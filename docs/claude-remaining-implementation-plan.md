# Claude implementation plan: remaining CNG audit work

Date: 23 September 2026. This handoff follows `codex implementation plan.md` and the original audit remediation program. Recheck the current `main` commit and deployed database before changing anything; counts and hosted state can drift.

## 1. Scope and current evidence

The application uses React, Vite, Supabase Auth/Postgres, and Cloudflare Pages. `CLAUDE.md`, `docs/authentication.md`, and parts of `docs/deployment-cloudflare.md` still describe the former Clerk setup; inspect the running code and Supabase configuration as the current source of truth, then correct the docs. Preserve the project's strict separation from the unrelated Coding System.

The Codex pass implemented region gated Station options; filter IDs/names; shared server page controls for Reports and Audit; compact Alerts; readable technical labels; notification bell naming; `robots.txt`; a 14-function database authorization test matrix; and a six-project Playwright suite. It also added a forward migration permitting only inactive removed-user tombstones without identity, because the existing user removal RPC clears `auth_user_id`. The migration was applied to the verified CNG Supabase project as version `20260923072119`, and the resulting constraint was read back; the destructive user-removal flow was **not** exercised on a live account. No speculative index was added. On disposable UTF-8 PostgreSQL 17.11 databases, all 67 migrations passed both fresh and 53-migration-prefix upgrade replay; `schema_scenarios.sql` passed 344 assertions and `rls_authorization.sql` passed 697 assertions on each. The RLS suite's final rollback exception is expected, and neither suite left fixture users behind. A full local Supabase Auth environment remains unverified. The local Playwright run passed 19 public/setup checks and skipped 180 authenticated checks because no E2E credentials were supplied. Unit tests: 635 passed; lint, typecheck, and production build passed. Check the final merge and verification report for any later corrections.

Known local fixture-browser failures at handoff: dashboard rows wrap badly at 1024 and 390 px (17/19 dashboard checks); the shell fixture has tall rows (29/32 checks); Alerts/Hoses/Notifications fixture scripts cannot render tables because `dev/supabaseStub.ts` does not serve their current summary-view shape; the detector fixture has one mapping-filter expectation failure (57/58). These are not evidence that the authenticated production screens fail; they are unresolved visual/test-harness defects that must be investigated and corrected, not waved away. Production dependency audit reports two moderate `exceljs → uuid` findings, zero high/critical.

## 2. Non-negotiable operating rules

1. Work only in `theknight87/CNG-Station-Management` and its own Supabase project `ypkggegquetvpsflkaxg` / Cloudflare Pages project `cng-station-management`. Never touch the Coding System.
2. Inspect `git status`, current branch, remote `main`, migrations already applied, and deployed asset hash before work. Preserve user changes. Keep each change reviewable.
3. Use test accounts and fixture data for mutations. Do not delete live users, acknowledge real alerts, change roles/mappings, or import historical assets while testing.
4. Never place credentials, JWTs, service-role keys, or test storage state in Git, logs, screenshots, prompts, or a browser bundle. Use environment variables/secret storage.
5. Keep audit logs, source values, date precision, canonical hierarchy, unresolved mappings, and RLS intact. No inferred Station/Unit/equipment links.
6. A migration must be forward-only, reviewed on a disposable database, verified against the actual hosted migration history, and applied to the correct project only. Keep DDL separate from historical data imports.
7. Show measured before/after evidence for performance changes. A low query time on one run is not enough.

## 3. Phase 0: establish a truthful release baseline

### Actions

- Compare the merged commit, local repo, production Pages deployment, and `supabase_migrations.schema_migrations`. Record the exact commit/hash and the latest applied migration. Do not infer deployed state from a file existing in Git.
- Run `npm ci`, `npm run lint`, `npm run typecheck`, `npm test`, `npm run build`, and `npm audit --omit=dev`. Record exit codes and counts.
- Run `npx playwright test` with no secrets to confirm public checks, then with dedicated staging/test credentials for authenticated work. `E2E_BASE_URL`, `E2E_EMAIL`, `E2E_PASSWORD` are the supported inputs; see `.env.e2e.example`. Do not put credentials in chat.
- Run `scripts/verify-all.sh` only against a disposable local PostgreSQL/Supabase instance. Its existing production-equivalent upgrade prefix count must be checked against current hosted migration history, not blindly trusted.
- Save a redacted baseline in `docs/` with screenshots at 1440×900, 1024×768, 390×844, and representative network and SQL timings. Mark any unavailable measurement as unavailable.

