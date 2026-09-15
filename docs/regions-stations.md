# Regions & Stations — the hierarchy browser (Prompt 9)

*Status: built and browser-verified at 1440 / 1024 / 390. Canonical asset tables are
still empty; the production import is Prompt 21 and has not been performed.*

The physical hierarchy is `Region → Station → Unit → Equipment → SRV` (CLAUDE.md §4).
Prompt 9 builds everything down to the **Unit boundary**. Full Unit Detail — the
equipment tabs and the Unit SRVs tab — is Prompt 10.

## 1. Routes

| Route | Screen | Owns |
| --- | --- | --- |
| `/regions` | `RegionsView` | Regions the caller is authorized for, with their totals |
| `/regions/:regionId` | `RegionDetailView` | one Region's totals plus its Stations |
| `/stations` | `StationsView` | every authorized Station, searchable and filterable |
| `/stations/:stationId` | `StationOverview` | one Station's attributes and its Units |
| `/units/:unitId` | `UnitOverview` | the Unit **boundary** — counts and onward links only |

`/regions/:regionId` is new in Prompt 9. Every other route already existed as a
placeholder from Prompt 7.

## 2. Database layer

Two `security_invoker` views added in migration **0029**:

- **`v_station_summary`** — one row per readable Station with unit, asset, overdue,
  approaching-due and unresolved-mapping counts.
- **`v_unit_summary`** — one row per readable Unit with its equipment counts.

The Regions screen deliberately reuses **`v_dashboard_region_summary`** rather than
adding a second region view. "Overdue" must mean one thing everywhere, and two views
computing it separately is how that stops being true.

Migration **0028** fixed `cng_normalize_name()`, which backs canonical Station and
Unit identity — see `docs/database.md` and the commit message for the defect.

## 3. Authorization — the part that matters

**Region scope is enforced in PostgreSQL, never in JavaScript.** Nothing in
`useHierarchy.ts` filters by region in the browser, because a filter in the browser is
decoration, not a boundary.

Consequences, each asserted in `supabase/tests/rls_authorization.sql` (HIER-1…13):

| Concern | Guarantee |
| --- | --- |
| A Station outside the caller's Regions | produces **no row** — not a zero row, not a redacted row |
| Searching its exact name | returns nothing (HIER-2), so existence cannot be probed string by string |
| Pagination total | computed by `count: 'exact'` **under the same RLS**, so "1–50 of 210" is the caller's own total and never reveals another Region's size (HIER-3) |
| The Region filter dropdown | built from the same RLS-scoped query as the table, so it cannot name a Region the caller cannot read |
| An unreadable Station opened directly by id | renders "Station not found — does not exist, **or** it is outside the Regions you are authorized for". The two are deliberately indistinguishable: confirming existence is the leak |
| An unscoped viewer | sees nothing at all, rather than everything (HIER-8, HIER-9) |

No `service_role` key reaches the frontend. Nothing here writes.

## 4. Search, filtering, sorting, pagination

All four run **server-side**, against the views:

- **Search** matches the stored name OR its folded form, so `الماظه` finds `الماظة`
  and `shobra` finds `Shobra`. Folding is done by `foldName()`, a mirror of the SQL
  `cng_normalize_name()`.
- **Filter** by Region and by attention state (has overdue / has unresolved mapping).
- **Sort** on any of seven columns, always with `station_name` as the tie-break so
  paging is stable. `aria-sort` carries the state; an arrow carries it visually.
- **Paginate** with `.range()`, 50 rows per page.

### `foldName()` is a search aid, never an identity rule

It never decides two names are the same Station, never creates an alias, never
writes. Canonical identity is the generated `normalized_name` column and the unique
constraints over it; resolving an unmatched name is a human decision recorded in
`station_aliases` (CLAUDE.md §8). A false positive shows an engineer one extra row;
it cannot merge two Stations.

It is pinned to the SQL two ways: the nine unit tests in
`src/features/hierarchy/__tests__/foldName.test.ts` assert the **same cases** as the
SQL suite's N1–N8, and the implementations were cross-checked against a live
PostgreSQL over a 24-name corpus (including `ابنوب` vs `ابنوب اسيوط`,
`ابو تيج- اسيوط`, `الادبيه - السويس`) — **all 24 matched exactly**.

