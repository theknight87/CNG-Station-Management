# Audit remediation implementation and handoff

**Date:** 20 September 2026

**Implementation baseline:** `a93b027fa8d1dbab0e3472ce31230c15b9fe9a48`

**Branch:** `codex/audit-remediation-20260920`

**Draft pull request:** `#2` — audit remediation against `claude/stoic-noether-tu4jpm`

**Production mutations:** none

## Implemented in this branch

1. Major authenticated routes and department sections load as separate route chunks. The auth
   shell remains eager and `/auth-test` is development-only.
2. Cloudflare Pages receives repository-owned browser security headers, immutable caching for
   fingerprinted assets, and safe revalidation rules for HTML and the service worker.
3. Mobile registry controls use 44 px touch targets, search no longer collapses on narrow screens,
   and horizontally scrollable tables expose a visible and accessible overflow instruction.
4. Vitest is upgraded from the vulnerable 3.x line to 4.1.11. The remaining audit finding is the
   transitive ExcelJS/UUID advisory, for which npm reports no available fix.
5. Regression tests cover the production route boundary, Cloudflare policy, and table overflow
   affordance. README, authentication, and deployment documentation now distinguish repository,
   deployed, and pending state.

## Verification evidence

- ESLint: pass.
- TypeScript strict build check: pass.
- Vitest: full suite pass; final count is recorded in the audit plan after the last run.
- Production build: pass.
- Initial application chunk changed from 954.92 kB raw / 253.01 kB gzip to approximately
  651.52 kB raw / 188.85 kB gzip. Department code now ships in route chunks.
- Responsive inspection at 390×844: no page-level horizontal overflow; search is 333×44 px;
  tested selects are at least 44 px high; the 1,222 px technical table stays inside its 349 px
  scroll region and displays the overflow cue.
- `npm audit`: two moderate findings, zero high or critical findings; both remaining findings are
  in the ExcelJS-to-UUID dependency chain.

These are local results, not proof that the public Cloudflare deployment contains this branch.

## Claude/operator handoff

Perform these steps in order and preserve every approval gate:

1. Review and merge this branch. Deploy the frontend to a preview first, then verify direct deep
   links, response headers, asset caching, Clerk sign-in, Supabase calls, Web Push, and all major
   route chunks before promoting it.
2. Create the next forward-only migration with the official Supabase CLI. Audit every current RPC
   caller, revoke default function execution from `PUBLIC`, `anon`, `authenticated`, and
   `service_role` where appropriate, then explicitly regrant only the functions each role needs.
   Run reset/catalogue/role tests before any hosted application. Do not invent or renumber the
   migration by hand.
3. **Do not deploy migration 0054.** Resume the existing Prompt 27A procedure for **0055 only**:
   verify the approved file fingerprint, deploy it, run the zero-write warehouse-SRV preview twice,
   compare both results, and stop for owner approval before any commit/import action.
4. After owner fingerprint approval, import the 2,188 warehouse SRVs once and reconcile source,
   staged, committed, rejected, conflict, and unresolved totals. Then process the separately
   approved 308 four-family rows and 325 Unit attributes under their existing evidence rules.
5. Create the production Clerk instance/domain and rotate the Pages build to its production
   publishable key. Replace development-domain CSP allowances with the exact production Frontend
   API origins, verify webhook/session flows, and retain the development-only diagnostic boundary.
6. Run the hosted adversarial role matrix for anon, missing-profile, inactive, viewer, engineer,
   manager, admin, and service role. Re-run Supabase advisors and resolve or explicitly accept each
   finding.
7. Complete the remaining audit program: debounced/cancellable search, cursor pagination,
   measured summary-query consolidation, full mobile table presets/details, monitoring and safe
   errors, CI release gates, and a tested backup/restore runbook with agreed RPO/RTO.

## Non-goals and safeguards

- No production migration, import, mapping decision, Cloudflare deployment, Clerk change, or
  secret rotation was performed by this implementation.
- The changes do not claim live performance improvement until the deployed site is measured again.
- Migration 0055 remains a preview-and-approval workflow, not permission to import automatically.
