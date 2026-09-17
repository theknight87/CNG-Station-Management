# Vessels Management (Prompt 12)

*Status: built and browser-verified at 1440 / 1024 / 390. Canonical asset tables are
still empty; the production import is Prompt 21 and has not been performed.*

## 1. Two asset types, one workspace, still two entities

Storage Vessels and Recovery Tanks share a workspace and an inspection vocabulary. They
are **not** merged: separate tables, separate rows, separate identities.

| | Storage Vessels | Recovery Tanks |
| --- | --- | --- |
| Table | `storage_vessels` | `recovery_tanks` |
| Can own an installed SRV | **yes** | **no** |
| Mapping states reachable | resolved · needs unit · conflict | identical |
| Schema fields | identical to Recovery Tanks | identical to Storage Vessels |

Every query pins `asset_type` — including the unfiltered fallback count used to tell
"no match" from "nothing exists" — so one registry can never show the other's rows
(VES-9, VES-10, plus a test).

Their schemas genuinely match field for field, so they share a renderer. Where they
**differ** they diverge honestly: only Storage Vessels show related relief valves.

## 2. Routes

| Route | Screen |
| --- | --- |
| `/manage/vessels` | canonical entry — redirects to Storage Vessels |
| `/manage/vessels/storage` | Storage Vessel registry |
| `/manage/vessels/recovery` | Recovery Tank registry |
| `/units/:unitId/storage`, `/units/:unitId/recovery-tank` | **unchanged** Prompt-10 Unit tabs |

Both are real routed links, so deep links and Back work in the production router.

## 3. No migration

**None was created.** `v_vessel_management` already existed: it unions the two tables
behind an `asset_type` discriminator and computes `due_status` with the same
`cng_due_status()` the Dashboard and the Unit tabs use. It is `security_invoker`,
SELECT-only to `authenticated` (VES-15…17). Migrations 0001–0029 remain immutable.

## 4. Fields the schema actually carries

Re-verified against the live schema for this prompt, not assumed from Prompt 10:

**Present:** manufacturer, model, serial (+ `serial_status`), `compressor_type_raw`
(raw source text for the vessel type), last inspection date, next inspection date, both
with explicit precision, `days_left`, `due_status`, `source_status_raw`, notes,
`mapping_status`, hierarchy ids, and full provenance.

**Deliberately NOT invented** — these columns do not exist on either table:

| Field | Status |
| --- | --- |
| Capacity | no column |
| Design pressure | no column |
| Working pressure | no column |
| Manufacture year | no column |
| Certificate / reference | no column |

Each registry states this in its footnote, so an engineer knows the value is *not
recorded* rather than merely empty. A test asserts none of these appears as a column.

**The date is an INSPECTION**, not a calibration. The schema says
`last_inspection_date` / `next_inspection_date`, and the UI keeps that word — they are
different procedures.

## 5. Mapping lifecycle — not the SRV lifecycle

`asset_mapping_status` is `resolved · needs_station_mapping · needs_unit_mapping ·
conflict`.

- There is **no `needs_equipment_mapping`**, and the filter does not offer one: a vessel
  *is* equipment, so it has no equipment parent to resolve.
- **`needs_station_mapping` is unreachable for these asset types.** `station_id` is
  `NOT NULL` on both tables. Verified by attempting the insert, which the constraint
  rejected. It is still handled in the label map so that if the schema ever changes the
  UI states the truth rather than rendering a blank (VES-14).

`conflict` is drawn distinctly from needs-mapping: one is missing evidence, the other is
evidence that disagrees with itself.

Each badge carries an icon, a word, and **its own** screen-reader description — these
badges borrow a colour kind but describe mapping, not compliance.

### ⚠️ A discrepancy for Prompt 21 to resolve

Prompt 6's dry-run reported **433 Storage** and **403 Recovery** records in
`needs_station_mapping`. The canonical tables **cannot hold that state** — `station_id`
is NOT NULL. Those staged rows therefore cannot be loaded as-is: the import must either
resolve a Station first, or the schema must change. This is an import/owner decision,
not a UI one, and is flagged rather than worked around. **No dry-run count is displayed
anywhere in this UI.**

## 6. Related SRVs — proven relationship only

A Storage Vessel's detail lists relief valves whose **equipment parent is that vessel**,
resolved through the composite foreign key `irv_storage_vessel_unit_fk
(storage_vessel_id, unit_id)` — which also forces the valve and the vessel into the same
Unit (VES-13).

A valve whose source `Location` merely says "Storage" has no `storage_vessel_id` and
never appears. That text is a parent-**kind** hint: it says the parent is *a* storage
vessel, not *which* one. When the list is empty the screen says so explicitly.

