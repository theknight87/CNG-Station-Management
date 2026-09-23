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