### Exit criteria

- One baseline table distinguishes **implemented in code**, **locally verified**, **applied to hosted DB**, **live verified**, and **still pending**. Failures have a reproduction and owner.

## 4. Phase 1: database safety and authorization

### 4.1 Removed-user migration and regression

- Review `supabase/migrations/20260923072119_allow_removed_identity_tombstones.sql` against the current `app_users` constraint and `cng_admin_remove_user` body. Confirm it allows an inactive row with `removed_at` and no identities, but rejects a live identity-less row and an active removed row.
- Replay all migrations from empty and the actual hosted upgrade prefix on disposable databases. Run `supabase/tests/schema_scenarios.sql` and `supabase/tests/rls_authorization.sql`; verify assertion counts, expected rollback sentinel, and absence of any other SQL error. A test function catching any exception must not count unrelated schema errors as authorization success.
- Test user removal with a disposable Supabase Auth account, then assert Auth identity deleted, `app_users` tombstone inactive, region grants removed, and audit actor/summary correct. Also test self removal, last active admin, stale precondition, inactive/missing targets, and non-admin callers. Keep the whole fixture transactional or on staging.
- Confirm the hosted migration remains listed as `20260923072119` with the expected constraint. Do not reapply it. Test the actual remove-user flow only with a disposable staging account.

### 4.2 Full function/role matrix

- Enumerate all 14 Advisor-listed `SECURITY DEFINER` signatures from the current catalog. Compare ownership, `search_path`, EXECUTE grants and actual behavior for `anon`, missing profile, inactive account, viewer, engineer, manager, admin, and `service_role` where relevant.
- Test negative and positive paths with realistic Auth UUID claims. Cover region isolation, alert acknowledgement, admin mutations, Stage B commit, installed-SRV batch, and server-derived actor identity. Test RLS/security-invoker views separately.
- Run Supabase Security Advisor. For any genuine finding, add the smallest forward-only migration with explicit role tests. Do not revoke browser access from a function the live client actually needs; inventory callers first.

### Exit criteria

- Every listed function has an exact signature, tested grants, role behavior, and evidence file. No unauthorized write or cross-region read succeeds. The user-removal path works end to end in staging.

## 5. Phase 2: finish authenticated browser coverage

- Use separate staging accounts for admin, manager, engineer, viewer, and inactive/pending states. Keep authenticated specs read-only on production; use staging for any mutation test.
- Run all six Playwright projects from `playwright.config.ts`: Chromium/Firefox/WebKit desktop and Chromium mobile/Firefox narrow/WebKit mobile. Publish results by project, not just aggregate totals.
- Visit Dashboard, Regions, Stations, both SRV registries, Vessels, Gas Detectors, Hoses, Alerts, each Report, Admin Users, Audit Log, Settings, and detail dialogs. Assert visible heading, resolved loading state, no console/page/network error, reachable actions, no page-level horizontal overflow, and correct role denial.
- Verify the three Station dropdowns make **zero** Station requests before selecting Region, fetch only selected Region after selection, clear stale options on Region change, and do not leak another Region's data.
- Verify Reports and Audit issue exact 50-row ranges when changing pages, show correct counts, reset to page 1 on filter change, and preserve other filters during Audit search. Include empty, one-page, last-page, and count/query-error states. Add a large dataset case; exact count cost belongs in Phase 3.
- Verify Alerts compact row/detail parity, unread bell label, responsive dialogs, SRV page selector, and `/robots.txt` content type and `Disallow: /`.
- Fix flaky selectors and setup only when the test reflects actual supported behavior. Do not make failing assertions disappear by broad skips. Archive traces/screenshots for any remaining failure without storing authentication secrets.

### Exit criteria

- All applicable specs pass on all six projects. Skips are limited to a documented role/data precondition, not a setup failure. The active browser's actual deployed UI matches the merged code.

## 6. Phase 3: measured performance, then minimal query changes

### Capture

