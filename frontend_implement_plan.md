# Frontend Redesign — Implementation Plan

**Project:** CNG Station Management (Cargas / NGV)
**Date:** 2026-09-24
**Author:** Claude Code (review and plan). **Implementer:** Gemini (see §9)
**Status:** DRAFT for owner annotation. **No code in this plan has been written.**
**Branch:** `claude/relaxed-galileo-nlezri`

> **Two requested steps did not run, and this plan does not pretend they did.**
>
> 1. **The Codex debate did not happen.** This session has no `/codex-delegate` skill, no `codex`
>    CLI and no OpenAI credentials, so `gpt-6-sol` could not be reached. §11 lists the disputed
>    positions with the strongest counter-argument I could build against each one. Those
>    counter-arguments are mine, not Codex's. §11.3 has the prompt to run the real debate.
> 2. **The plan has not been through Plannotator.** The `/plannotator-annotate` skill and the
>    `plannotator` CLI are not installed here. The document is organised for annotation (numbered
>    sections, stable task IDs, one decision per bullet). §12 has the command.

---

## 0. TL;DR

- The current UI is **sound underneath and messy on top**. The data layer, NULL semantics, status
  vocabulary, brand tokens and accessibility intent are better than most production apps and are
  **kept**. The problems are presentation: no shared form or overlay primitives (61 hand-styled
  `<select>`s), filter UIs that eat the first mobile screen, the identifying column in 5th place,
  flat 30-field detail modals, a dark theme with no switch, developer jargon in user-facing text,
  and a shell with no global lookup.
- **"From scratch" here means a new presentation layer on top of the existing data layer.** Every
  `use*.ts` hook, every Supabase view and RPC, every query and every migration stays the same.
  A redesign that rewrote hooks together with the screens could not prove it kept all the data.
  One that leaves the hooks alone can.
- **"Without losing any data" is enforced mechanically, not by reviewer attention.** Phase 0
  freezes an inventory of every column, detail field, filter, state and action on every screen
  (§3). A test fails if any item disappears. A diff guard fails if a data-layer file changes.
- **Strangler migration, 10 phases, one PR each.** New primitives are built next to the old ones,
  screens move one at a time, and the old primitives are deleted last. Each phase is sized for a
  Gemini session with a written brief, a file allowlist and a command gate.

---

## 1. Non-negotiables (these win over every design suggestion)

Restated from `CLAUDE.md` so the implementer has them in one place. If a task below seems to
conflict with one of these, the task is wrong. Stop and ask.

| # | Rule | Source |
|---|---|---|
| N1 | Hierarchy is `Region → Station → Unit → Equipment → SRV`. Never flattened, never re-parented in UI. | §4 |
| N2 | NULL is shown with `NullValue` (em dash plus sr-only "not recorded"). Never `N/A`, `Unknown`, `-`, `0`, `TBD` or blank. | §6, §11.5 |
| N3 | `year_only` dates show the year only. Only `exact_date` drives days-left and due badges. | §6 #17 |
| N4 | An unresolved mapping is labelled, never hidden, never styled as an error. | §11.5 |
| N5 | Brand colours (`--brand-*`) and status colours (`--status-*`) stay separate namespaces. `scripts/verify-brand.mjs` must pass. | §11.6 |
| N6 | Logo assets are used as supplied. Title stays `CNG Station Management \| Cargas`. | §11.6 |
| N7 | Hiding a control is UX, not security. No authorization logic moves into or out of the frontend. | §10 |
| N8 | No hard-coded counts, no fixture data in `src/`, no fabricated placeholder values. | §6 #1, Prompt 19 |
| N9 | **No change** to `src/**/use*.ts`, `src/lib/supabase/**`, `src/lib/auth/**`, `src/import/**`, `supabase/**`, `scripts/verify-report-contract.mjs`, or any SQL. | this plan |
| N10 | Exit code is the only PASS signal. Test counts never drop without a written justification. | §7a |
| N11 | Density is a feature: 34px table rows, 14px base text, no oversized KPI cards, no gradients or glassmorphism, no decorative motion. | §11.3, §11.4 |

---

## 2. Review and critique

Evidence comes from reading `src/` and from screenshots of the real components rendered by the dev
harness (`dev/preview.html`, Supabase stubbed) at 1440×900 and 390×844. The screenshots are
reproducible with `npx vite --config vite.preview.config.ts` plus the Phase 0 capture script.

### 2.1 What is good and must survive

| Asset | Why it matters |
|---|---|
| `NullValue` / `ValueOrNull` / `PrecisionDate` / `Serial` / `Identifier` / `EntityName` | They encode the data principles. The redesign restyles them and never replaces them with ad-hoc rendering. |
| `statusSemantics.ts` and `StatusBadge` (icon + word + sr-only description) | A correct, colour-independent status vocabulary. |
| Five explicit screen states in `AppStates.tsx` (loading / empty / no-results / error / permission / not-implemented) | Keeps "nothing here", "filtered out", "not allowed" and "failed" apart. |
| Cargas token system in `src/index.css` (sampled, contrast-measured, brand ≠ status) | Documented and verified. Kept as is; only the neutral and typography layers change. |
| Real `<table>` semantics, sticky headers, `aria-sort`, captions, row headers | Keep. |
| Server-side sort, filter and paging in hooks, with a deterministic tiebreak | Keep. The redesign only changes how these are driven. |
| Route-level code splitting (`routes.tsx`) | Keep. |
| The dev preview harness with a Supabase stub | Becomes the visual-regression base (Phase 0). |