## 5. What this UI deliberately does NOT do

Browsing is not a data-quality tool (prompt §29):

- It **never resolves a mapping.** Unresolved assets are surfaced and counted;
  mapping happens in Admin → Data Quality, where the decision is recorded with who
  and when (decision D3).
- It is **not an alias-management system.** No governorate-suffix stripping, no
  merge affordance, no fuzzy auto-resolution.
- It **never creates a default Unit.** A Station with no Units shows an empty Units
  table stating that the Unit structure is unknown — with no "add a Unit" nudge
  (decision D7).
- The 387 Prompt-6 unmatched names remain standing Data Quality work. They are not
  created as Stations here, not merged, not mapped, and their count is **not
  hard-coded** into any production screen.

## 6. Displaying unknown data

- A NULL bay status, job number or note renders as the quiet "not recorded" marker —
  never `N/A`, `Unknown`, `-`, or `0`.
- A **zero is a measured fact**, rendered as a real `0` in muted (not faded) text.
  It is not the missing-data treatment.
- A Station with NULL fields is a **complete record with unknown attributes**
  (principle #19). It is never badged "incomplete" and never visually degraded.
- `needs_review` is stated as a fact about the **source**, beside its reason — not
  styled as damage to the record.
- The raw source value is shown beside a normalized one when they differ
  (principle #6), so an engineer can see what the workbook actually said.

## 7. Arabic

Station and Unit names render through `EntityName` (`dir="auto"` plus bidi
isolation), so Arabic renders correctly inside otherwise left-to-right chrome,
including mixed Arabic/Latin/numeric strings such as `الماظة 1`.

**Names are never truncated into ambiguity.** Tables take their natural width and
scroll inside their own container; the breadcrumb trail scrolls rather than
ellipsing. The page body never scrolls sideways — verified in the browser at all
three widths.

## 8. States

Four zero-row answers, four different renderings — conflating any two sends an
engineer hunting for data that was merely filtered out, or reports all-clear while
blind:

| State | Rendering |
| --- | --- |
| Loading | `LoadingState` |
| Nothing exists | `EmptyState` — "No Stations recorded yet" |
| Nothing matches the filters | `NoResultsState` + a Clear control |
| The query failed | `ErrorState` with the message and a retry |

"Nothing matches" is only claimed after a second, head-only count proves records
exist for this caller. **A database error is never rendered as zero.**

## 9. Verification

| Check | Result |
| --- | --- |
| SQL assertions | 72 schema + 118 authorization, zero failures |
| Frontend tests | 193 passing (26 new for this prompt) |
| `foldName` vs live SQL | 24/24 exact match |
| Typecheck / lint / build | clean |
| Browser, 1440 / 1024 / 390 | no page errors; **no horizontal page overflow** on any screen |
| Sorting | verified monotonic ascending and descending, with correct `aria-sort` |
| Pagination | verified advancing 1–50 → 51–100 of 137 |
| Region filter | verified narrowing the table to a single Region |
| Focus ring | measured `rgb(7,131,63)` = `--brand-strong` |
| Contrast | headers 5.17:1, description 5.67:1, muted zeros and null markers 5.67:1 |
| Production bundle | contains **no** dev fixture strings and no stub |
| Production counts | `stations` 0, `units` 0 — unchanged; no import performed |

### The dev harness

This environment's egress policy blocks both Clerk and Supabase, so the authenticated
app cannot be reached in a browser here. `vite.preview.config.ts` therefore aliases
**only** the Supabase client to `dev/supabaseStub.ts`, so `/dev/preview.html` mounts
the **real** screens, the real hooks and the real state machine with a stubbed
transport. The production build uses `vite.config.ts` and is verified to contain
neither file.

`?view=` selects the screen; `?scenario=empty|error|scoped` reaches the branches that
are otherwise unreachable without a database.

One defect found this way was in the **stub**, not the app: it overwrote a single
sort column instead of applying PostgREST's ordered `.order()` calls in sequence, so
a sort by Assets silently became a sort by name. Fixed in the stub; the application
was correct.