**A Recovery Tank cannot own an SRV, and none is shown.** `installed_relief_valves` has
no `recovery_tank_id` column, no such foreign key, and `srv_parent_kind` is
`compressor | storage_vessel | dispenser` (VES-11, VES-12). The Recovery registry shows
no relief-valve section at all and **issues no query** — asserted by a test.

A failed related-SRV query says so rather than rendering "no valves", which would read as
a safety-relevant fact that has not been established.

Not N+1: the query runs only when a row is **expanded**, one query for that one vessel.

## 7. Date precision and due status

Reuses `cng_due_status()` through the view — one definition product-wide. Buckets:
`overdue · due_today · due_7 · due_15 · due_30 · due_60 · valid · unknown`.

- Only an **exact date** produces a Days-left countdown.
- A `year_only` date shows its year with a qualifier and `—` in Days left. It becomes
  neither 1 January nor 31 December.
- `unknown` reads **"No exact date"**, never "Within date".
- Source status text such as `منتهية` sits beside the missing date, never becoming one.
- **No inspection interval is hard-coded.** The UI never derives a next-due date from an
  assumed period; it displays only what the database computed.

## 8. Search, filters, sorting, pagination — server-side

- **Search** covers serial, manufacturer, model, station and unit, with the folded form
  offered so an Arabic query typed one way finds the other. Retrieval only — it resolves
  no identity.
- **Filters**: Region, Mapping status, Due status. They intersect (verified: East +
  Overdue).
- **Sorting** puts the requested column first and appends `id` as a tie-break, so paging
  is stable and a secondary `.order()` cannot displace the primary sort. NULLs sort last
  deliberately (`nullsFirst: false`).
- **Pagination** uses `.range()` with an RLS-scoped `count: 'exact'`.

"Due ≤60d" **includes overdue**, and the label says so.

## 9. Attention summary

Six `head: true` counts over the whole authorized dataset **for that asset type** — the
server returns numbers and no rows. They describe the dataset, not the filters; when the
table is filtered to a different number, a line says so. Any failure replaces the strip
with a sentence; **a failed count is never a zero**.

## 10. Authorization

`v_vessel_management` is `security_invoker` over tables whose SELECT policy is
`cng_can_read_region(region_id)`. Both `station_id` and `region_id` are NOT NULL, so —
unlike SRVs — there is no station-unconfirmed path needing a separate policy: every row
is region-scoped, and so is the count behind pagination.

Asserted (VES-1…8): a foreign Region's vessels and tanks are absent from the list, from
a direct id lookup, from search on the foreign Station name, from the counts, and from a
mapping filter.

## 11. Mapping mutation — deferred

Unchanged from Prompt 11's finding, and it applies here too: the database enforces
hierarchy consistency, but **mapping attribution is still forgeable and unaudited** —
there is no audit trigger, and the actor columns are client-writable. Per CLAUDE.md §9 a
mapping change must record a non-forgeable who and when. Until a generic audited mapping
mechanism exists, **no mapping control is exposed** on this screen either.

## 12. Responsive, accessible, branded

Verified at 1440 / 1024 / 390; tables scroll inside their own region and the page body
never scrolls sideways. Measured: active type label 4.64:1, inactive 5.42:1, metric
labels 5.67:1, null markers and headers 5.17:1. One `h1` with a clean H1→H2→H3 order,
`aria-sort` on seven sortable columns, a live pagination region, every control named.

Brand colour appears only as the active-type underline and text (`--brand-strong`) and
the focus ring. Mapping and due states use the independent semantic tokens — "Resolved"
is the teal `ok` token, never Cargas green.

## 13. Verification

| Check | Result |
| --- | --- |
| `scripts/verify-all.sh` | **exit 0** |
| Frontend tests | **270** (245 → 270, +25) |
| Schema assertions | **72** (unchanged) |
| Authorization assertions | **166** (149 → 166, +17 VES-1…18) |
| Migrations | 29 from zero; **no new migration** |
| Browser, both registries × 3 widths | no page errors, no horizontal page overflow |
| Production counts | all asset tables 0 — unchanged |

### Deferred to Prompt 13+

- Mapping mutation, pending non-forgeable attribution and audit history.
- The full Data Quality administration system.
- The `needs_station_mapping` discrepancy above is an import/owner decision for Prompt 21.

---

## Prompt 24B — Storage Vessel duplicate serial visibility

Prompt 24A found a real gap: **16 storage vessels (8 serials) share a recorded
serial with another vessel, and nothing in the product said so.** `serial_duplicate`
existed only on `v_hose_registry`, because Prompt 14 built it where a hose's
individual traceability made it the organising fact. Data principle 16 requires
duplicate candidates to be *reported*; for vessels they were not.