### 2.2 Findings

Severity: **S1** blocks the redesign's goals or hurts daily use. **S2** is clear friction.
**S3** is polish.

| ID | Sev | Finding | Evidence |
|---|---|---|---|
| F01 | S1 | **No form or overlay primitive layer.** `src/components/ui/` holds only `button`, `badge` and `card`. There are 61 raw `<select>`s in 18 files and 41 raw `<input>`s, each with the same class string pasted in (`h-7 rounded border bg-background px-1.5 text-sm`). Every visual change has to be made about 100 times. | `grep -c '<select'` across `src/features` |
| F02 | S1 | **Touch sizing depends on CSS keyed to ARIA roles.** Controls are 28px (`h-7`). `index.css` raises them to 44px on mobile through selectors such as `[role='search'] select` and `[role='dialog'] button`. A control outside those roles stays 28px, and renaming a landmark silently breaks touch targets. | `src/index.css` media blocks |
| F03 | S1 | **Registry tables do not lead with identity.** Installed SRVs starts with *Set pressure, Status, Manufacturer, Size*, and *Serial* (the row header) is 5th. Station, Unit, Mapping, Next calibration and Days left sit off-screen to the right at 1440px. An engineer scanning for a valve or a station has to scroll sideways first. | `InstalledSrvSection.tsx` `COLUMNS`; screenshot `d-srvs` |
| F04 | S1 | **Mobile filters bury the data.** On `/manage/srvs` at 390px the first screen is entirely search, 4 selects, a second "smart filter" row of 5 inputs and an error banner. No row is visible without scrolling. | screenshot `m-srvs` |
| F05 | S1 | **Two filter systems on one screen.** `DataToolbar` (selects) plus `SmartFilterBar` (monospace text inputs with placeholders like `contains…`, `e.g. M 3/4" X`) use different heights, fonts and label positions. | `SrvPieces.tsx` `SmartFilterBar` |
| F06 | S2 | **Record detail is a flat modal of up to about 30 facts.** Identity, hierarchy, calibration, source provenance and notes are one undifferentiated list, and the modal hides the table the user was working in. There are 215 `<Fact>` uses with no grouping primitive. | `RecordDetailsDialog.tsx`, `InstalledSrvSection` `detail` |
| F07 | S2 | **Dark theme is dead code.** `.dark` tokens are fully defined and contrast-tuned, but nothing sets the class and there is no theme control. | `grep "'dark'" src` returns nothing |
| F08 | S2 | **The shell offers no global lookup.** The header holds a breadcrumb and the account control. Finding a serial means first knowing its family, opening that module and then searching. About 7k records across 6 families. | `AppHeader.tsx`; screenshots |
| F09 | S2 | **The sidebar collapses by itself on table routes.** `TABLE_WORKSPACE` forces icon-only mode on `/alerts`, `/reports`, `/regions`, `/stations`, `/manage/*` and `/admin/*`. Labels then exist only as `title` tooltips, which never appear on keyboard focus or touch. Navigation changes shape as you move around. | `AppShell.tsx` L13, L64 |
| F10 | S2 | **Developer and process jargon in user-facing text:** "…expected until Prompt 21", "…see docs/srv-management.md". | `AdminDataQualitySection.tsx:318`, `InstalledSrvSection.tsx:358` |
| F11 | S2 | **Duplicated signals in Alerts.** The *Alert* badge ("15 days") and the *Due* badge ("Due ≤15d") say the same thing side by side, and *Days left* is three columns away from *Due*. | screenshot `d-alerts` |
| F12 | S2 | **Inconsistent header casing.** Sortable headers render Title Case ("Serial", "Alert", "Asset") next to UPPERCASE non-sortable ones ("PART NUMBER", "DAYS LEFT"), so sortability reads as a typo. | `DataTable.tsx` `SortableHeader` (the inner button does not inherit transform), screenshots |
| F13 | S2 | **Broken-looking secondary states.** Unit and Station pages render "Photos could not be loaded" as bare red text in an otherwise empty card with a stray rule above it, instead of using `ErrorState`. The Unit "Attention" panel shows one small tile in a half-empty box. | screenshots `d-unit`, `d-station` |
| F14 | S2 | **Mobile record cards have no priority.** Every column becomes a full-width row, the first row is the "Details" eye icon, and one SRV is about 15 rows tall. | screenshot `m-srvs` |
| F15 | S2 | **Filter state is not in the URL.** Filters, sort and page live in `useState`, so a filtered view cannot be shared, bookmarked or restored with Back. | `InstalledSrvSection.tsx` `useState<InstalledQuery>` |
| F16 | S3 | **Typography depends on the operating system.** A system stack only: on Linux it renders as DejaVu, and Arabic comes from whatever font the OS has, so glyph widths, digits and Arabic shaping differ by machine. Tabular numbers are applied only where `.tabular` is added. | `index.css` `body` |
| F17 | S3 | **Hand-rolled focus trap** in `RecordDetailsDialog` and `MobileNav`. It works, but it is duplicated and misses cases Radix handles (inert background, scroll lock, nested portals). | `RecordDetailsDialog.tsx` L17–L60 |
| F18 | S3 | **Hard-coded palette classes in 10 places** (`text-slate-800`, `bg-red-50`, …) bypass the tokens and will not follow dark mode. | grep result |
| F19 | S3 | **Page tabs carry sub-descriptions** ("Valves fitted to station equipment") that double tab height and overflow at 390px. | screenshot `m-srvs` |
| F20 | S3 | **KPI strips come in three shapes** (dashboard cards, SRV `Metric` grid, Alerts inline strip) with different label and number sizes. | screenshots |

