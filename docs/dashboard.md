# Operational Dashboard

The dashboard built in Prompt 8. It answers, in one screen: what is late, what is coming, where
the work is concentrated, and what is still unresolved.

> **Every figure is live.** There is no sample data, no seeded row and no hard-coded total in this
> feature. Before the Prompt 21 import the honest result is a screen of zeros, and the dashboard
> says so in words rather than leaving the reader to guess.

---

## 1. The rule that shaped this feature

**A database error is never rendered as zero.**

A dashboard reporting "0 overdue" because a query failed is a safety system reporting all-clear
while blind. `DashboardState` is a discriminated union — `loading | unconfigured | error | ready`
— so there is no shape in which a failure can present as an empty result, and **one** failing
query fails the whole dashboard rather than leaving four good panels beside one silently-empty
one. Tests `VIEW-1` through `VIEW-4` hold this.

Three states that look similar and mean different things are kept visibly distinct:

| State | Meaning |
| --- | --- |
| Error | the database did not answer. **Nothing is shown**, and the message says it is not a report of zero |
| Empty | the queries succeeded and the database is genuinely empty — stated plainly, with the reason |
| Permission | the account is not active, so nothing is readable. **Not** "the system is empty" |

---

## 2. Metric definitions

| Metric | Definition |
| --- | --- |
| **Overdue** | installed assets whose next inspection/calibration date is before today (Africa/Cairo), across all five due-tracked asset types |
| **Needs attention ≤60d** | overdue **plus** everything due within 60 days. Excludes `valid` and excludes `unknown` |
| **Unresolved mapping** | assets whose `mapping_status` is not `resolved`, live from `v_data_quality_queue` |
| Stations / Units | rows in `stations` / `units` under the caller's RLS scope |
| Installed SRVs | rows in `installed_relief_valves`. **Warehouse valves are not included** |
| Storage Vessels / Recovery Tanks / Gas Detectors / Hoses | rows in their own tables |
| Warehouse SRVs in stock | rows in `warehouse_relief_valves`, reported in a **separate** panel |

Compressors and dispensers are counted by the views but are not surfaced as drill-down tiles:
they have no management module yet, and a tile linking nowhere is a dead affordance.

---

## 3. Due-date classification

The buckets come from `cng_due_status()` — the same function the asset screens use, so the
dashboard cannot drift into a different definition of "overdue".

| Bucket | Column label | Meaning |
| --- | --- | --- |
| `overdue` | Overdue | before today |
| `due_today` | Today | today |
| `due_7` | 1–7 days | within 7 days |
| `due_15` | 8–15 days | 8 to 15 days |
| `due_30` | 16–30 days | 16 to 30 days |
| `due_60` | 31–60 days | 31 to 60 days |
| `valid` | Current | more than 60 days away |
| `unknown` | No exact date | no exact due date exists |

