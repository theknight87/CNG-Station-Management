# Release baseline — Phase 0 (after Prompt 27A), 2026-09-23

Environment: cloud dev container. Production = Supabase `ypkggegquetvpsflkaxg`, Pages `cng-station-management` (builds from `main`).

## State

| Item | Value | Status |
| --- | --- | --- |
| `main` | `c0b5bcd` | pushed; the Pages build could not be observed from here |
| Work branch | `claude/stoic-noether-tu4jpm` (main + 27A docs + this baseline) | pushed, not merged |
| Hosted migrations | 67, latest `20260923113221 warehouse_srv_import` | applied to hosted DB |
| Undeployed migration files | `0054_irv_station_batch_audit_fix.sql` only | still pending (needs owner decision) |
| Warehouse SRVs | 2,188 imported (27A) | live-verified by owner (screen shows 2,188) |

## Checks (exit codes are authoritative)

| Check | Result |
| --- | --- |
| `npm ci` / lint / typecheck / build | 0 / 0 / 0 / 0 |
| Unit tests | 0 — 32 files, **635 passed** (baseline 635) |
| `npm audit --omit=dev` | 1 — 2 moderate (`exceljs → uuid`), 0 high/critical (triage in Phase 5) |
| `scripts/verify-all.sh` | **0** — 67 migrations from zero; schema **344**, RLS **697**; production-equivalent base 66 (every file except 0054), then upgrade replay 0054, both suites re-pass |
| Playwright, public, Chromium desktop + mobile | 0 — 7 passed, 60 skipped (need `E2E_EMAIL`/`E2E_PASSWORD`) |
| Playwright, Firefox / WebKit projects | **unavailable here** — browsers not installed in this container (installing them is not permitted here); 0 test failures, only launch errors |

## Gate change made in Phase 0

`verify-all.sh` used "the first N migration files" as the production-equivalent base. After 27A that
is false (0055+ deployed, 0054 not). The base is now "every file except `UNDEPLOYED_MIGRATIONS`" and
the upgrade replays exactly that list; SQL baselines raised to 344 / 697.

## Not measured (marked unavailable, not assumed)

- Screenshots at 1440/1024/390 and network/Core Web Vitals timings: need authenticated browser access
  to production or staging (no E2E credentials here; pages.dev has been 403 from this environment).
- Authenticated E2E across all six projects: needs dedicated staging accounts → Phase 2.

## Migration 0054 — impact analysis (NOT deployed, awaiting owner approval)

- **What it changes:** exactly one object. It uses `CREATE OR REPLACE FUNCTION cng_irv_station_batch_commit(text,int,int,text)`
  and adds a COMMENT. There is no DML at migration time: the UPDATE/INSERT statements in the file sit inside the function body. Deploying it
  **modifies 0 rows** in any table.
- **Behaviour change:** only the NEXT future call to the batch commit. That call would record 16 audit figures captured
  before the UPDATE, where the current version re-reads the preview afterwards and records `byte_exact_rows: 0`.
- **Historical data:** the existing audit row `27eb800a…` (25J batch `2fb604cf…`, 1,054 SRVs, `byte_exact_rows: 0`,
  true value 839) is **not modified**. 0054 does not repair history. Live SRV data is untouched.
- **Would it do anything today?** No. The live batch preview reports **0 eligible rows** (1,054 already mapped,
  1,596 with no candidate, 12 cross-Region-only), so a commit after 0054 would be refused at its own gate.
- **Dependency with 0055:** none. 0055 touches only `cng_wrv_import_*` and warehouse tables, and 0054 contains 0
  references to them. The gate applies 0054 on top of the production-equivalent 66 and both SQL suites pass.
