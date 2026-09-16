# Gas Detector Management (Prompt 13)

Company-wide calibration and inventory registry for station Gas Detectors.

**Route:** `/manage/gas-detectors` — the existing sidebar entry, preserved. It is a
single flat route inside the existing `AppShell`; no parallel layout was introduced.

**No new migration.** Every source this workspace needs already existed. `v_gas_detector_management`
was created in migration 0011 and is read as-is.

---

## 1. What this is, and what it is not

It is a **management and calibration registry**. It is **not** a monitoring console.

The schema stores no reading, no gas concentration, no alarm state, no online/offline flag,
no sensor health and no battery level. None of those is displayed, and `GD-28` asserts that
`gas_detectors` carries no such column, so the absence is enforced rather than merely observed.

Alert generation, the alert inbox, acknowledgement and scheduled processing belong to Prompt 15.
Prompt 13 only *consumes* the existing due-status data.

## 2. The actual schema

### `gas_detectors` — installed detector assets only

| Column | Notes |
| --- | --- |
| `station_id` | **NOT NULL** — see §4 |
| `region_id` | NOT NULL; pinned to the station's region by `gas_detectors_station_region_fk` |
| `unit_id` | nullable — NULL while the Unit is unconfirmed |
| `mapping_status` | `asset_mapping_status` |
| `manufacturer`, `manufacturer_raw` | |
| `model`, `model_raw` | |
| `serial_number`, `serial_number_raw`, `serial_status` | TEXT; 149 of 178 installed detectors have no serial |
| `last_calibration_date` / `_precision` / `_raw` | |
| `next_calibration_date` / `_precision` / `_raw` | |
| `source_status_raw` | e.g. `منتهي`, preserved beside a missing date |
| `notes`, provenance, `needs_review`, `review_reason` | |
| `resolved_by`, `resolved_at`, `archived_at` | |

Constraints that the UI depends on, each proved by an assertion:

- `gas_detectors_resolved_ck` — a `resolved` detector must carry a Unit (`GDS4`)
- `gas_detectors_needs_unit_ck` — `needs_unit_mapping` means the Unit really is absent (`GDS5`)
- `gas_detectors_last_prec_ck` / `_next_prec_ck` — a date and its precision cannot disagree
  (`GDS1`, `GDS2`, `GDS3`)
- `gas_detectors_station_region_fk` — a detector cannot be filed under a foreign region (`GDS7`)

### `gas_detector_presence` — evidence, not an asset

138 source rows state "Not exist in the station". That is information worth keeping, and it is
kept **without fabricating a detector record to represent absence** (`GDS8`). A presence row
carries `detector_presence` (`installed | not_installed | unknown`), `presence_raw`, `area_type`
and `area_type_raw`. One statement per unit, and one per station where the unit is unknown
(`GDS10`).

## 3. Area Type — a classification, never a location and never a status

**`area_type` is not a column on `gas_detectors`.** It lives on `gas_detector_presence`, and
`v_gas_detector_management` LEFT JOINs it by `(station_id, unit_id)`. Asserted both ways:
`GD-25` (absent from the detector) and `GD-26` (present on the presence row).

Three consequences, all of them deliberate:

1. Area Type describes the **area**, so it is shared by every detector in that unit.
2. It is **NULL** where no presence row covers a detector's station and unit. Those detectors are
   counted in neither the Open nor the Closed breakdown, and the summary says so.
3. It is **not a position**. There is no `location`, `location_raw`, `position` or `placement`
   column anywhere in this schema (`GD-27`), so no location is displayed and none is inferred —
   not from the station name, the unit name, `area_type`, the source row order, another detector,
   or the equipment inventory.

`Open` and `Closed` render in **exactly the same neutral treatment** — identical border,
background, weight and colour; only the word differs. A unit test asserts the two `className`
strings are equal, so a future change that colours "Closed" as a warning fails the suite.
An enclosed area is a design fact, not a fault, and the brand rule holds too: Cargas green never
means healthy and NGV yellow never means warning.

## 4. Canonical compatibility of `needs_station_mapping` — a NEW Prompt-21 blocker

**The mandatory §9 check. The answer is NO.**

`asset_mapping_status` defines `needs_station_mapping` (`GD-21`), but `gas_detectors` cannot hold
it: **`station_id` is NOT NULL** (`GD-22`). This was proved by attempting the insert, which the
not-null constraint rejected — `GD-23` and `GDS6` both run that insert and require rejection,
rather than reading the catalogue and inferring.

Prompt 6 staged **219 gas detector rows** in exactly that state (of 316 total: 54 resolved,
43 `needs_unit_mapping`, 219 `needs_station_mapping` — **dry-run staging figures, never displayed
as production metrics**). Those 219 rows **cannot enter the canonical table as staged.**

