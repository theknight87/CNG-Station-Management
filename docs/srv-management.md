# Global SRV Management (Prompt 11)

*Status: built and browser-verified at 1440 / 1024 / 390. Canonical asset tables are
still empty; the production import is Prompt 21 and has not been performed.*

## 1. Two datasets, one workspace, never merged

| | Installed SRVs | Warehouse SRVs |
| --- | --- | --- |
| Table | `installed_relief_valves` | `warehouse_relief_valves` |
| Physical position | `Region → Station → Unit → Equipment` | **none** |
| Mapping lifecycle | yes | **not applicable** |
| Region filter | yes | **none offered** |
| RLS | region-scoped; unmapped rows admin/manager only | any active user may read |

They are queried separately, paged separately and never unioned. Two valves that
share a part number are still two different things. Asserted by **SRV-10**: no id
appears in both views.

Warehouse records do carry `target_region` / `target_station` — but that is a
**destination**, modelled by the `warehouse_availability` enum's "sent to station"
states. It is where a valve is being *sent*, not where it is *fitted*, and the column
is labelled **Destination**. It is never rendered as hierarchy.

## 2. Routes

| Route | Screen |
| --- | --- |
| `/manage/srvs` | canonical entry point — redirects to Installed |
| `/manage/srvs/installed` | installed valves, all mapping states |
| `/manage/srvs/warehouse` | warehouse inventory |
| `/units/:unitId/srvs` | **unchanged** — the Prompt-10 Unit-scoped view |

Both datasets are real deep-linkable routes, so the browser Back button works.

## 3. Schema and views reused — no migration

**No migration was created.** Migrations 0001–0029 remain immutable. Everything needed
already existed:

- `v_installed_srv_management` — hierarchy, mapping status and label, parent kind and
  label, `station_display`, `needs_station_mapping`, date precision, `days_left`,
  `due_status`, and full source provenance.
- `v_warehouse_srv_management` — availability, warehouse code, destination,
  `is_unassigned_stock`, dates and due status.
- `v_unit_srvs` — the Prompt-10 Unit view, untouched.

Both are `security_invoker`, granted SELECT to `authenticated` only (SRV-12, SRV-13),
and no application role can write through either (SRV-14).

## 4. Global vs Unit visibility — the widening is the database's decision

The global screen shows **every mapping state the caller is authorized to read**. That
is safe because RLS, not the UI, decides:

```sql
CASE WHEN station_id IS NOT NULL THEN cng_can_read_region(region_id)
     ELSE cng_can_access_unmapped_srv()   -- admin/manager only
END
```

So a Region-scoped engineer reads **no** station-unconfirmed valve at all — because its
raw source station name would otherwise disclose a Station they have no claim to. An
unconfirmed name is evidence, never permission (CLAUDE.md §10). Asserted in **SRV-6**
and **SRV-7**.

The Unit tab's narrower rule is untouched: it reads a different view with its own
predicate, re-asserted by **SRV-11** and verified in the browser regression pass.

## 5. Mapping lifecycle presentation

`needs_station_mapping → needs_unit_mapping → needs_equipment_mapping → resolved`,
with `conflict` as an evidence-preserving side state. Nothing here advances a record.

| State | What the screen shows |
| --- | --- |
| `resolved` | full hierarchy and the named equipment parent |
| `needs_equipment_mapping` | Station and Unit; parent reads **Not confirmed** |
| `needs_unit_mapping` | Station; Unit reads **Not confirmed** |
| `needs_station_mapping` | **Station not confirmed** — no Region, no Station, no Unit |
| `conflict` | drawn distinctly from needs-mapping, with its own description |

**Conflict is not "needs mapping".** One is missing evidence, the other is evidence that
disagrees with itself. Collapsing them would hide the second behind the first.

Each badge carries an icon, a word, and its **own** screen-reader description — a
critique-pass fix: "Resolved" previously borrowed the compliance description and
announced "within its calibration or inspection date", describing a calibration state
to someone reading a mapping state.

## 6. Source context is never an identity

`Stage` and `Storage` are parent-**kind** hints. In the expanded record they appear as:

- **Location (source text)** — `Stage` + *"source context, not an identity"*
- **Expected parent (source hint)** — `Compressor` + *"which one is unknown"*
- **Station name (source text)** — the raw unmatched name + *"unconfirmed source text"*

None is ever promoted into the Station or Equipment column, and none populates a foreign
key. Verified in the browser and in tests.

## 7. Identifiers

Serial and part number are separate TEXT columns and are never parsed, padded, trimmed
or merged. `SS-4R3A` is owner-confirmed as a **Part Number**: it renders in the Part
number column and the serial reads *not recorded*, because no genuine serial exists.
Verified by reading the actual rendered cells, not the markup.

A NULL serial is the quiet marker reading "not recorded" — never `N/A`, `Unknown` or `0`.
`not_yet_assigned` is worded differently, because it is a fact rather than a gap.

## 8. Due status and date precision

Reuses the existing `cng_due_status()` via the views — one definition across the whole
product. Buckets: `overdue · due_today · due_7 · due_15 · due_30 · due_60 · valid ·
unknown`.

- Only an **exact date** produces a Days-left countdown.
- A `year_only` date shows its year with a qualifier and `—` in Days left. It becomes
  neither 1 January nor 31 December, and never enters a countdown bucket.
