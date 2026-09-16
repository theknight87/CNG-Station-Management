# Reports Module (Prompt 20)

Routes: `/reports`, with categories at `/reports/due`, `/srv`, `/vessels`,
`/gas-detectors`, `/hoses`, `/data-quality`, `/activity`.
One migration: **0042**, additive — a single view.

---

## 1. What the gap analysis found

Most of what a Reports module needs already existed. These views are already
RLS-bounded, already date-precision-correct, and already the source the Unit
workspace and the management registries read:

| Report | Reads |
| --- | --- |
| SRV (installed) | `v_installed_srv_management` |
| SRV (warehouse) | `v_warehouse_srv_management` |
| Vessels | `v_vessel_management` (`asset_type` keeps Storage and Recovery distinct) |
| Gas Detectors | `v_report_gas_detectors` (Prompt 20A — see §1a) |
| Hoses | `v_hose_registry` |
| Notification Activity | `v_alert_inbox` |
| Data Quality | `v_report_data_quality` (Prompt 20A — see §1a) |

Reports **read** those. Building parallel reporting tables would have created a
second place for the truth to live, and a second place is where drift starts.

**The one genuine gap** was a unified, cross-family due/overdue *list*.
`v_dashboard_due_summary` counts; it does not enumerate. So exactly one object
was added.

**No new RPC. No new table. No new index.** Asserted: `RPTSEC-10`, `RPTSEC-11`.

## 1a. Two corrections (Prompt 20A)

Independent review found one material completeness gap and one related
detector-row issue. Migration **0043** adds two views; nothing else changed.

### Defect 1 — Data Quality read canonical assets only

`v_data_quality_queue` covers **committed canonical assets**. Production has
committed none, so the report read *clean* while the staged import carried real
unresolved evidence — including the `stale_source_decision` state Prompt 19B
added precisely so a lapsed ruling stays visible. A compliance report saying
"nothing to see" while the evidence exists is worse than no report.

`v_report_data_quality` unions **three layers**:

| Layer | Source | Visible to |
| --- | --- | --- |
| `canonical` | `v_data_quality_queue` + Region/Station names | everyone, **Region-scoped** |
| `staged` | `v_admin_staged_mapping_queue` | manager / admin only |
| `import_issue` | open rows of `import_issues`, using the **existing** `import_issue_type` enum | manager / admin only |

**No authorization was weakened to do this.** `import_staging_rows`,
`import_issues` and `import_mapping_decisions` are all manager/admin-only by
their *existing* SELECT policies, because raw source text is never an
authorization boundary (§10) and a record whose Station is unconfirmed has no
proven Region to scope it by. Since the view is `security_invoker`, each branch
keeps its own RLS and the layering is automatic — a viewer reads the canonical
layer alone (`DQR-17`), an engineer likewise (`DQR-12`, `DQR-13`), and the
Station-unconfirmed protection is intact (`DQR-16`). No policy relaxed, no grant
widened, no Admin-only view exposed to a Region-scoped role.

A Region-scoped user is **told** that staging is out of scope rather than left to
infer it is absent.

`stale_source_decision` is its own `issue_kind`, its own summary metric, and is
never collapsed into "awaiting" or "recorded" (`DQR-4`, `DQR-5`, `DQR-6`). No
issue type was invented: `DQR-7` asserts every import-issue kind is a real
`import_issue_type` value.

Reports remains **read-only**: `DQR-19` proves that a manager who can now *see*
staged evidence still cannot decide it, `DQR-20` that no decision can be
superseded, `DQR-21` that raw staged evidence is immutable, `DQR-22` that the
view itself is not writable.

### Defect 2 — recorded detector absence rendered as a detector

`v_gas_detector_management` deliberately unions installed detectors with recorded
**absence** — a "not installed" row is evidence that an area has no detector, and
carries `detector_id IS NULL`. Migration 0042 filtered those out of the *due*
report, but the gas-detector *asset* report did not.

Two consequences: recorded absence could be read as an installed detector with no
serial and no calibration; and a NULL identity column leaves a paginated sort
without a stable key, where a row can appear on two pages or on none.