- Take three comparable cold and warm runs for Sign In, Dashboard, Alerts, Hoses, Gas Detectors, Reports/Due, and Audit. Record FCP, LCP, CLS, route-to-data-ready time, total/duplicate requests, response sizes, and slowest Supabase endpoints. Use one network/location profile and dataset for before/after.
- Separate frontend bundle/render cost, Auth/session refresh, PostgREST transfer, Postgres execution, and count-query cost. Do not attribute latency to Auth without request timing evidence.
- Collect Supabase Performance Advisor, `pg_stat_statements` top total/mean/calls, `pg_indexes`, table sizes, and redacted `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` for Alerts list/summary, Reports list/summary/export, Hoses, Gas Detectors, Station options, Audit, and RLS membership. Never run `ANALYZE` on mutating statements.

### Change only where evidence supports it

- Add an index only when a measured selective filter, join, ordering, or RLS lookup benefits and an existing index does not already cover it. Record before/after plan, rows scanned, execution time, storage/write cost, and deployment lock strategy. Do not add all ~84 FK indexes or remove ~38 apparently unused ones on Advisor counts alone.
- If exact Reports/Audit page counts dominate latency, compare exact-count, bounded-count, and cursor/keyset options with product needs. Preserve a usable page picker or explicitly obtain a product decision before removing it.
- Debounce high-frequency search fields and cancel/ignore stale requests; ensure latest filter owns the result. Keep export separate from visible-page fetch and preserve the export cap and RLS.
- Consolidate repeated dashboard/summary queries only after measuring identical inputs and checking the security-invoker and RLS behavior. Keep truthful error/unknown states.
- Compare production build chunk sizes and lazy route boundaries; split a genuinely heavy initial chunk if it improves measured LCP without extra initial requests.

### Exit criteria

- Every performance code/migration change has a paired measurement. Target desktop LCP <2 s, CLS <0.05, and no audited route >10% slower across three comparable runs without an explained tradeoff. Record when network conditions make an absolute target unattainable.

## 7. Phase 4: repair visual regressions and fixture checks

- Fix Dashboard's Due matrix at 1024 and 390 px: labels/dates must remain readable, rows compact, with no squeezed letter-by-letter wrapping or giant blank region. Prefer a small-screen layout with meaningful labels and totals over a ten-column micro-grid. Verify the arithmetic stays correct. Compare actual production/staging data and the fixture screenshot.
- Review all major tables at 1440, 1024, 768, 390 and at 200% zoom. Keep each row to essential scanning data, put full data in structured details, and avoid page-level horizontal scrolling. For narrow widths use the existing responsive record/card pattern if necessary; retain labels and keyboard access. Do not hide facts irretrievably.
- Inspect `dev/supabaseStub.ts` against current summary-view shapes; repair Alerts/Hoses/Notifications preview fixtures without changing production counts to fit a fixture. Investigate the detector mapping filter assertion and align the fixture with the canonical mapping status. Run `verify:ui`, `verify:dashboard`, and four direct `verify-*.mjs` scripts using `vite.preview.config.ts`; update obsolete density assertions only after confirming the intended responsive layout.
- Audit modal widths, vertical scrolling, focus return, long IDs, date/time display, table filter wrapping, sidebar auto-collapse, logo size, typography and icon consistency. Capture before/after screenshots; run a keyboard and screen-reader-name pass.

### Exit criteria

- No overlap, clipped control, letter-by-letter heading, unexpected blank viewport, or horizontal document scrollbar. All fixture browser checks pass or a narrowly documented test limitation has a replacement assertion.

## 8. Phase 5: production readiness and documentation

- Update `CLAUDE.md`, `README.md`, `docs/authentication.md`, `docs/deployment-cloudflare.md`, and any linked diagrams to reflect Supabase Auth. Remove obsolete Clerk setup instructions and stale migration/deployment counts while preserving historical decision records as history.
- Verify the production sign-in flow: email confirmation redirect allowlist, password reset, OAuth provider redirects, pending approval, region access, sign-out, expired session, and safe user-facing errors. Test with dedicated accounts.
- Check current Cloudflare `_headers`, CSP, `_redirects`, caching and service worker against the Supabase Auth origins actually used. Verify after deployment with response headers and browser network evidence.
- Add CI gates for lint, typecheck, unit tests, build, SQL migration/tests, public E2E, and safe authenticated staging E2E where secret management permits. Do not require production credentials in PR CI.
- Define monitoring for failed/slow DB requests, Auth errors, Edge Function jobs, Pages build failures, and alert-delivery failures. Use redacted diagnostic IDs and documented operator actions; do not expose SQL/SDK internals to users.
- Document and rehearse backup/restore for this CNG Supabase project: backup source, frequency, restore target, access, RPO/RTO, restore test, and verification of Auth links, regions, and audit records.
- Triage the current `exceljs → uuid` moderate advisory based on whether vulnerable buffer APIs are reachable in this app. Prefer a maintained dependency update or a documented scoped exception; do not downgrade ExcelJS just to make an audit count green.