---

## 3. What "without losing any data" means, and how it is enforced

A redesign can lose data in four ways. Each gets a guard that runs in the gate.

| Loss mode | Guard | Phase |
|---|---|---|
| **A column or detail field stops being rendered** | **Field Parity Inventory.** `scripts/ui-inventory.mjs` renders every registry and workspace screen in jsdom against the dev stub fixtures and records, per screen: column headers, detail-fact labels, filter controls and their options, sort keys, tabs, actions, and the empty / error / no-results titles. The output is committed to `docs/ui-redesign/inventory.baseline.json`. `src/test/uiParity.test.ts` re-runs it and **fails if any baseline item is missing**. Additions are allowed. A renamed label needs an explicit entry in `docs/ui-redesign/inventory.renames.json`, which the owner reviews. | P0 |
| **A hidden column becomes unreachable** | A column moved out of the default table view (priority 2/3, §5.4) must still be (a) in the column-visibility menu **and** (b) in the detail sheet. The parity test checks "table OR (column menu AND detail)". | P0, P5 |
| **The data layer changes underneath** | **Data-layer freeze.** `scripts/guard-data-layer.mjs` diffs against `main` and fails if any path in N9 changed. An override needs `DATA_LAYER_WAIVER=<reason>` in the PR body and owner approval. | P0 |
| **A state collapses into another** (error shown as empty, NULL shown as 0) | The existing state tests stay. The parity inventory also records which `AppStates` component each screen shows for each stub scenario (`ok`, `empty`, `filtered-empty`, `error`, `denied`), and a changed mapping fails. Plus a forbidden-literal lint (§8.3). | P0, P1 |

The existing tests stay unmodified, except where a test asserts a specific class name or DOM
structure that the redesign replaces. Each such test is **rewritten to assert the same behaviour**,
listed in the PR, and the frontend count never drops (§7a).

---

## 4. Design direction: "Control-room ledger"

A working instrument for engineers: neutral surfaces, data-first, brand at the edges, status in
the rows. It **evolves the Prompt 7/9 foundation, not a different product**. The
`ui-ux-pro-max` design-system query again returned *Exaggerated Minimalism* (oversized type, large
whitespace, scroll-reveal motion). That is rejected for the same §11.4 reasons as in Prompt 7. Its
palette ("industrial slate + stock green"), its density dial (9/10) and its checklist are kept.

### 4.1 Tokens

| Layer | Decision |
|---|---|
| Brand | **Unchanged** (`--brand`, `--brand-strong`, `--brand-deep`, `--brand-yellow`, `--brand-rail`, `--brand-ring`). |
| Status | **Unchanged** values. Add `--status-*-border` so badges stop using `/30` opacity hacks. |
| Neutrals | Keep slate. Add one elevation step (`--surface-raised`) for sheets and popovers, so surfaces separate by value rather than shadow stacks. |
| Spacing | Formalise a 4px scale: `1 = 4px … 6 = 24px`. Page gutter 16px, section gap 12px, control gap 8px. Nothing above 24px inside a working screen. |
| Control height | **32px desktop, 40px below `md`, 44px on touch (`@media (pointer: coarse)`)** through one CSS variable `--control-h` set per breakpoint and pointer type. This replaces the `[role=…]` selectors (F02). |
| Radius | Keep `--radius: 0.25rem`. Badges go from `rounded-full` to `rounded-sm`, matching `StatusBadge`. |
| Type scale | 12 / 13 / 14 (base) / 16 / 18 / 20. One page title size (20), one section size (16). Table headers 12px uppercase, **applied to the `<th>` and its sort button alike** (F12). |
| Numerals | `font-variant-numeric: tabular-nums` on `body` by default, not opt-in. |

### 4.2 Typography (decision D-T; see §11 for the debate)

**Proposal:** self-host **IBM Plex Sans**, **IBM Plex Sans Arabic** and **IBM Plex Mono** through
`@fontsource` packages, bundled by Vite (no CDN, no runtime network request), Latin plus Arabic
subsets, weights 400/500/600 only, `font-display: swap`, with the current system stack kept as the
fallback.

