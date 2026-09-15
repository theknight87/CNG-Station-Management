# Unit workspace (Prompt 10)

*Status: built and browser-verified at 1440 / 1024 / 390. Canonical asset tables are
still empty; the production import is Prompt 21 and has not been performed.*

The Unit workspace is the operational screen at the bottom of the physical hierarchy,
`Region → Station → Unit → Equipment → SRV` (CLAUDE.md §4). Prompt 9 built everything
down to the Unit boundary; this replaces that boundary with the real workspace.

## 1. Route architecture

Sections are **nested routes**, not local tab state — so every section is
deep-linkable, the Back button works, and a future equipment-detail route can hang off
the same tree.

| Route | Section |
| --- | --- |
| `/units/:unitId` | Overview |
| `/units/:unitId/compressor` | Compressor |
| `/units/:unitId/recovery-tank` | Recovery Tank |
| `/units/:unitId/dispensers` | Dispensers |
| `/units/:unitId/storage` | Storage |
| `/units/:unitId/gas-detectors` | Gas Detectors |
| `/units/:unitId/hoses` | Hoses |
| `/units/:unitId/srvs` | SRVs |

Every child path that existed before Prompt 10 is preserved, so no deep link breaks.
`/units/:unitId/srvs` now opens the workspace with the SRVs section selected rather
than the global SRV module — one implementation, not two that could diverge. Prompt 11
owns the global SRV Management workflow.

`/units/:unitId/hoses` is new; the other paths previously rendered Prompt-7
placeholders, which have been deleted rather than left as dead code.

## 2. Query architecture — and why no migration was needed

Every source the workspace needs **already existed**. Migrations 0001–0029 are
untouched and no new database object was created.

| Section | Source | Narrowed by |
| --- | --- | --- |
| Overview counts | `v_unit_summary` | `unit_id` (already loaded by the header) |
| Compressor | `compressors` | `unit_id` |
| Recovery Tank | `v_vessel_management` | `unit_id` + `asset_type='recovery_tank'` |
| Dispensers | `dispensers` | `unit_id` |
| Storage | `v_vessel_management` | `unit_id` + `asset_type='storage_vessel'` |
| Gas Detectors | `v_gas_detector_management` | `unit_id` |
| Hoses | `v_hose_management` | `unit_id` |
| SRVs | `v_unit_srvs` | `unit_id` |

One set-based query per section. Nothing fetches a row in order to count it, nothing
issues a query per row, and nothing loads company-wide assets to filter them in
JavaScript. The tab-strip counts come from the summary row the header already fetched,
so the strip costs **zero** additional queries.

`v_vessel_management` unions storage vessels and recovery tanks behind an `asset_type`
discriminator, so both tabs share one renderer — which is what stops "overdue" drifting
apart between two nearly identical screens.

## 3. Equipment ownership — the URL is not authorization

Every query filters `unit_id = :unitId` against an RLS-protected table or a
`security_invoker` view. The id in the address bar is a **lookup key**: if the caller
cannot read that Unit's Region, the filter matches rows they cannot see and returns
nothing. No asset is ever fetched by its own id and then assumed to belong here.

Asserted in `supabase/tests/rls_authorization.sql` (UNIT-1…16):

| Concern | Guarantee |
| --- | --- |
| Every tab, against a Unit in a foreign Region | returns **no rows** (UNIT-1…6) |
| The Unit itself | produces no summary row, so it cannot even be named (UNIT-7) |
| Tab counts | equal the rows the tab can actually list (UNIT-8, UNIT-9) |
| All four views | `security_invoker`, no `anon` grant, no write grant for any application role (UNIT-14…16) |

A Unit the caller cannot read reports "does not exist, **or** it is outside the Regions
you are authorized for" — deliberately indistinguishable, because confirming existence
is itself the disclosure. Nothing is fetched and then hidden.

## 4. SRV Unit visibility — the critical rule

**The rule lives in SQL, not in the component.** `v_unit_srvs` is defined as:

```sql
unit_id IS NOT NULL
AND mapping_status IN ('resolved', 'needs_equipment_mapping')
```

so the UI cannot show a valve it should not, even if it tried.