This is the **same shape as the vessel blocker** found in Prompt 12 (433 Storage, 403 Recovery).
It is recorded, not worked around:

- no constraint was relaxed
- no station mapping was fabricated
- no staged row was silently dropped
- the unreachable state is **not offered** in the Mapping filter, because offering a state the
  database cannot store would be a lie in the UI

**Prompt 21 must resolve both blockers before the production import.**

`needs_equipment_mapping` does not apply to detectors at all: a detector hangs off a Unit and has
no equipment parent, and `gas_detectors` carries no `compressor_id`, `storage_vessel_id` or
`dispenser_id` (`GD-24`).

## 5. Hierarchy

`Region → Station → Unit → Gas Detector`, where the schema confirms it.

- A **resolved** detector shows its confirmed Station, Region and Unit.
- A **`needs_unit_mapping`** detector shows the Station (which *is* proven) and states
  "Not confirmed" for the Unit. **No Unit is ever guessed** — not from the station's only unit,
  not from a similar detector, not from name similarity.
- The Prompt-10 **Unit tab is unchanged** and remains Unit-scoped. `GD-30` asserts that a
  resolved detector always carries a confirmed Unit, so a Unit tab cannot surface an unresolved
  one; the existing Prompt-10 test asserting `v_gas_detector_management.eq:unit_id` still passes.

## 6. Calibration, date precision and due status

**Calibration interval — a documented gap.** There is **no authoritative representation of a
calibration interval anywhere in this project.** `alert_rules` carries only `subject`, `threshold`
and `days_before`; it has no interval, frequency or period column. No schema column, no
configuration table and no seed row states "one year".

Therefore **no interval is hard-coded in React.** The UI displays the stored
`next_calibration_date` and the due status SQL derives from it, and computes nothing of its own.
A unit test feeds a `days_left` and a `due_status` that deliberately disagree and asserts the UI
renders both unchanged — proving there is no competing frontend calculation.

If an authoritative interval is wanted later, it needs a schema or configuration decision; it must
not be inferred from general engineering knowledge.

**Date precision** follows the project rule exactly. Only `exact_date` drives a countdown.
A `year_only` date shows its year, is labelled "year only", and is **never** converted to
`2025-01-01` or `2025-12-31`. `days_left` is NULL for it and `due_status` is `unknown` —
which reads "No exact date", never "Within date". Excel `Days Left` is not used.

**Due status** comes from `cng_due_status()` via the view. The buckets are the project's existing
ones: `overdue | due_today | due_7 | due_15 | due_30 | due_60 | valid | unknown`, labelled
Overdue, Due today, Due ≤7d/≤15d/≤30d/≤60d, Within date, No exact date.

## 7. The registry

**Columns, in priority order:** Serial · Station · Unit · Area type · Next calibration ·
Days left · Status · Last calibration · Mapping · Manufacturer · Model.

The order is a measured decision, not the schema's order. With Manufacturer and Model in third and
fourth place, `Days left` and `Status` fell outside the 1152px visible region at the 1440px desktop
target — the two values the screen exists to surface were the two you could not see. Reordering put
every attention column on screen at 1440; Manufacturer and Model, which an engineer looks up rather
than scans, now scroll instead. A test locks the first seven headers in place.

**Deliberately not invented** — no column exists for any of these, so none is drawn:
detector location/position, calibration certificate number, calibration gas or concentration,
detection range, sensor type, installation date, firmware version, and every live-telemetry field.
An empty column would imply the value is merely missing rather than never recorded.

**Presence defaults to `installed`**, because the registry's subject is the device. Recorded
absence is one filter selection away and is counted under its own "Not installed" metric — it is
never added to the detector count.

**NULL** shows as a quiet em dash with the accessible text "not recorded". Never `N/A`, never `0`,
never a placeholder. `serial_status = 'not_yet_assigned'` is worded differently, because the source
*stating* no serial has been issued is a fact, not a gap.

## 8. Search, filters, sorting, pagination

All server-side. Nothing is fetched company-wide and filtered in React.

- **Search** — `serial_number`, `manufacturer`, `model`, `station_name` on the raw term, and
  `unit_name` on the folded form, using the same Arabic folding as the SQL. Search is retrieval:
  a match resolves no mapping and advances no state.
- **Filters** — Region, Station (dependent, offered only once a Region bounds the list),
  Area Type, Presence, Mapping Status, Due Status. They combine as a true intersection;
  East + Closed + Overdue is verified in the browser.
  Manufacturer and Model are searchable rather than dropdown filters: a distinct-value dropdown
  would need an unbounded scan of the view for little gain over search.
- **Sorting** — 8 sortable columns, each with `aria-sort`, both directions verified.
  `nullsFirst: false` throughout, so unknown values sort last intentionally.