Why: one family with a designed Arabic companion gives matching x-height, stroke and digits across
Arabic Station names and Latin serials (F16). Plex Mono makes serials unambiguous (`0/O`, `1/l`).
The family has an engineering character without being decorative. Cost: about 180–250 KB of
subsetted WOFF2, cached after first load.

This reverses the Prompt 7 "no webfont" decision, so **it is an owner decision**. The fallback, if
rejected, is to keep the system stack and fix only tabular numerals (F16 becomes partially fixed).

### 4.3 Layout: the shell

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [leaf] CNG Station Mgmt │ Region ▸ Station ▸ Unit      [⌘K Find asset…] 🔔 ◐ 👤 │  48px top bar
├──────────┬───────────────────────────────────────────────────────────────┤
│ Dashboard│  Page title                                    [page actions] │
│ ──────── │  Tabs:  Installed | Warehouse | Log | Calibration | Emergency │
│ Regions  │ ┌ Filter bar: [search][Region▾][Status▾][Due▾] [+ More (2)] ┐ │
│ Stations │ │ active chips: Region: East ✕  Due: overdue ✕   Clear all  │ │
│ ──────── │ └───────────────────────────────────────────────────────────┘ │
│ SRVs     │  1,204 of 2,662 · [Columns▾] [Density▾] [Export]              │
│ Vessels  │ ┌ table (identity first) ──────────────────┐┌ Record sheet ──┐ │
│ Detectors│ │ Serial │ Station ▸ Unit │ Status │ …     ││ Identity       │ │
│ Hoses    │ │ …                                        ││ Hierarchy      │ │
│ ──────── │ │                                          ││ Calibration    │ │
│ Alerts   │ └──────────────────────────────────────────┘│ Source         │ │
│ Reports  │  ‹ 1 2 3 … ›                                └────────────────┘ │
│ Admin    │                                                               │
└──────────┴───────────────────────────────────────────────────────────────┘
```

- **Top bar (48px):** logo mark with the 2px brand keyline, breadcrumb, **global asset finder**
  (F08), alert bell, theme switch (F07), account.
- **Sidebar:** labels always visible at `lg` and above (224px). The user may collapse it (the
  preference is remembered), but **route-driven auto-collapse is removed** (F09). When collapsed,
  every item gets a Radix Tooltip that also shows on keyboard focus.
- **Record sheet:** row click, or Enter on the row header, opens a right-side resizable sheet
  (`Sheet`, 420–640px) with the facts in fixed groups. On screens narrower than `xl` it is a
  full-height overlay. It replaces the modal (F06) and keeps the table in view.

### 4.4 Global asset finder (F08)

A `Command` palette (`⌘K` / `Ctrl+K` and a visible button) that searches **through the existing
per-family search hooks** in parallel (installed SRV, warehouse SRV, storage vessel, recovery tank,
gas detector, hose, station, unit). It shows up to 5 hits per family, grouped, and each hit
deep-links to its module with the record sheet open.

- **It does not add a query, view or RPC.** If a family hook cannot be called with a plain search
  term and a page size of 5, that family is left out and listed as a gap. It must not be solved by
  touching the hook.
- RLS decides what comes back, as it already does.

### 4.5 Filter pattern (F04, F05, F15)

One `FilterBar` composite replaces `DataToolbar` plus `SmartFilterBar`:

1. **Primary row:** search, plus at most 3 primary selects chosen per screen (normally Region,
   Status/Due, Mapping).
2. **"More filters (n)"** opens a popover on desktop and a bottom sheet on mobile, holding every
   other existing filter **with the same options and semantics**. The inventory proves nothing
   was dropped.
3. **Active filter chips** appear under the bar, each removable, plus *Clear all*.
4. **The URL is the state.** Filter, sort, page and the open record id sync to `searchParams`
   through a small `useUrlQueryState(schema, defaults)` helper in `src/components/data/`. It maps
   URL ↔ the existing `*Query` objects, so **the hooks receive exactly the object they receive
   today.**
5. On mobile the bar collapses to `[search] [Filters (n)]`, so rows are visible on the first screen.

### 4.6 Registry tables (F03, F12, F14)

`RegistryColumn<T>` gains optional presentation-only fields:

```ts
priority?: 1 | 2 | 3          // 1 always shown; 2 hidden by default below xl; 3 hidden by default
group?: 'identity' | 'hierarchy' | 'technical' | 'due' | 'mapping' | 'source'
mobile?: 'title' | 'subtitle' | 'meta' | 'hidden'   // card slot below md
```

- **Column order rule on every registry:** identity → hierarchy → due/status → mapping → technical
  → source. For installed SRVs: Serial · Station ▸ Unit · Status · Next calibration · Days left ·
  Mapping · Set pressure · Size · Manufacturer · Part number · Last calibration · Warehouse code ·
  Equipment parent.
- A **Columns menu** shows and hides columns (remembered per registry in `localStorage`). Every
  column stays reachable (§3).
- A **density toggle** switches between Compact (34px, the current default) and Comfortable (40px).
- **Mobile cards:** title = identity, subtitle = Station ▸ Unit, a status badge on the right,
  2–4 `meta` pairs, and "Open" to the sheet. No full-width row per field.
- **Drop the eye column.** The whole row is the click target, and the row header is a real link or
  button for keyboard and screen-reader users.

### 4.7 Record sheet groups (F06)

The fixed order for every asset family (a group with no fields is omitted, never shown empty):

1. **Identity:** serial (normalized plus source raw), part number, tag, warehouse code, serial status, duplicate-serial candidate badge
2. **Hierarchy:** Region, Station, Unit, equipment parent, mapping status, expected-parent hint (labelled as a hint)
3. **Technical:** manufacturer, model, size, pressure, capacity, …
4. **Due and history:** last / next date (precision-aware), days left, due badge, source status text, valve history
5. **Source provenance:** file, sheet, row, raw station name, `Location`, notes
6. **Admin tools:** `RecordAdminTools`, unchanged behaviour, admin-only visibility as today

A `FactGroup` primitive (a `<section>` with an `<h3>` and a `<dl>` in 2 columns at `md` and above)
replaces free-floating `<Fact>`s.

### 4.8 Other screens

| Screen | Redesign intent |
|---|---|
| Dashboard | One `MetricStrip` component (F20). The due matrix stays a table (good). Region bars become a proper inline bar with a numeric label. The Data-quality and Warehouse panels use `FactGroup`. No charts added unless the owner asks. |
| Regions / Stations | Station header becomes `EntityHeader` (name, Region, status summary badges, actions). The facts grid loses cell borders in favour of a `dl`. Units table unchanged in content. |
| Unit workspace | Tabs keep their counts. Overview: equipment counts become a compact `MetricStrip`; the Attention tile expands to the full due breakdown, not only Overdue; the photos error uses `ErrorState` (F13). |
| Alerts | Merge the *Alert* and *Due* badge columns into one "Due" column (threshold as the badge, date beside it). Put *Days left* next to it. Read/Ack become an icon + word pair (F11). |
| Reports | Same `FilterBar` and `RegistryTable`. CSV export untouched (it re-runs the authorized query). |
| Admin | Same primitives. Every mutating dialog uses `AlertDialog` with the existing typed-confirmation rules preserved exactly (e.g. station batch). |
| Settings | Notification preferences as a `Switch` list with descriptions. The in-app channel stays non-toggleable and labelled as such. |
| Auth pages | Centered 400px card, logo, same fields and flows. Password reset flows untouched. |

### 4.9 Arabic and mixed direction

- Every entity string goes through `EntityName` (`dir="auto"` plus `unicode-bidi: isolate`). The
  parity test also asserts that entity cells use `EntityName`.
- Arabic names are never truncated with an ellipsis inside table cells. If a name must be
  truncated, it gets `title` and the full text in the record sheet.
- Breadcrumb separators are isolated so `الماظة 1` never reorders its neighbours.
- The layout stays LTR. A full RTL UI is out of scope unless requested.

### 4.10 Copy

- Remove process jargon (F10). "Prompt 21" and `docs/…` paths are replaced with plain operational
  sentences, e.g. "Nothing of this type is waiting for mapping." The docs link, where it helps,
  becomes an admin-only "Why?" disclosure.
- Status and mapping labels come only from `statusSemantics.ts` and `humanize.ts`, with no new
  vocabulary.

---

## 5. Technical architecture

### 5.1 New dependencies (owner approves in P1)

| Package | Purpose |
|---|---|
| `@radix-ui/react-{select,dropdown-menu,dialog,alert-dialog,popover,tooltip,tabs,checkbox,switch,label,separator,scroll-area,toggle-group,visually-hidden}` | Accessible primitives, through shadcn/ui "new-york" (already configured in `components.json`) |
| `cmdk` | Global finder (`Command`) |
| `@fontsource/ibm-plex-sans`, `@fontsource/ibm-plex-sans-arabic`, `@fontsource/ibm-plex-mono` | Only if D-T is approved |
| `@axe-core/playwright` (dev) | Automated a11y gate |

No state or data library is added (no TanStack Query or Table). The hooks stay as they are (N9).

### 5.2 Component map

```
src/components/ui/            shadcn primitives (generated, then token-adjusted)
  button badge card input label select checkbox switch dialog alert-dialog sheet
  popover tooltip tabs dropdown-menu command separator scroll-area toggle-group