`v_report_gas_detectors` applies the filter **in the database**, so it is not a
presentation decision about what counts as a physical asset, and the report
orders by a column that cannot be NULL (`GDR-2`, `GDR-3`, `GDR-5`). The due
report is unchanged (`GDR-6`). `GDR-1` and `GDR-4` assert the fixtures really do
contain both shapes, so the test is not vacuous.

## 2. `v_report_due_compliance` — the only new object

A `UNION ALL` over the five asset families, built **on top of the management
views**, so:

* `days_left` and `due_status` are the family views' own, which come from
  `cng_days_left()` and `cng_due_status()` — the alert engine's functions, and
  the only place in this system that computes them. There is no second
  interpretation to drift, and `RPTDUE-15`/`RPTDUE-16` assert every report row's
  classification equals a fresh evaluation of those functions on its own date.
* RLS follows automatically. The view is `security_invoker = true`, stated
  explicitly because `CREATE OR REPLACE VIEW` does not preserve reloptions
  (Prompt 19B).

Columns absent from a family are `NULL` and that is a **fact, not a gap**: an
installed SRV has no `model` column in this schema; a hose has neither `model`
nor `manufacturer`. Nothing is invented to fill a column.

**Job Number** exists only on `units` and `compressors`. The due report therefore
shows the **Unit's** job number, labelled `Unit Job No.`, joined once, set-based.
No per-asset job number was invented.

## 3. Authorization

| Role | Scope |
| --- | --- |
| anon | nothing (`RPT-1`, `RPT-2`, `RPT-3`) |
| viewer | read-only, own Regions (`RPT-10`, `RPT-11`) |
| engineer | read-only, own Regions (`RPT-7`, `RPT-8`, `RPT-9`) |
| manager | company-wide (`RPT-6`) |
| admin | company-wide (`RPT-4`, `RPT-5`) |

**The database enforces this, not the filters.** `RPT-9` is the assertion that
matters: an engineer running the report with *no* Region filter still receives
only their own Regions. A forged `region_id` returns that Region's rows only if
the caller was already entitled to them.

A Station-unconfirmed record carries raw source text and no proven Region, so it
stays admin/manager only in reports exactly as everywhere else (`RPT-12`).

Reports **mutate nothing**: no RPC, no write, no acknowledgement, no mapping
control. Asserted in SQL (`RPT-14`, `RPT-15`) and in the frontend tests.

### Every view is `security_invoker`

`VIEWSEC-ALL` asserts, from `pg_class.reloptions`, that **no view in the schema**
runs with owner rights — not only the ones a `v_admin%` or `v_report%` naming
pattern would catch. A report reads six views named neither way, and an
owner-rights view among them would hand a viewer another Region's assets.

## 4. Due-date semantics

Identical to the Alerts engine, because it is literally the same functions.

| State | Meaning |
| --- | --- |
| Overdue | exact date before the Cairo business date |
| Due Today | exact date equal to it |
| Due ≤ 7 / 15 / 30 / 60 | exact date within that window |
| Later / Current | exact date beyond 60 days |
| **Unknown Due Date** | precision is `year_only`, `unknown` or `invalid`, or no date |

**A year-only date never enters an exact bucket** (`RPTDUE-9`, `RPTDUE-10`) and
yields **no** days-remaining figure at all (`RPTDUE-13`). Unknown is deliberately
neither compliant nor overdue. Boundaries are exact: day 7 is `due_7`, day 8 is
`due_15` (`RPTDUE-3`, `RPTDUE-4`). Imported Excel "Days Left" is never read.

## 5. Filters

Region → Station → Unit, **dependent by construction**: no Region means no
Station list; changing the Region clears both. A Station/Unit pair that never
existed is not expressible from the bar — and is refused anyway (`RPTSEC-4`).

Draft and applied are separate: typing edits a draft, **Apply** commits it. A
report query counts across five families, so firing one per keystroke would be
wasteful and would make the summary flicker between answers to different
questions. Search additionally debounces at 300ms. **Clear** resets both.