- **Deterministic tie-break** — every sort appends `detector_id, station_id, unit_id`. A presence
  row has no `detector_id`, but `gas_detector_presence` is unique on `(station_id, unit_id)`, so
  the triple identifies every row across both branches of the UNION and paging is stable.
- **Pagination** — server-side, 50 per page, `count: 'exact'` under RLS.

Four distinct screens: loading, empty, filtered-no-results, and query failure. A failure is never
rendered as an empty registry and a failed count is never rendered as zero.

## 9. Attention summary

Eight `head: true` counts over the **whole authorized dataset** — not the current page and not the
current filters: detectors, overdue, due ≤60d (incl. overdue), needs unit mapping, no exact date,
not installed, open area, closed area. Each runs under the caller's own RLS.

Any single failure fails the whole strip and states so, because seven correct metrics beside one
that silently reads zero is the same lie in a smaller box.

## 10. RLS and information leakage

The view is `security_invoker` (`GD-18`) over two tables whose SELECT policy is
`cng_can_read_region(region_id)`, and `region_id` is NOT NULL on both, pinned by composite FK — so
it is a trustworthy authorization key, not a denormalized copy that could drift. `anon` holds no
grant (`GD-19`), and no application role may write through the view (`GD-20`).

31 assertions prove an out-of-region detector cannot be reached through **list, direct lookup,
the base table, search by serial / manufacturer / station name, the pagination count, the Area Type
filter, the Presence filter, or detail expansion** (`GD-1`…`GD-14`), and that `anon` reaches
nothing at all (`GD-15`…`GD-17`).

Two of those assertions required care and are worth remembering: `authenticated` **holds** the
UPDATE grant on `gas_detectors`, so an unauthorized UPDATE raises no privilege error — the row
simply fails the policy's `USING` clause and the statement matches nothing. **Zero rows changed is
the security property**, so that is what `GD-12` and `GD-13` assert. An exception-only test would
have reported a false PASS for the wrong reason.

Because `station_id` is NOT NULL, there is no station-unconfirmed detector and therefore no
raw-source-text leakage path of the kind `installed_relief_valves` needs a special policy for.

## 11. Mapping mutation — DEFERRED

No mapping control is exposed, for the same reason as Prompts 11 and 12.

The database enforces hierarchy consistency, but `gas_detectors` has **no audit trigger**
(`GD-29`), and `mapping_status`, `unit_id`, `resolved_by` and `resolved_at` are all
client-writable. Attribution is therefore **forgeable and unrecorded**, and CLAUDE.md §9 requires
every mapping change to record who and when and be retained as audit history.

A detector-specific insecure workaround was not built. Mutation needs the generic, audited
mechanism: a server-derived non-forgeable actor, a trustworthy timestamp, retained old/new values,
DB hierarchy enforcement and RLS authorization.

## 12. Performance

One set-based query per page plus eight head-only counts. No N+1 station lookup, no N+1 unit
lookup, no per-row due-status request, no per-row count query, and no client-side authorization
filtering. The station dropdown is bounded by requiring a Region first. Indexes already exist on
`unit_id`, `station_id`, `region_id`, `serial_number`, `next_calibration_date` and
`mapping_status`.

## 13. Responsive and accessibility

Verified in Chromium at **1440 / 1024 / 390** — 58 browser assertions, all passing.

No page-level horizontal overflow at any width; the dense table scrolls inside its own region, and
stays a table on mobile rather than becoming a stack of giant cards. One `h1` per screen, heading
order skips no level, every filter control is labelled, `aria-sort` on 8 columns, the detail
disclosure reports `aria-expanded`, and Tab reaches a genuinely `:focus-visible` control.

Measured contrast, light and dark: area chip 16.32:1, page h1 17.08:1, filter labels 17.87:1,
NULL markers / metric labels / area caption 5.67:1, footnote 5.42:1, column headers 5.17:1.
All pass WCAG AA. Neither Area Type nor due status is conveyed by colour alone — each carries its
word plus an accessible description.

Arabic and mixed Arabic/Latin/numeric station and unit names render at every size, including
inside the LTR table layout.

## 14. Deliberate deferrals

| Item | Why | Owner |
| --- | --- | --- |
| Mapping mutation | attribution is forgeable and unaudited (§11) | a later prompt, once the generic audited mechanism exists |
| Alert generation and inbox | out of scope by instruction | Prompt 15 |
| `needs_station_mapping` for detectors | canonically unstorable (§4) | Prompt 21 |
| Manufacturer / Model dropdown filters | would need an unbounded distinct scan; search covers it | — |
| Authoritative calibration interval | not represented anywhere (§6) | needs a schema/config decision |