src/components/data/          (existing, restyled)  DataTable RegistryTable StatusBadge NullValue …
  + FilterBar.tsx  FilterChips.tsx  ColumnsMenu.tsx  RecordSheet.tsx  FactGroup.tsx
  + MetricStrip.tsx  useUrlQueryState.ts  registryColumns.ts (priority/group helpers)
src/components/layout/        AppShell AppHeader SidebarNav MobileNav (rebuilt on Sheet/Tooltip)
  + GlobalFinder.tsx  ThemeSwitch.tsx  EntityHeader.tsx  PageTabs.tsx
```

### 5.3 Theme

`ThemeSwitch` offers System / Light / Dark. It stores the choice in `localStorage` (`cng.theme`,
wrapped in try/catch like the existing sidebar key) and applies `.dark` on `<html>`. A tiny inline
script in `index.html` applies it before first paint. `verify-brand.mjs` is extended to run its
contrast assertions against both themes.

### 5.4 Legacy removal

Old primitives (`DataToolbar`, `SmartFilterBar`, the eye-column path in `RegistryTable`,
`RecordDetailsDialog`, the role-keyed CSS in `index.css`) are deleted only in P9, after
`grep` shows zero importers.

---

## 6. Phases

Every phase is **one PR**, is **green on its own**, and leaves the app shippable. Every phase ends
with the **Gate** (§8.1). Task IDs are stable so annotations can refer to them.

### P0: Safety net (no visual change)

| ID | Task | Files |
|---|---|---|
| P0.1 | Record baselines: `npm test`, `npm run build`, `tsc` exit codes and counts into `docs/ui-redesign/baseline.md`. Measured while writing this plan: **`npx vitest run` exit 0, 36 files, 671 tests** | docs |
| P0.2 | Build `scripts/ui-inventory.mjs` plus `src/test/uiParity.test.ts` as in §3. Commit `inventory.baseline.json` | scripts, src/test, docs |
| P0.3 | Build `scripts/guard-data-layer.mjs` (N9 path list) and add it to `scripts/verify-all.sh` | scripts |
| P0.4 | Extend the harness: `?theme=dark`, `?state=empty\|error\|denied` for every view. Add `scripts/capture-ui.mjs` (1440 / 1024 / 390, light and dark, 200% zoom) writing to `artifacts/ui/<phase>/` | dev, scripts |
| P0.5 | Add the forbidden-literal test (§8.3) | src/test |

**Done when:** the gate passes, the inventory covers every routed leaf screen in `src/routes.tsx` (redirects excluded), and the guard fails
on a deliberate one-line edit to a hook (proved, then reverted).

### P1: Tokens, type and theme

| ID | Task |
|---|---|
| P1.1 | Add spacing, control-height, `--surface-raised`, `--status-*-border` and type-scale tokens to `index.css` and `tailwind.config.ts`. Existing token values stay the same. |
| P1.2 | Make tabular numerals the default. Fix F18 (replace 10 raw palette classes with tokens). |
| P1.3 | Only if D-T is approved: install `@fontsource` Plex and wire it in `main.tsx` with fallbacks. |
| P1.4 | `ThemeSwitch` plus the pre-paint script. Dark contrast added to `verify-brand.mjs`. |

### P2: Primitive layer

| ID | Task |
|---|---|
| P2.1 | Generate the shadcn primitives in §5.2 and align them to the tokens (32px control, `rounded-sm`, `--brand-ring` focus). |
| P2.2 | A `dev/preview.html?view=kit` page showing every primitive in every state (default, hover, focus, disabled, invalid, loading), light and dark. |
| P2.3 | Unit tests for keyboard behaviour: Select opens on Enter and Space, Esc closes, focus returns to the trigger, Tooltip shows on focus. |

### P3: Shell

| ID | Task |
|---|---|
| P3.1 | Rebuild `AppShell`, `AppHeader`, `SidebarNav` and `MobileNav` on `Sheet` and `Tooltip`. Remove `TABLE_WORKSPACE` auto-collapse (F09). Keep the skip link, keep the `cng.sidebar.collapsed` key, and keep `navigation.ts` role visibility unchanged. |
| P3.2 | Add `ThemeSwitch` and a placeholder slot for the finder to the top bar. Breadcrumb bidi isolation. |
| P3.3 | Update `verify-ui.mjs` and `verify-zoom.mjs` expectations. The no-horizontal-page-scroll assertion stays. |

### P4: Data composites

| ID | Task |
|---|---|
| P4.1 | `FilterBar`, `FilterChips`, `useUrlQueryState` (typed schema → the existing `*Query` object, round-trip tested). |
| P4.2 | `RegistryTable` v2: priority, group and mobile slots, `ColumnsMenu`, density toggle, row activation, `RecordSheet` with `FactGroup`s. The v1 API keeps working (additive props) so screens migrate one at a time. |
| P4.3 | `MetricStrip`, `EntityHeader`, `PageTabs` (no sub-descriptions: they move to the tab's `title` and to the page description) (F19). |

### P5: Registry screens (the biggest phase; may split into P5a/P5b)

Installed SRV · Warehouse SRV · SRV Log / Calibration / Emergency · Storage vessels · Recovery
tanks · Gas detectors · Hoses. For each: reorder columns by the §4.6 rule, assign
priority/group/mobile, move filters to `FilterBar`, move the detail into `RecordSheet` groups, and
update the inventory renames file if any label changes. **All filters, options, sort keys,
columns and facts are kept.**

### P6: Hierarchy screens

Regions list · Region detail · Stations browser · Station overview · Unit workspace plus its 8
sections. Fix F13.

### P7: Dashboard, Alerts, Reports

Dashboard onto `MetricStrip` (F20). Alerts column merge (F11). Reports onto `FilterBar` and
`RegistryTable` v2 while keeping the report-contract script green.

### P8: Admin, Settings, Auth, and the global finder

The admin sections onto the primitives, with **identical confirmation and stale-write
behaviour**. Settings switch list. Auth pages. `GlobalFinder` (§4.4). Copy clean-up (F10).

### P9: Removal and polish

Delete the legacy primitives and role-keyed CSS. Run the full a11y pass (axe: 0 serious or
critical). Final capture set. Update `docs/ui-foundation.md` with a "Redesign 2026-10" section,
and add a baselines row to `CLAUDE.md` §7a.

---

## 7. Acceptance criteria (whole redesign)

1. The gate passes on every phase PR.
2. `uiParity.test.ts` passes with **zero missing baseline items**. Every rename is listed and
   approved.
3. `guard-data-layer.mjs` passes, meaning no N9 path was touched (or an approved waiver exists).
4. The frontend test count is at least the P0 baseline (671 when this plan was written). Schema and authorization suites are
   unchanged, because no SQL changed.
5. axe: 0 serious or critical issues on every harness view, light and dark.
6. At 390px, every registry shows at least 1 data row above the fold with filters collapsed.
7. At 1440px, every registry shows identity, Station/Unit, status and next-due without horizontal
   scrolling.
8. No horizontal page scroll at 390 / 1024 / 1440 or at 200% zoom.
9. `verify-brand.mjs` passes in both themes.
10. **Deployment check (the Prompt 24D lesson):** the final commit is an ancestor of the branch
    Cloudflare Pages builds before anything is called "deployed". Owner browser acceptance is the
    last step.

---

## 8. Verification

### 8.1 The gate (run directly, exit codes only, nothing piped)

```bash
npm run typecheck
npm run lint
npm test                              # count >= baseline
npm run build
node scripts/guard-data-layer.mjs
node scripts/verify-brand.mjs
npx vite --config vite.preview.config.ts --port 5177 &   # harness
node scripts/verify-ui.mjs && node scripts/verify-zoom.mjs && node scripts/capture-ui.mjs
```

The full `scripts/verify-all.sh` (schema and authorization suites against local Postgres) runs at
P0 and P9 as a sanity check. Its counts must be unchanged.

### 8.2 Visual review

Every PR attaches before and after captures from `artifacts/ui/` for the screens it touched.
Claude reviews each Gemini PR against §1, §3 and the phase task list before the owner sees it.

### 8.3 Forbidden-literal test

This test fails if any `.tsx` under `src/features`, `src/components` or `src/pages` renders the
string literals `N/A`, `Unknown`, `TBD`, `n/a`, `Prompt [0-9]`, `docs/` in JSX text, or a numeric
literal inside a `Metric`/`MetricStrip` `value` prop. Comments are excluded.

---

## 9. Gemini as the implementer

### 9.1 Why this plan is shaped for it

Large-context implementers tend to **rewrite more than asked**, **normalise away odd-looking but
deliberate code** (and this codebase is full of deliberate oddities, each with a comment saying
why), **fill gaps with plausible placeholders**, and **"fix" data hooks while touching a screen**.
The guards in §3 make each of those a red test rather than a review finding.

### 9.2 Operating rules (paste these at the top of every Gemini session)

```
You are implementing phase <Pn> of frontend_implement_plan.md in the CNG Station Management repo.
Read CLAUDE.md §4, §6, §10, §11 and frontend_implement_plan.md §1, §3, §4, and the <Pn> section.

