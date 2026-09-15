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