- **Dry run:** the production-equivalent replay in `verify-all.sh` (every hosted migration, then 0054) passes. The deployed function
  hash today is `107b62f5…` (0052's body), and 0054 would replace it. A production DDL dry run was deliberately not run.

## E2E credentials — what the suite actually requires

- Exactly **one** account: `E2E_EMAIL` + `E2E_PASSWORD` (plus optional `E2E_BASE_URL`). `e2e/auth.setup.ts` signs in once
  and every project reuses that storage state.
- There is **no** multi-role support and **no** role switching. The suite never changes a role. Admin-only specs
  (`admin-audit`, audit-log pagination) **skip** when the account is not an administrator.
- Therefore: one active **admin** test account covers every spec that exists today. The per-role matrix in
  Phase 2 (manager/engineer/viewer/inactive) would need NEW env variables and spec changes. That work has not been built.

## Phase 3 — database-side measurements (production, read-only)

Method: each query ran 3 times as `authenticated` with the admin's claims (so RLS is enforced), inside a transaction that
always aborts. Times are in ms (run 1, run 2, run 3). The cumulative `pg_stat_statements` figures (mean ~1 s, max ~7.9 s) predate the
0058+ RLS/summary fixes and do NOT describe the current state.

| Query (as admin, RLS on) | rows | ms |
| --- | --- | --- |
| v_dashboard_region_summary | 6 | 649 (cold), 14, 12 |
| v_dashboard_due / asset_counts / mapping | — | ≤16 |
| v_station_summary | 157 | 12, 3, 2 |
| v_installed_srv_summary | 1 | 13, 5, 6 |
| v_installed_srv_management count / page 50 | 2,662 / 50 | 5 / 9 |
| v_warehouse_srv_management count / page 50 | 2,188 / 50 | 194 (cold), 3 / 1 |
| v_report_due_compliance count | 2,941 | 55, 22, 20 |
| v_report_due_summary | 1 | ~23 |
| **v_alert_inbox count** | 704 | **247, 185, 186** |
| v_alert_inbox unread page 50 | 50 | ~18 |
| vessels / hoses / detectors | 191 / 26 / 62 | ≤5 |
| **v_admin_audit_log count / page 50** | 290 / 50 | **~71 / ~75** |

**Two findings. Both costs are linear in row count, so they will grow:**

1. `alerts_select` calls `cng_can_access_unmapped_srv()` **once per row** for the 486 Station-less alerts. EXPLAIN shows 184 ms
   in the seq scan, of which only 39 ms is the stations subplan.
2. `audit_logs_select` calls `cng_is_admin()` / `cng_current_app_user_id()` **once per row**: 69 ms to scan 290 rows,
   about 0.24 ms per row. At 10k audit rows this would reach about 2.4 s.

**Proposed fix (NOT built, pending approval):** wrap the row-independent calls as initPlans, for example
`(SELECT cng_is_admin())` and `(SELECT cng_can_access_unmapped_srv())`. The standard Supabase RLS pattern evaluates them once per statement. These
functions take no row argument, so the semantics are identical. It would be one forward migration replacing two policies, plus RLS
suite assertions and a before/after EXPLAIN.

## 0054 DEPLOYED (owner-approved 2026-09-23)

- Recorded once as `20260923121100 irv_station_batch_audit_fix`. Hosted migrations 67 -> **68**.
- The deployed `cng_irv_station_batch_commit` prosrc MD5 is `e54789f5bdc2f93b14f000af17259197` (8,077 chars), **identical** to
  the locally tested build. It is still SECURITY DEFINER with a pinned search_path, EXECUTE authenticated (admin-gated inside) / anon none.
- **0 production rows changed.** The public-schema write counter (ins+upd+del) was 25,097 before and after. Content hashes of `audit_logs`
  (`cfd81ec0…`) and of installed SRVs' id/station/status (`2194d71a…`) were identical before and after. The historical 25J audit row
  still reads `byte_exact_rows: 0`, untouched by design. The installed-SRV Station batch was NOT re-run.

## Finding — one hosted migration has no repository file

`20260920204210 bootstrap_initial_admin` exists in `supabase_migrations.schema_migrations` but not in
`supabase/migrations/`. It was presumably a one-off data step creating the first admin (Supabase Auth cutover). The repository
therefore cannot rebuild production identically (CLAUDE.md §2.7). It was not touched. Recording it (without any
personal identifiers) or documenting it as intentionally environment-specific is an owner decision for Phase 5.

## E2E coverage status

The signed-in suite uses **one** dedicated active admin account (`E2E_EMAIL` / `E2E_PASSWORD`, supplied through the environment
only, never committed). It does not change that account's role and runs no destructive user-management operation.
**The existing suite provides NO manager / engineer / viewer / inactive role coverage.** Multi-role browser
authorization testing remains an open Phase 2 item and is not complete. Role boundaries are covered only by the SQL suites
(`rls_authorization.sql`, `rls_initplan_perf.sql`).

## Alerts / audit-log RLS performance fix — built locally, NOT deployed

Migration: `supabase/migrations/20260923130000_rls_initplan_alerts_audit.sql`. It changes two policy USING clauses (`ALTER POLICY`).
Name, command, roles and permissive mode are unchanged:

- `alerts_select`: `ELSE cng_can_access_unmapped_srv()` -> `ELSE (SELECT cng_can_access_unmapped_srv())`
- `audit_logs_select`: `cng_is_admin() OR actor_id = cng_current_app_user_id()` ->
  `(SELECT cng_is_admin()) OR actor_id = (SELECT cng_current_app_user_id())`

**Local benchmark** (all migrations; 157 Stations, 5,000 alerts of which 1,500 have no Station, 5,000 audit rows; RLS enforced as admin):

| | before (ms, 5 runs) | after (ms, 5 runs) |
| --- | --- | --- |
| `count(*) v_alert_inbox` | 167, 149, 174, 155, 143 | 17, 18, 18, 15, 15 |
| `count(*) v_admin_audit_log` | 420, 375, 356, 360, 358 | 2.1, 1.5, 1.5, 1.3, 1.3 |
| audit log page (50, newest first) | 355, 376, 342, 348, 343 | 1.9, 1.8, 1.7, 1.8, 1.7 |

**Function calls for ONE statement** (from `pg_stat_user_functions`, `track_functions = all`):

| statement | before | after |
| --- | --- | --- |
| `count(*) FROM alerts` | `cng_can_access_unmapped_srv` = **1,500** | = **1** |
| `count(*) FROM audit_logs` | `cng_is_admin` = **5,000** | = **1** |

`cng_can_read_region` stays at 157 (one per Station in the hashed subplan). It is row-dependent and deliberately unchanged.

**Plan shape:** the Filter now reads `(InitPlan n).col1` instead of calling the function. For example, production's audit scan was
`Filter: (cng_is_admin() OR (actor_id = cng_current_app_user_id()))` at 68.9 ms for 290 rows.

**Authorization identical.** The visible id set (count + MD5 of ordered ids) of `alerts`, `audit_logs`, `v_alert_inbox` and
`v_admin_audit_log` for admin, manager, engineer, viewer, inactive admin and no-subject callers was **24/24 identical**
before and after.

**Regression suite** `supabase/tests/rls_initplan_perf.sql` has **25 assertions**, now part of `verify-all.sh`:
- catalog shape (1-4)
- plan shape, with no per-row Filter call for any of the three functions (5-7)
- an exact visibility matrix over both tables and both views for 8 callers: admin, manager, East/West engineer, East viewer,
  inactive admin, no subject, unknown subject (8-23)
- the unmapped alert is hidden from a Region-scoped engineer (24)
- other users' and service audit rows are hidden from a non-admin (25)

**Proved to detect the defect:** against a database WITHOUT the migration it gives 20 pass / **5 fail**. The failures are exactly
the shape checks 2, 4, 5, 6 and 7; every authorization check passes both ways.

**Gate:** `verify-all.sh` exit 0. There are 68 migrations from zero. Schema 344, RLS 697, rls_initplan_perf 25. The production-equivalent base is 67
files (everything deployed), then the upgrade applies this migration, and all three suites re-pass.

## RLS speed fix DEPLOYED (owner-approved 2026-09-23)

- Recorded as `20260923121735 rls_initplan_alerts_audit`. Hosted migrations 68 -> **69**. No repository migration file is still undeployed.
- The deployed policy text hashes to `ce069db6…`, **identical** to the locally tested database. The old value was `852c588b…`.
- The production plans now read `Filter: ((InitPlan 1).col1 OR (actor_id = (InitPlan 2).col1))` for audit_logs and
  `... ELSE (InitPlan 5).col1 END` for alerts. There are no per-row function calls.
- **Admin visibility is identical.** Alerts 704 rows, id-set MD5 `40bc885b…`; audit 290 rows, `3fba3b2b…`. These are the same before and after.
- Timings as admin with RLS on: alert inbox **347.5 ms -> 38–62 ms**, audit log **98.5 ms -> 0.7–3.5 ms**.
- 0 rows changed (the write counter was 25,097 before and after). Non-admin roles are covered by `rls_initplan_perf.sql`
  (25/25), because production has no non-admin test accounts.

## Known production-only bootstrap migration (owner decision 2026-09-23)

`20260920204210 bootstrap_initial_admin` is a **known, intentional, production-only** migration. It was a one-off step that
bootstrapped the first production admin account during the Supabase Auth cutover. It is deliberately left untouched:
- no repository file is recreated
- the migration history is not repaired
- the initial admin account is not modified

The rebuild requirement is **schema and permission equivalence** with production, which the gate verifies. It is not a
reproduction of how the initial admin was created. A clean rebuild creates its own first admin as part of environment setup.
Any hosted-vs-repository migration comparison should expect exactly this one extra hosted record.

## Phase 1 — database safety and authorization (local; no production change)

**Security Advisor (production, 2026-09-23):**
- 14 × `authenticated_security_definer_function_executable`. Every one is an intended browser RPC that checks authority
  internally: 11 through `cng_require_admin()` or the caller's own grant, and `cng_current_role` / `cng_has_region_grant` answer only
  for the caller. None was revoked, because each has a live frontend caller.
- 1 × **leaked-password protection disabled** (Supabase Auth). This is a dashboard setting and an owner action. It is not a migration.

**14-function matrix:** it already exists as `rls_authorization.sql` workstream H. It covers:
- anon, no app user, inactive, viewer, engineer, manager and admin callers against all 14 functions
- identity helpers answering only for the caller
- fail-closed batch commits

**Removal (Phase 1.1):** 6 new assertions, `P1-REMOVE`. They check that:
- a stale precondition is refused (40001)
- a missing target is refused (42704)
- a second removal of a tombstone is refused (42704)
- refusals change no row and write no audit entry
- an inactive pending user is removable, with exactly one audit row
- that user's retained legacy subject then resolves to no identity, role or data

The last-active-admin guard is **unreachable by construction**: the actor is always another active admin and
self-removal is refused first. It remains as defence in depth.

**Observation (no change made):** `cng_admin_remove_user` clears `auth_user_id` but **keeps a legacy `clerk_user_id`**
on the tombstone. It grants nothing, because the row is inactive and removed, and the test above proves the subject resolves to nothing. It is
recorded only because the constraint comment says tombstones "may clear both identities".

Not done here: an end-to-end removal of a real Supabase Auth account needs a disposable staging account. It is not run against production.

Gate: `verify-all.sh` exit 0. Schema 344, RLS **703** (was 697, +6), rls_initplan_perf 25, 68 migrations from zero,
production-equivalent 68 with nothing pending.

## Phase 4 — layout fixes (sample-data harness, Chromium; not yet on `main`)

**Root cause of most failures:** the Codex responsive pass made every `DataTable` `table-fixed`, with
`break-words` cells, inside a `.table-scroll` set to `overflow-x: hidden`. Wide tables were therefore squeezed until text
broke letter by letter (dashboard grid, serials, "MANUFACTURE/R"). Where squeezing was not enough, columns were
**clipped out of reach**: at 390 px the grid lost Current / No exact date / Total, and the Region table lost Overdue onward. That
contradicted CLAUDE.md §11.3 ("wide tables scroll rather than wrap") and §11.5 (never hide facts).

**Fixes**
- `DataTable` is back to its Prompt 7 shape: content-sized (`w-max min-w-full`), with `whitespace-nowrap` cells and headers. `.table-scroll`
  is `overflow-x: auto`, so a table that cannot fit scrolls inside its own region. The page never scrolls
  sideways. The registries' phone card layout (`responsive-records`) is unchanged.
- Dashboard grid: one table, two densities. Below 640 px the five dated windows fold into one **Due ≤60d** column,
  their exact sum, so each row still adds up to its total. From 640 px up, all buckets show on one line.
- Region table: the decorative proportion bar is hidden below 640 px, and the Assets column carries the number.
- `RecordDetailsDialog` (every registry's details):
  - focus moves into the dialog on open
  - Tab and Shift+Tab stay inside it
  - Escape closes it and returns focus to the control that opened it
  - the title wraps instead of being truncated, so Arabic names stay whole
- `dev/supabaseStub.ts` now serves `v_alert_summary` and `v_hose_summary`, derived clause for clause from the view SQL.
  Alerts and Hoses previously crashed in the harness.

**Check updates (each one reflects the intended design, not a loosened standard)**
- `verify-dashboard`: sums only visible cells, which covers the 5-cell phone row. It also gains **"no table columns are clipped out of
  reach"**, proved to FAIL on the old CSS at 1024 and 390 px.
- `verify-detectors`, `verify-hoses`, `verify-alerts`: facts that the compact registry moved into row details are read from the DOM or
  by opening the details dialog as a user would, and the dialog is closed with Escape. Visible-only assertions still use visible text.
- `verify-alerts`: the "Due date" header was renamed "Due". **"Several columns are sortable" was lowered from ≥5 to ≥4** because
  the compact Alerts table defines 4 sortable columns (Subject moved into details). This is a justified decrease.

**Results:** ui 32/32, dashboard 22/22, alerts 58/58, hoses 63/63, notifications 26/26, detectors 58/58, each exit 0.
Before these fixes: 29/32, 17/19, crash, crash, crash, 57/58. Unit tests **640** (was 635):
- MATRIX-5 checks the folded column
- DIALOG-1..4 all fail against the old dialog
Lint, typecheck and build all exit 0.

**Not covered here:** Firefox and WebKit (not installed in this environment), authenticated production screens (need E2E
credentials), and a 200% zoom pass.

## Phase 4 (cont.) — 200% zoom, Chromium only

Browser scope is **Chromium only**, by owner decision (2026-09-23). The Firefox and WebKit Playwright projects are not
required. `scripts/verify-zoom.mjs` checks 9 preview views at 720×450 CSS px (1440×900 at 200%). It found and proved
two defects:
- a search field collapsing to an icon-sized box in a crowded filter row (Alerts, Hoses, Detectors)
- the Alerts "push not configured" note running past the right edge, because the page header's actions area was `shrink-0`

Fixes:
- a global `min-width: 12rem` on search labels
- the header actions area may shrink and wrap
- page `<h1>` titles wrap instead of being truncated with an ellipsis, since they include Arabic Station names (§11.3)

Before: 3 FAIL. After: 9/9 PASS. All six fixture scripts still pass and unit tests stay at 640.

## Phase 5 — Supabase Auth documentation and response policy

- `docs/authentication.md` has been rewritten for first-party Supabase Auth. The Clerk-era document is kept as
  `docs/authentication-clerk-history.md`. `CLAUDE.md` (§1–3 and §10), `architecture.md`, `deployment-cloudflare.md` and `README`
  no longer describe Clerk as current. The historical prompt records are unchanged.
- The CSP `connect-src` was narrowed from `*.supabase.co` to this project's own host (`ypkggegquetvpsflkaxg.supabase.co`,
  https and wss). Nothing else in `_headers` changed, and it contained no Clerk origin.
- Found: **there is no password-reset flow** in the app (open item, `authentication.md` §6).

## Phase 6a — Stage B2 Station batch (308 rows): deployed, awaiting the owner's click

**Finding (production, read-only):** 1,307 four-family staged rows are not yet canonical. Applying the approved Stage B
rule (exactly one same-Region Station by `cng_normalize_name`) to all of them reproduces the Prompt 26 figure exactly:
**308 undecided rows**, staged `resolved` (268) and `needs_unit_mapping` (40), which Stage B never considered.
- Their staged `station_id` / `unit_id` are 32-hex synthetic dry-run keys: 0 exist in `stations` or `units`.
- **All 268 `resolved` rows sit under a one-Unit Station** with no Unit column in the source and no Unit reason, so their
  Unit is the forbidden one-Unit inference (§4). They are confirmed at **Station level only**, following the 25C ruling.
- 28 are gas-detector **absence** rows. They get a Station decision, and the unchanged asset import blocks them.
- The other 999 undecided rows have no same-Region candidate (746 + 77 absence rows staged `needs_station_mapping`,
  plus 174 staged `needs_unit_mapping`).

**Migration `20260923150000_stage_b2_station_batch`** adds 4 functions and changes nothing else.
- It is hosted as `20260923143224`, bringing production to 70 migrations. File SHA-256 `a86e27be…5a2c`.
- The prosrc MD5 of all 4 functions equals the tested build. Deploying wrote 0 rows (write counter 25,097 before and after).
- The same rules as Stage B apply:
  - admin only, with the actor from `cng_require_admin()`
  - content-bound to the manifest and preview fingerprints
  - refuses rows that are already decided
  - no dynamic SQL
  - `confirmed_unit_id` is always NULL
  - the staged status and the discarded Unit are kept as evidence
- Suite `stage_b2_station_batch.sql`: 30/30 (in the gate).

**Deployed preview**, read twice as the admin with RLS enforced, identical both times, 928 ms:
- 308 rows in 62 groups, all deterministic
- storage vessels 141, recovery tanks 91, gas detectors 54, hoses 22
- resolved 268, needs_unit_mapping 40, absence 28, 0 already decided
- **Preview fingerprint `9ff0975c9e3c5a9fd09869cd91317183099610402bbc5449ccdbecea0616c990`**, manifest `764d3c0f…b8f`

**Execution surface:** `/admin/station-batch` is restored for **B2 only** (Stage B stays committed). The screen uses the same guarded
flow as 22C.1:
- the live preview must equal the constants
- the admin must type `CONFIRM 308 STATION MAPPINGS`
- the action locks after it is used
- an uncertain result is never retried

Remove the screen again once B2 is committed. Frontend tests 640 → **647**.

**Next (6b):** once B2 is committed, the unchanged `cng_asset_import_*` (0049, service_role) will see **280** READY rows and
28 BLOCKED absence rows. Its deployed preview fingerprint then needs a separate owner approval before the one-time import.

**6c — 325 `unit_attributes` rows:** not started yet. This is a separate workflow and needs its own analysis.

## Network opened (2026-09-23): deployment now observed, not inferred

- The session network policy was set to full by the owner, and both `ypkggegquetvpsflkaxg.supabase.co` and `cng-station-management.pages.dev`
  are now reachable from the build environment.
- **The live bundle was inspected directly**: it contains the B2 fingerprint `9ff0975c…`, `CONFIRM 308 STATION MAPPINGS`
  and the phone "Due ≤60d" column. The live `Content-Security-Policy` carries the narrowed `connect-src`. So `main`
  `cbf03d9` is DEPLOYED on Cloudflare Pages, verified at the response level for the first time.
- **E2E test account** created through the normal public sign-up path (no SQL write to Auth, no role set by SQL):
  - it is `app_users` `cd579932…`, an inactive `viewer` created by the `cng_auth_user_sync` trigger, with the email unconfirmed
  - owner steps: confirm the email, then in Admin → Users activate the account and set its role to admin. That route is audited.
  - its credentials exist only in a mode-600 file in the session scratchpad, never in the repository, logs or chat
- Leaked-password protection needs a paid plan. The owner set a minimum length of 8 with complex passwords instead, and the protection stays off.
