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

## Prompt 25J-B — the attention summary failed in production; root cause was a seven-way count fan-out

After the Prompt 25J batch, `/manage/srvs/installed` rendered *"The attention summary could not be
loaded, so no counts are shown. The table below is unaffected."* The table itself stayed healthy.

**DIAGNOSED FROM `pg_stat_statements`, NOT FROM THE BANNER.** The strip fired **SEVEN parallel count
queries** at `v_installed_srv_management` (total, overdue, attention, and one per mapping status).
The real browser traffic recorded against that view peaks at **7910.5 ms, 7855.2 ms, 7581.0 ms and
7327.1 ms** — against the `authenticated` role's **`statement_timeout = 8s`**. Whichever query
crossed the line was cancelled (57014), supabase-js returned `.error`, and `useInstalledSummary`
fails the WHOLE strip if ANY of the seven errors — deliberately, because seven metrics where one
silently reads 0 is the same lie in a smaller box. **The table survived because it is one query, not
seven.**

**RULED OUT BY MEASUREMENT, not assumption**: all seven statements were executed READ-ONLY in
production under the owner's real Admin RLS and every one SUCCEEDED — 547 / 1017 / 1047 / 334 / 540
/ 513 / 519 ms, returning 2662 / 302 / 598 / 1608 / 1054 / 0 / 0. So it is not a schema or view
contract fault, not an RPC fault, not an RLS denial, not NULL handling, not due-date logic, not
aggregate logic and not frontend parsing. It is the COST and COUNT of the round trips.

**THE BATCH EXPOSED A LATENT DEFECT; IT DID NOT CREATE ONE.** `irv_select` reads
`CASE WHEN station_id IS NOT NULL THEN cng_can_read_region(region_id) ELSE cng_can_access_unmapped_srv() END`.
Before the batch all 2,662 rows took the second branch — a bare role check with no argument, which
the planner can fold. The 1,054 Station-confirmed rows now take the first, which takes a per-row
argument and is evaluated per row. Measured in production: **0.21 ms/row** on the unconfirmed branch
versus **0.51 ms/row** on the confirmed one, ~2.4x. The fan-out was already marginal at ~7.3-7.9 s;
that shift pushed it over. **Nothing about the 1,054 mapped rows is wrong** — the defect is the
seven-scan pattern, which would have bitten on volume growth alone.

**THE FIX: ONE MIGRATION, 0053, ADDING EXACTLY ONE VIEW** (SHA-256 `18abe4a3…`).
`v_installed_srv_summary` returns all seven counts in a single row, so the screen makes ONE round
trip and the database performs ONE RLS-evaluated scan instead of seven — six fewer chances to trip
the timeout and roughly a seventh of the work. **A migration is genuinely required**: PostgREST
cannot express conditional aggregates, and tallying rows in the browser would risk PostgREST
silently truncating at its row limit, producing counts that are WRONG rather than absent — worse
than a stated failure (§11.5). **Raising `statement_timeout` was deliberately NOT the fix**: a
2,662-row summary has no business taking 8 seconds, and a longer timeout would only let the same
fan-out bite a larger dataset later.

**SECURITY IS UNCHANGED**: `security_invoker = true` is stated explicitly (a replaced view silently
running with owner rights was the Prompt 19B defect), so every count is still the caller's own and a
Region-scoped user can never learn the size of a Region they cannot read. `authenticated` gets
SELECT and nothing else; `anon` gets nothing. No policy, grant, RLS boundary or existing view was
touched, and **no mapping data was changed**.

**REGRESSION TESTS, PROVED TO FAIL AGAINST THE OLD CODE FIRST** (5 of them did). Frontend: the strip
loads from ONE query and fires no per-status count at the row view; the real post-batch mixed state
(1,608 + 1,054 = 2,662, overdue 302, attention 598) renders with BOTH statuses at once; a missing
row and a timeout error are each stated rather than rendered as zeros; and a failed summary never
blanks the table. SQL (SRVSUM-1..11) asserts the view is `security_invoker`, anon-free, write-free,
exactly one row and exactly seven columns, and — the point of the exercise — that **every one of its
seven counts equals the separate query it replaced**, over a dataset deliberately shaped like
production with Station-confirmed and Station-unconfirmed rows coexisting. Due semantics are
re-asserted, not re-derived: attention still INCLUDES overdue, and a `year_only` date enters no
bucket so it can never reach the summary.

**Gate exit 0**: frontend **627 -> 631**, schema **274 -> 285**, authorization 624 unchanged
(correctly — no policy or grant changed), 53 migrations from zero, upgrade replay 52 -> 53.

**MIGRATION 0053 IS NOT DEPLOYED** and production is unchanged: 52 migrations, 0 summary views
deployed, 2,662 SRVs (1,054 `needs_unit_mapping` / 1,608 `needs_station_mapping`), unit and
equipment FKs 0, decisions 281, `asset_mapping_audit` 1,054, `audit_logs` 285, aliases 0, staging
7,163 — and ONE distinct `updated_at` in each of the mapped and unmapped groups, so no row moved.