HARD RULES
- Touch ONLY the files the phase names, plus tests for them. List every file you changed.
- NEVER edit: src/**/use*.ts, src/lib/supabase/**, src/lib/auth/**, src/import/**, supabase/**, any .sql.
- NEVER remove a column, detail field, filter option, sort key, tab, action or state. Moving one
  is allowed only if uiParity.test.ts still passes.
- NEVER render N/A, Unknown, TBD, "-", 0 or "" for a missing value. Use NullValue / ValueOrNull.
- NEVER introduce a hard-coded count, sample row or fixture in src/.
- Keep existing explanatory comments unless the code they explain is deleted.
- Brand colours (--brand-*) are never status; status colours (--status-*) are never brand.
- Do not add dependencies beyond plan §5.1.
- Success = exit code 0 from every gate command in §8.1. Report the exact test counts.
- If a rule blocks the task, STOP and write the conflict down. Do not work around it.
```

### 9.3 Loop per phase

1. Claude writes a phase brief: tasks, file allowlist, and expected before/after inventory diff.
2. Gemini implements on `redesign/<Pn>` from the redesign branch.
3. Gemini runs the gate and attaches counts and captures.
4. Claude reviews: rules §1, the inventory diff, the guard output, the captures, and a read of the
   diff looking for dropped fields and invented values.
5. The owner annotates or approves, then merges.

### 9.4 Things to spot-check hardest in Gemini PRs

- `detail={…}` blocks moved into `RecordSheet`: count the facts before and after, per registry.
- Filter `<option>` lists moved into `Select`: every `value` string is still present and identical,
  since the hooks switch on them.
- Conditional rendering around `mapping_status === 'needs_station_mapping'` ("Not confirmed"),
  which must survive verbatim in intent.
- `EntityName` on every Arabic-capable cell.
- Admin typed-confirmation strings (e.g. `CONFIRM 281 STATION MAPPINGS`) must be byte-identical.

---

## 10. Risks and open decisions (owner)

| ID | Decision / risk | Recommendation |
|---|---|---|
| D-T | Self-hosted IBM Plex (reverses the Prompt 7 "no webfont" decision) | **Approve.** Consistent Arabic and Latin rendering is worth about 200 KB, cached. |
| D-URL | Filter state in the URL | **Approve.** Shareable, Back-button-safe views. Presentation-only. |
| D-SHEET | Side sheet instead of modal for record detail | **Approve.** It keeps table context. |
| D-SIDEBAR | Remove route-driven auto-collapse | **Approve.** Predictable navigation beats 176px of width. The user can still collapse it. |
| D-FIND | Global finder built only from existing hooks | **Approve,** accepting that a family whose hook cannot serve it is left out rather than adding a query. |
| D-RTL | Full RTL UI mode | **Defer.** Not requested. Arabic content is already handled inline. |
| R1 | Radix portals and focus changes break existing tests that query the DOM shape | Rewrite those tests to assert behaviour. The count never drops. |
| R2 | The P5 diff is large | Split per family (P5a SRVs, P5b vessels, P5c detectors/hoses). |
| R3 | Harness fixtures drift from production shapes | The inventory runs on the stub. `verify-report-contract.mjs` still guards production columns. |

---

## 11. Debate record

### 11.1 Status

**Not held with Codex.** No Codex access in this session (see the banner). The table below is a
**self-adversarial pass**: for each contested position, the strongest objection I could make and
where the plan ends up. Treat it as the agenda for the real debate, not its outcome.

### 11.2 Contested positions

| # | Plan position | Strongest objection | Resolution in this plan |
|---|---|---|---|
| 1 | Freeze the data layer (N9) | "A real redesign should add TanStack Query for caching and dedupe; 75 `useEffect`s are the actual UX problem (spinners on every tab switch)." | **Kept frozen.** Caching is a behaviour change to the data layer, and mixing it into a visual redesign destroys the "no data lost" proof. Recorded as a follow-up track after P9. |
| 2 | Evolve, not replace, the visual language | "The user asked for *from scratch*; keeping slate and 34px rows is a reskin." | **Evolve.** The brand and density rules are owner-mandated (§11.3, §11.6). The from-scratch part is the component and interaction layer (primitives, shell, filters, sheet, finder, theme), which is where the problems are. |
| 3 | Webfont (D-T) | "Prompt 7 rejected webfonts deliberately: no network request, no layout shift, works offline at stations." | Self-hosted and bundled means no third-party request. `swap` plus metric-compatible fallbacks keep layout shift minimal. **Left to the owner.** |
| 4 | Side sheet over modal | "On 1024px a 480px sheet leaves a 544px table; a modal is simpler and already accessible." | Sheet is an overlay below `xl` and docked from `xl` up. It is resizable, and the table keeps its column menu. |
| 5 | URL state | "It adds complexity and risks breaking the page-reset-on-filter logic (the `update()` page:0 rule)." | `useUrlQueryState` preserves that rule explicitly and gets a round-trip test for it (P4.1). |
| 6 | Parity inventory from jsdom plus stub | "Stub fixtures do not cover every conditional field, so the inventory can miss fields that only render for some rows." | P0.2 extends the stub with at least one row per conditional branch (e.g. `needs_station_mapping`, `serial_match` warehouse code, `year_only` dates), and the inventory records labels, not values. |
| 7 | Gemini as implementer | "Use one model end to end; splitting the author and implementer loses intent." | Intent lives in this document and in per-phase briefs, and the guards are mechanical. Claude reviews every phase. |

### 11.3 How to run the real debate

The model name below is written as given in the request. Confirm the exact Codex model ID before
running it.

```bash
codex exec -m "gpt-6-sol" -c model_reasoning_effort="high" --sandbox read-only \
  "Read frontend_implement_plan.md and CLAUDE.md in this repo. Act as an adversarial reviewer.
   For each row of §11.2 and each phase in §6: agree, or disagree with a concrete alternative
   and the evidence (file:line). Separately list anything that could lose data (a field, filter,
   state or NULL semantic) that §3's guards would NOT catch. Output markdown with a verdict per item."
```

Paste its output under a new §11.4 and resolve each disagreement before P0 starts.

---

## 12. Annotation

The plan is ready for Plannotator but has not been annotated (the tool is not installed in this
session). To annotate locally:

```bash
plannotator annotate frontend_implement_plan.md    # or: /plannotator-annotate frontend_implement_plan.md
```

Suggested annotation focus: §10 decisions (approve or reject each), §4.6 column order per
registry, and §9.2 rules for Gemini.