### Exit criteria

- A new contributor can deploy and recover the current Supabase Auth application from current docs. CI and monitoring report real failures; no credentials appear in build output or repository.

## 9. Phase 6: separate historical data and mapping backlog

This work depends on source evidence and owner decisions and must not be folded into frontend hardening. First reconcile current import history and migration state against the hosted project; older documents mention migration 0055 and warehouse SRV batches but may be stale.

- Inventory unresolved Station, Unit, and equipment-parent mappings, source fingerprints, duplicate/conflict groups, and count reconciliation. Keep unconfirmed values visibly unconfirmed.
- For each proposed batch: produce a zero-write preview, repeat it to prove determinism, review source-to-canonical evidence with the owner, capture an explicit decision/fingerprint, then execute once in a transactionally auditable way. Reconcile staged, committed, rejected, conflicted, and unresolved totals.
- Preserve the physical hierarchy `Region → Station → Unit → Equipment → SRV`. Do not promote source text to a canonical relationship or invent dates/serials.
- If the temporary Station Batch admin surface remains, decide from current workflow evidence whether it is still used; remove only after confirming no pending approved batch, route, or audit dependency remains.

### Exit criteria

- Every imported or mapped row has traceable evidence and audit attribution. Unresolved rows remain visible and honest. No batch is executed solely because it appears in an old plan.

## 10. Suggested Claude task prompts, in order

Give Claude the repository path, this file, `codex implementation plan.md`, and the current merge SHA. Keep the prompts as separate reviewable tasks; each returns changed files, exact tests, results, and unresolved risks.

1. **Baseline and DB gate.** “Inspect current Git/deployment/migration state. Run disposable fresh and upgrade SQL suites; verify the removed-user tombstone migration and 14-function authorization matrix with real Supabase Auth fixtures. Fix only demonstrated defects. Produce a redacted evidence report. Do not touch production data.”
2. **Authenticated E2E.** “Using dedicated staging credentials from environment variables, run all six Playwright projects. Fix real UI/test defects, cover role and region boundaries, Report/Audit pagination, Station request deferral, and mobile dialogs. Preserve read-only production behavior. Report results per project and remaining skips.”
3. **Query performance.** “Measure cold/warm browser timings, `pg_stat_statements`, and representative `EXPLAIN (ANALYZE, BUFFERS)` paths for Alerts, Reports, Hoses, Detectors, Stations, Audit and RLS. Propose and implement only measured query/index changes with before/after evidence and migration tests.”
4. **Responsive product polish.** “Repair the Dashboard Due matrix and empty space, then audit compact tables/details, filters, pagination, sidebar and dialogs at desktop/mobile/zoom. Fix `vite.preview.config.ts` fixture regressions and browser checks. Supply screenshots and accessibility evidence.”
5. **Auth/docs/release.** “Update all Clerk-era documentation to the current Supabase Auth architecture; verify confirmation/reset/OAuth/approval flows and Cloudflare response policy, add CI/monitoring/backup runbook, and triage the ExcelJS advisory. Keep secrets out of Git.”
6. **Historical data (owner-reviewed).** “Reconcile current source and import state, preview unresolved mapping/import batches twice, present evidence and decisions for owner review, then execute only a separately approved batch with complete audit/count reconciliation.”

## 11. Final handoff format

Return: commit/PR links and SHA; migration list and hosted status; files changed by phase; SQL assertion counts and role matrix; six-project E2E table; network/Core Web Vitals before/after; EXPLAIN plans for each index; visual screenshots; current dependency advisories; exact skips and owner decisions. Say explicitly which results are local, staging, and production. Never claim a production improvement from fixture tests alone.