- `unknown` renders as **"No exact date"**, never as "Within date".
- Source status text such as `منتهي` appears beside the missing date, never as one.

## 9. Search, filters, sorting, pagination — all server-side

- **Search** covers serial, part number, manufacturer, tag, station, unit, and the raw
  source station name, with the folded form offered so an Arabic query typed one way
  finds the other. `foldName()` mirrors the SQL and is pinned to it by tests and a
  24-name cross-check against a live PostgreSQL. **Search is retrieval, never mapping.**
- **Filters**: Region, Mapping status, Due status, Equipment parent type. They combine
  as an intersection — verified in the browser (East + Overdue).
- **Sorting** puts the requested column **first** and appends `id` as a deterministic
  tie-break, so paging is stable and a secondary `.order()` can never displace the
  primary sort. A test asserts the order of the emitted `.order()` calls.
- **Pagination** uses `.range()` with an RLS-scoped `count: 'exact'`. Nothing loads the
  whole dataset into the browser.

The "Due ≤60d" bucket **includes overdue**, and the label says so — an ambiguous metric
would be worse than none.

## 10. Attention and mapping summary

Seven `head: true` counts over the **whole authorized dataset** — the server returns
numbers and no rows. They describe the dataset, not the active filters; when the table
is filtered to a different number, a line says so explicitly.

A browser-found defect fixed during the pass: the summary originally counted the current
*page*, so it read "Needs mapping 0" while four such records existed.

**A failed count is never a zero.** If any of the seven fails, the strip is replaced by a
sentence saying the summary could not be loaded, and the table continues to work.

## 11. Mapping actions — deliberately DEFERRED

The database enforces more than enough for a safe mapping workflow:

| Guarantee | Enforced by |
| --- | --- |
| Unit belongs to the chosen Station | `irv_unit_station_fk (unit_id, station_id)` |
| Equipment belongs to the chosen Unit | `irv_compressor_unit_fk`, `irv_storage_vessel_unit_fk`, `irv_dispenser_unit_fk` |
| Station belongs to the Region | `irv_station_region_fk (station_id, region_id)` |
| Lifecycle shape per state | `irv_status_shape_ck` |
| Region scope on write | `irv_update` RLS, with both `USING` and `WITH CHECK` |

Verified empirically: an insert naming Station A with Unit B was **rejected** by
`irv_unit_station_fk`. These are re-asserted by **SRV-15**, so if they ever weaken, the
deferred UI must not be built.

**What is missing, and why the UI is deferred anyway:** CLAUDE.md §9 requires every
mapping change to record *who* made it and *when*, retained as audit history with an
actor that cannot be forged. Today:

- there is **no audit trigger** on `installed_relief_valves` (only `set_updated_at`);
- `resolved_by`, `resolved_at` and `mapping_status` are all in the 49 columns granted
  UPDATE to `authenticated`, so a client could write **another user's id** as the
  resolver.

A mapping button whose attribution is forgeable and whose history is not retained is
exactly the unsafe write §23 warns against. Per §23 and the §49 stop condition, the
mutation UI is deferred and the screen offers **no control that changes a mapping** —
asserted by a test. Prompt 12+ should add a `SECURITY DEFINER` mapping function (or an
audit trigger plus column-level grants that exclude the actor columns) before the UI is
built.

## 12. Responsive and accessible

Verified at 1440 / 1024 / 390. Tables scroll inside their own labelled region; the page
body never scrolls sideways at any width. Records never become stacked cards.

Measured: active dataset label 4.64:1, inactive 5.42:1, metric labels and null markers
5.67:1, column headers 5.17:1. One `h1`; `aria-sort` on all five sortable columns; a
live region on the pagination range; every select and button named; every status badge
carries an icon and words so meaning never depends on colour.

## 13. Cargas brand

Unchanged from Prompt 9 (CLAUDE.md §11.6). Brand colour appears only as the active
dataset underline and text (`--brand-strong`) and the focus ring. Mapping and due states
use the independent semantic tokens — **"Resolved" is the teal `ok` token, never Cargas
green**, and NGV yellow never marks Warehouse.

## 14. Verification

| Check | Result |
| --- | --- |
| `scripts/verify-all.sh` | **exit 0** — every step judged by its exit code, not by grep |
| Frontend tests | **245** (217 → 245, +28) |
| Schema assertions | **72** (unchanged) |
| Authorization assertions | **149** (134 → 149, +15 SRV-1…15) |
| Migrations | 29 apply from zero; **no new migration** |
| Browser, both datasets × 3 widths | no page errors, no horizontal page overflow |
| Production counts | all asset tables 0 — unchanged; owner rules intact |

### Deferred to Prompt 12+

- **Mapping mutation UI**, pending non-forgeable attribution and audit history (§11).
- Bulk mapping, which depends on the same workflow.
- The full Data Quality administration system; this screen surfaces live SRV data-quality
  states but does not administer them.
- Repair Kits remain out of scope and are not inferred from warehouse stock.
- Back/Forward could not be exercised in the dev harness, which mounts `MemoryRouter`
  and has no browser history by design; the routes and hrefs that give the production
  router its history integration are verified instead.
