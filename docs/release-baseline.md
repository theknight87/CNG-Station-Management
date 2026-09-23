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