### What this is, and what it is not

It is **evidence for review**. Principle 16 is explicit that repeated values are
not duplicates without supporting evidence — six identical relief valves on one
station may be six real devices, and two vessels recording the same serial may be
two real vessels whose serials came from the same source cell.

So: **nothing is merged, deduplicated, deleted, invalidated or corrected.** All 16
remain independent canonical records. No serial value is altered. No source
evidence is touched. No Unit mapping, alias or staged row is affected. The UI
offers no destructive action, and the wording is **"Duplicate serial candidate"** —
never "duplicate asset", "invalid", "error" or "delete duplicate".

### Production finding (Phase 1, read-only)

| Measure | Value |
| --- | --- |
| Groups / rows | **8 groups, 16 rows**, every group a pair |
| Affected Stations | 5 |
| Same-Station groups | 6 groups (12 rows) |
| Cross-Station groups | 2 groups (4 rows) |
| Same-Region / cross-Region | 8 / **0** |
| Groups from distinct source rows | **8 of 8** |
| Groups with differing raw spelling | 0 |

All eight come from **distinct source rows with byte-identical raw serials** —
eight pairs of separately recorded assets, not one row imported twice.

### Migration 0050 (`v_vessel_management`) — NOT DEPLOYED

One additive migration containing **exactly one view replacement and no DML**. It
adds **no table, column, constraint, index, grant, policy or enum**; the three new
values are derived in the view and stored nowhere (VDUP-13).

It **reuses the Prompt 14 hose pattern** rather than inventing a second
duplicate-detection architecture: the same `count(*) FILTER (...) OVER (PARTITION BY ...)`
shape, appending `serial_missing`, `serial_duplicate` and `serial_duplicate_count`.

Three design points:

- **Partitioned by `asset_type`.** The view UNIONs two genuinely distinct
  entities; a Storage Vessel and a Recovery Tank sharing a serial are not a
  candidate pair (VDUP-8).
- **Blank serials are not duplicates.** The first draft used `IS NOT NULL` alone
  and my own regression test caught two blank-serial vessels being reported as a
  pair. All three expressions now use `nullif(btrim(serial_number), '')`. A blank
  source cell and a NULL are the same fact; two of them are not evidence of a
  shared identity (VDUP-5/6). The stored value is still displayed exactly as
  recorded — the guard filters the comparison, it never trims the data (VDUP-10).
- **`security_invoker = true` is RESTATED.** `CREATE OR REPLACE VIEW` does not
  preserve reloptions — the Prompt 19B defect. The comparison therefore runs over
  rows the caller may already read, so a collision whose other half lies outside
  the caller's Regions is **not** reported to them; a wider signal would disclose
  a row they may not see. VDUP-11 asserts it from `pg_class.reloptions`.

`v_report_due_compliance` depends on this view, so columns were **appended** and
the view was never dropped (VDUP-12).

### Query and UI

`useVesselManagement` selects the three columns, adds a `serial_duplicate` count
to the attention summary, and a single **"Duplicate serial candidates only"**
checkbox that narrows the existing query by one server-side column — not a new
filtering system. Both halves of a pair carry the flag, so the filter can never
hide one half of a candidate group.

The badge borrows the `conflict` kind for colour and icon (the existing vocabulary
for "held for human resolution") and **overrides the description**, which is the
documented contract for a badge that borrows a kind but means something else. It
sits **beside** the serial, never in place of it.

### Data Quality (Phase 6) — a finding, no change

`v_data_quality_queue` is keyed on `mapping_status <> 'resolved' OR needs_review`.
All 279 canonical assets are `needs_unit_mapping`, so **all 16 vessels already
appear in the Data Quality queue** — but for the unit-mapping reason, not the
duplicate one. Surfacing the duplicate reason there would require either setting
`needs_review`/`review_reason` on production rows (DML, which this prompt forbids)
or a further view change beyond the single approved migration. `import_issue_type`
already contains `duplicate_candidate`, so the enum exists for it whenever an
owner authorizes that work. **Recorded, not done.**

### Latent gap reported, not silently changed

`v_hose_registry` has the same blank-serial behaviour 0050 fixes for vessels.
Production holds **0 blank serials anywhere**, so the gap is latent rather than
live, and changing another module was outside this prompt's scope.

### Verification

Gate exit 0. Frontend **617 → 627**, schema **261 → 274**, authorization 624
unchanged (no policy, grant or RLS boundary was touched). Both the SQL assertions
and five of the frontend tests were **proved to fail against the pre-change code**
before being accepted.

**Migration 0050 is NOT DEPLOYED** (SHA-256 `7883b978...`). It requires separate
owner approval.