| Mapping status | On a Unit tab? | Why |
| --- | --- | --- |
| `resolved` | **shown** | Station, Unit and equipment parent all proven |
| `needs_equipment_mapping` | **shown**, flagged | Station and Unit proven; parent is not |
| `needs_unit_mapping` | **not shown** | the Unit is not proven |
| `needs_station_mapping` | **not shown** | not even the Station is proven |
| `conflict` | **not shown** | excluded by the same predicate; source evidence disagrees |
| warehouse stock | **cannot appear** | a different table, with no `unit_id` or `station_id` at all (UNIT-13) |

### The equipment parent is never guessed

For `needs_equipment_mapping` the parent is genuinely unknown, and the screen says so
rather than filling the column. Specifically:

- `location_raw` (the source's `Stage` or `Storage`) is shown **only** in the expanded
  record, labelled *source context, not an identity*. `Stage` is never rendered as
  though it named a compressor.
- `expected_parent_kind` is shown as a hint, with *which one is unknown* beside it.
- Neither ever populates an equipment foreign key.

A `resolved` valve has **exactly one** equipment parent — asserted as a data property
in UNIT-12, not merely assumed by the renderer.

### `SS-4R3A`

Owner-confirmed as a **Part Number**, not a Serial. It renders in the Part number
column; the serial cell reads "not recorded", because no genuine serial exists. Serials
are never synthesized. Covered by a test that reads the actual rendered cells.

## 5. Due dates and date precision

Due status comes from the views, which use the same `cng_due_status()` the Dashboard
uses — one definition of "overdue" across the product. The buckets are
`overdue · due_today · due_7 · due_15 · due_30 · due_60 · valid · unknown`.

- Only an **exact date** produces a Days-left countdown. A `year_only` date shows its
  year with a "year only" qualifier and a `—` in Days left.
- **`unknown` is never shown as current.** It renders as "No exact date", not "Within
  date" — a valve whose next calibration is a bare year cannot be said to be in date.
- Source status text such as `منتهي` / `منتهية` is shown **beside** the missing date,
  never converted into one and never into a computed compliance status (principle #21).

## 6. NULL, absence, and technical units

- A NULL renders as the quiet marker reading "not recorded" to assistive technology —
  never `N/A`, `Unknown`, `-` or `0`.
- **`not_yet_assigned` is a fact, not a gap** (principle #20): it reads "not yet
  assigned", worded differently from a NULL where the source said nothing.
- **Absence of a record is not missing data.** A Unit with no recovery tank shows an
  empty-state saying so; no placeholder slot is drawn, because nothing in the schema
  says a Unit must have one.
- **Pressures carry the unit the source proved.** `working_pressure_unit`,
  `test_pressure_unit` and `pressure_unit` are real enum columns (BAR or PSI). Nothing
  is converted, and where no unit was proven the number is shown alone rather than
  dressed in a guessed one (§32).

### Fields the schema does not carry

These were considered and **deliberately not shown**, because the columns do not exist
and inventing an empty one would imply the data is merely missing:

| Suggested field | Reality |
| --- | --- |
| Storage/recovery tank **capacity** | no column |
| Storage/recovery tank **design or working pressure** | no column |
| Storage vessel **manufacture year** | no column |
| **Certificate / reference** on any equipment | no column on any equipment table |
| Gas detector **location** | the schema records `area_type` (open/closed) and its raw source text — not a physical position |
| Hose **manufacturer / model** | the schema records a free-text `description` |
| Compressor **inspection / calibration dates** | the compressor table has no date columns at all; its periodic data is running hours and gas sales |

Each is stated in the section's footnote so an engineer knows the field is not recorded
rather than merely empty.

## 7. Equipment detail interaction

A row **expands in place**. §22 requires that no verified source field becomes
unreachable just because it is not in the compact table, and §23 asks for the full
technical record without losing Unit context — an inline disclosure does both, keeps
working at 390px, and avoids modal proliferation entirely. The control carries
`aria-expanded` / `aria-controls` and responds to Enter.

## 8. Unit header and breadcrumbs

The header carries only fields the `units` table actually holds: Unit name, Station,
Region, Job Number. **Manufacturer and model are deliberately absent** — they live on
the equipment records, and copying a compressor's manufacturer onto its Unit would
attach a fact to the wrong entity.

Breadcrumbs are `Regions › East › <Station> › <Unit>`, with **real entity labels**.
A new `BreadcrumbProvider` lets a screen that owns an entity publish the trail once its
data has loaded; until then the path-derived fallback stands, so a UUID is never shown
as a name and nothing is fabricated while loading. Region detail and Station detail now
publish their trails the same way.

## 9. Tabs

Routed `NavLink`s inside a `nav`, **not** an ARIA tab widget — using `role="tablist"`
for real navigation lies to a screen reader about what Enter will do. The active
section is marked three ways, never by colour alone: a 2px underline, a weight change,
and `aria-current="page"`.

**A count is shown only when it is known.** If the summary query failed, the tab strip
is absent entirely rather than showing a row of misleading zeros — a failed count must
never render as `[0]`.

## 10. States

Six distinct outcomes per tab, none of which share a rendering:

| State | Rendering |
| --- | --- |
| Loading | `LoadingState` |
| No records | `EmptyState`, worded per equipment type |
| Filtered no-results (SRVs) | distinct wording plus the filter context |
| Query failure | `ErrorState` with the message and a retry |
| Permission / not found | non-disclosing "does not exist, or is outside your access" |
| Records exist, fields NULL | rows render with "not recorded" per field |

## 11. Responsive

Verified at 1440 / 1024 / 390. The tab strip scrolls rather than wrapping or shrinking
— at 390px eight technical labels cannot fit, and truncating them into ambiguity is
worse than a swipe. Tables scroll inside their own container. **The page body never
scrolls sideways** at any width. No technical field is hidden because the viewport is
narrow, and no table becomes a stack of cards.

## 12. Cargas brand

The Prompt-9 brand system is used unchanged (CLAUDE.md §11.6). Brand colour appears in
the workspace only as the active-tab underline and text (`--brand-strong`, 4.64:1) and
the focus ring. Compliance is stated entirely in the independent semantic status
tokens — **"within date" is the teal `ok` token, never Cargas green**.

## 13. Favicon correction (Prompt 10 pre-flight)

`public/brand/favicon.svg` — a blue `#1d4ed8` gear scaffold placeholder, not Cargas
artwork — has been **deleted** so it cannot be restored by accident. The browser icon
is the Cargas leaf device cropped from the official lockup at its own transparent seam,
served as `favicon.ico` (16/32/48), `favicon-96.png` and `apple-touch-icon.png`.
Verified against the production build: all three return 200, the title is
`CNG Station Management | Cargas`, and no reference to the gear remains in source or
in `dist/`.

## 14. Read vs write

The workspace is **read-only**. No CRUD was invented: no write requirement is
established for these screens, so per §24 and §46 writes are deferred to the
specialized management prompts. Viewer remains read-only; no destructive delete exists
for any role; no new permission was created to make a button useful.

## 15. Verification

| Check | Result |
| --- | --- |
| Frontend tests | 220 passing (27 new) |
| SQL assertions | 72 schema + 134 authorization (16 new), zero failures |
| Migrations | 29 apply from zero; **no new migration** |
| Typecheck / lint / build | clean |
| Browser, 8 sections × 3 widths | no page errors, no horizontal page overflow |
| Deep link to a section | correct tab active, single `aria-current` per nav |
| Keyboard | tab strip reachable, focus ring visible, Enter toggles a row |
| Contrast | active tab 4.64:1, inactive 5.42:1, qualifiers and null markers 5.67:1 |
| Regression | Dashboard, Regions, Stations, Station Detail unchanged, branding intact |
| Production counts | all asset tables 0 — unchanged; owner-confirmed rules untouched |

### Deferred

- Global SRV Management and the warehouse experience — **Prompt 11**.
- A dedicated equipment-detail route (the nested-route tree supports one; the inline
  disclosure covers the need today).
- Repair Kits remain out of scope.
- End-to-end verification against the authenticated hosted app is still blocked by the
  environment's egress policy; the dev harness drives the real components with only the
  Supabase transport stubbed.