## 6. Pagination

Server-side filtering, ordering and paging throughout. Nothing fetches a table
and filters in the browser.

* 50 rows per request, **Load more** extends the range; no permanent ceiling.
* An exact total comes from `count: 'exact'`, computed under the caller's RLS —
  so the total a viewer sees is the total they are allowed to see.
* **Ordering is deterministic**: every query ends with the row's own id. Without
  that tiebreak two rows sharing a due date can swap between pages, showing one
  twice and omitting the other.
* A filter change resets paging by derivation, so page 3 of one question never
  survives into another.

## 7. CSV export

The export **re-runs the same query**: same view, same filters, same order, same
RLS — just more pages of it, in 1,000-row chunks. It cannot contain a row the
table could not have shown that user. There is no "download the table and filter
in the browser" path, and no new export RPC to attack.

Ceiling: **10,000 rows**, documented and *stated in the UI* when reached, so
nobody receives a short file believing it is complete.

### Formula-injection protection

A spreadsheet treats a cell starting `=`, `+`, `-`, `@`, tab or CR as a formula.
Source data here is operator-entered text, so this is a real path to attacking
whoever opens the file.

* Text cells with a formula lead are **quoted and prefixed with an apostrophe**
  (the OWASP mitigation). The prefix is additive — strip it and the original
  value is intact.
* **Genuine numbers are emitted bare**, so a numeric column still sorts
  numerically: `-5` days remaining stays `-5`. A value that is not actually
  numeric falls back to the text guard even in a numeric column.
* **UTF-8 with a BOM**, because Arabic Station names are ordinary data here and
  Excel misreads BOM-less UTF-8 as the local codepage.
* Stable header row in the declared column order; NULL is blank — never `N/A`,
  `-` or `0`; CRLF line endings; identifiers keep their leading zeros.
* Dates export as the **raw ISO date or blank** — a year-only value exports
  blank, never as a calendar date it never had.
* Filename `cng-<report>-<YYYY-MM-DD>.csv`, dated by the **Cairo** business date.

## 8. Indexes — none added, deliberately

Every report predicate and ordering is already covered by an existing index:
`*_region_idx`, `*_station_idx`, `*_unit_idx`, `*_serial_idx`, `*_mapping_idx`,
the partial `*_due_idx` on `next_*_date WHERE precision = 'exact_date'` (exactly
a due report's predicate), and `alerts_open_idx` / `alerts_region_idx` /
`alerts_station_idx`. The secondary sort key is the primary key, which every
table already indexes.

Adding more would be speculative. If a real query plan later shows a gap, that is
the moment to add an index and say which query it serves.

## 9. Empty production

Production has run no import, so most reports are legitimately empty. The two
kinds of empty are told apart, because they call for different next actions:

* unfiltered and empty → *"No canonical assets have been imported yet."*
* filtered and empty → *"No records match the selected filters."*

Neither is presented as an error, and no sample row is ever invented.

## 10. Verification

| | Count | Prompt 19B baseline |
| --- | --- | --- |
| Frontend tests | 557 | 499 |
| Schema assertions | 146 | 146 |
| Authorization assertions | 591 | 508 |
| Migrations from zero | 43 | 41 |

Upgrade replay: production-equivalent base at **41**, then 0042 and 0043, then
both SQL suites against the upgraded database.

**NOT DEPLOYED and NOT LIVE VERIFIED.** 0042 and 0043 exist in the repository
only.

## 11. Deferred / non-goals

* **PDF export** — CSV is the required format and the architecture has no PDF
  path; adding one would not have been minimal scope.
* **Saved report definitions / scheduled report email** — not asked for, and
  scheduling would touch the notification system.
* **Charts** — the prompt asks for operational tables and warns against vanity
  metrics; every figure here is a counted number with a stated scope.
* **Mapping corrections from Reports** — explicitly forbidden. Reports is a read
  surface; corrections stay in `/admin/data-quality`, which an admin reaches by
  a link.