**The buckets are mutually exclusive, not cumulative.** Every asset falls in exactly one, so a row
of the matrix sums to that asset type's total — asserted in the browser at all three viewports,
and by test `DUE-5`. The labels state ranges ("8–15 days") rather than thresholds ("within 15
days") precisely so a cumulative misreading is not available; test `DUE-2` forbids the word
"within" in a bucket label.

---

## 4. Date precision

`unknown` is deliberately distinct from `valid`. A year-only, invalid or missing date is **not**
compliant and **not** overdue — it is simply not known. Conflating it with "Current" would quietly
mark unverifiable equipment as safe.

`cng_days_left()` returns NULL for anything that is not `exact_date`, so a year-only value cannot
enter a day countdown, cannot be classified as due on an invented day, and never becomes 1 January
or 31 December. Test `DUE-3` asserts the "No exact date" bucket is neither `ok` nor `overdue`, and
`MATRIX-3` asserts a year-only population lands there rather than under Current.

---

## 5. Region scoping

`v_dashboard_region_summary` is driven `FROM regions`, whose own RLS decides which rows the caller
sees. **A region outside the caller's scope produces no row at all** — not a zero row — so its
size cannot be inferred from the dashboard.

No region filtering happens in JavaScript. A client-side region filter is decoration, not a
boundary.

Verified by assertions in `supabase/tests/rls_authorization.sql`:

| | |
| --- | --- |
| `DASH-1` | an East-only engineer sees exactly one region in the summary |
| `DASH-2` | an unauthorized region produces **no row** |
| `DASH-3` | asset counts equal the caller's own visible rows, not the table total |
| `DASH-4` | due buckets partition the caller's rows — they sum to the visible total |
| `DASH-5` | an admin sees every region |
| `DASH-6` | an unscoped viewer aggregates **nothing**, not everything |
| `DASH-7` | every dashboard view is `security_invoker` |
| `DASH-8` | `anon` holds no grant on any dashboard view |

---

## 6. Warehouse separation

Warehouse relief valves are inventory. They belong to no Unit, carry no mapping lifecycle, and are
**absent from `v_dashboard_asset_counts` entirely** — so they cannot be added into a station asset
total by accident. They appear only in their own labelled panel, which states the distinction in
the UI itself. Tests `WH-1` and `WH-2` hold this.

Repair Kits remain out of scope and are not represented anywhere.

---

## 7. Data quality

Unresolved mapping work is **surfaced, not hidden** — it is the queue Admin → Data Quality exists
to work, and an unresolved mapping is missing evidence, not a fault. The panel styles it as
`unmapped`, never as an error.

**These are live production counts.** The Prompt 6 dry-run figures (387 unmatched names, 1,599
`needs_station_mapping`, 262, 801) are facts about the source workbooks, not about this database,
and appear nowhere in this feature. Test `DQ-2` fails the build if any of them is ever hard-coded.

---

## 8. Query architecture

Five `security_invoker` aggregate views, added by **migration 0027**. One round trip each, issued
in parallel; no row is fetched in order to be counted.

| View | Shape |
| --- | --- |
| `v_dashboard_asset_counts` | one row per installed asset kind |
| `v_dashboard_due_summary` | asset kind × due bucket |
| `v_dashboard_region_summary` | one row per readable region |
| `v_dashboard_mapping_summary` | asset kind × mapping status |
| `v_dashboard_warehouse_summary` | a single row |

**Why views rather than client-side counting:** at the expected scale (hundreds of stations,
thousands of SRVs) fetching rows to count them would be wasteful — and, far worse, it would put
the region filter in the client. Aggregating in PostgreSQL keeps both the work and the
authorization in the database.

**Security:** every view is `security_invoker = true`, so base tables are read *as the caller* and
their RLS applies. There is no `SECURITY DEFINER`, no privileged aggregation endpoint, and no
service-role use anywhere in the browser. `anon` receives no grant. A row the caller cannot see is
not merely hidden from a list — it is absent from the COUNT, because a total that includes rows
you may not read is itself a leak.

---

## 9. Visual design

Deliberately **not** the four-huge-KPIs-then-two-decorative-charts pattern.

Two tiers: three **attention** metrics lead (overdue, ≤60 days, unresolved), then a compact
inventory strip at secondary weight. An earlier version gave all ten metrics equal weight, so
"197 overdue" competed with "71 hoses" for the same glance — ui-ux-critique-pro flagged it and it
was rebuilt.

Below that: a **due matrix** (asset type × bucket) because the question is "which type is late and
by how much", which a number answers exactly and a bar only approximately; a **region table** with
a small proportional bar as a visual aid *beside* the figure, never instead of it; and the data
quality and warehouse panels.

**No charting library was added.** ui-ux-pro-max's own chart guidance rules a choropleth out for
regions of differing size and for mobile, and recommends a data-table alternative for any
encoded visual. With six regions and five asset types, the table *is* the better answer.

---

## 10. Browser verification

`npm run verify:dashboard` — real Chromium at 1440 / 1024 / 390px. **19/19 checks pass**, covering
no console errors, no horizontal page scroll, dense rows (34px at every width), **due buckets
summing to the row total**, region figures readable as text, no metric tile occupying a phone
screen, and section headings present.

Screenshots in `artifacts/ui/` (git-ignored).

### The real database result

Executed as the real admin user against the live project:

```
regions rows: 6 -> East=0, West=0, Canal=0, Delta=0, Alex=0, Upper=0
asset counts: all nine kinds = 0
due summary rows: 0   mapping summary rows: 0   warehouse: total=0
```

That is the correct, honest state before Prompt 21, and the dashboard renders it as "No
operational records exist yet — the queries succeeded; this is an empty database, not a failure."

### Visual fixtures, and how they are isolated

The populated dashboard was inspected using **fixtures in the dev harness only**
(`dev/preview.tsx?view=dashboard`). They render the REAL panel components, are never written to
Supabase, are never imported by the application, and the production bundle is verified to exclude
the harness entirely.

**The authenticated dashboard route could not be opened in a browser here**, because this
environment's egress policy blocks Clerk — the same limitation recorded in Prompts 5 to 7. The
live data was therefore verified in SQL as the real user, and the rendering of every state by the
component suite.

---

## 11. Deferred

| Item | Phase |
| --- | --- |
| Alerts list behind the attention metrics | Prompt 17 |
| Notification delivery | Prompt 18 — dashboard classification and notification delivery are separate concerns |
| Data Quality resolution workflow | Prompts 10-14 |
| Region context filter on the dashboard | not built — with six regions and RLS already scoping the data, a filter would add a control without adding an answer |
| Historical trend charts | no time series exists; a trend line over one snapshot would be fabricated |
| Opening the authenticated dashboard in a browser | blocked by the egress policy |
