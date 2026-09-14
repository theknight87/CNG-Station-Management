# Architecture — CNG Station Management System

Status: **planning document**. No application code exists yet.
Companion document: [`../CLAUDE.md`](../CLAUDE.md) (isolation rule, data principles).

---

## 1. System overview

A single-page React application served statically from Cloudflare Pages, talking directly
to Supabase PostgreSQL over PostgREST, with Clerk as the identity provider and Supabase RLS
as the authorization boundary. Scheduled work (due-date scanning, notification dispatch)
runs in Supabase Edge Functions triggered by Supabase Cron.

```
        Browser (React + Vite SPA, Cloudflare Pages)
              │                       │
        Clerk SDK                Supabase JS client
        (session,                (PostgREST + Realtime,
         JWT mint)                Clerk JWT in Authorization)
              │                       │
              └──── JWT ──────────────┤
                                      ▼
                         Supabase PostgreSQL  ── RLS policies
                                      ▲
                                      │
             Supabase Cron ──▶ Edge Functions ──▶ Resend (email)
                                              └─▶ Web Push (VAPID)
```

### Why this shape

- **No custom backend.** The data model is CRUD-plus-derived-views; PostgREST + RLS covers
  it without an API tier to secure, deploy, and keep in sync.
- **Authorization in one place.** Every read and write passes through RLS, so a UI bug
  cannot become a data breach.
- **Derived values in SQL.** Days Left and compliance status are computed in views, which
  keeps data principle #13 structurally enforced rather than remembered.

### Trade-off accepted

Direct client→database access means the DB schema is effectively the public API. Column
renames are breaking changes, and complex multi-table writes need `SECURITY DEFINER`
functions rather than ad-hoc transactions. This is accepted for a system of this size; the
escape hatch (an Edge Function acting as an RPC endpoint) exists when needed.

---

## 2. Authentication and authorization

### Identity: Clerk

- Clerk Application: `CNG Station Management` (new — see isolation rule).
- Clerk issues a JWT via a Supabase-targeted JWT template; the Supabase client attaches it.
- Clerk `user_id` is the canonical user key. A local `app_user` table mirrors profile data
  and, crucially, **role and regional scope** — authorization facts live in the database,
  not only in Clerk metadata, so RLS can evaluate them in SQL without trusting a claim the
  client could influence.

### Roles (initial proposal)

| Role | Scope | Capability |
| --- | --- | --- |
| `admin` | global | full read/write, user management, import |
| `regional_manager` | assigned Regions | read/write within scope |
| `station_engineer` | assigned Stations | read/write equipment + maintenance in scope |
| `viewer` | assigned scope | read only |

### RLS model

Every table carries a derivable path to a Region. Rather than denormalizing `region_id`
onto every row (which would create drift), scoping is resolved through a helper:

- `app_user_scope(user_id)` → set of accessible `region_id` / `station_id`.
- Equipment tables resolve their station via their Unit; SRVs resolve theirs via their
  parent equipment.
- Policies are written against `SECURITY DEFINER` helper functions (e.g.
  `current_app_user_has_station(station_id)`) so policy bodies stay short and auditable, and
  so the scoping logic is defined once.

Every table is `ENABLE ROW LEVEL SECURITY` in the same migration that creates it.

---

## 3. Data model (conceptual)

### Hierarchy

```
region (id, code, name)
  └── station (id, region_id, name, job_number NULL, ...)
        └── unit (id, station_id, name, job_number NULL, ...)
              ├── compressor      (unit_id)
              ├── recovery_tank   (unit_id)
              ├── gas_detector    (unit_id)
              ├── dispenser       (unit_id)
              └── storage_vessel  (unit_id)
```

`job_number` is nullable on `station` and `unit` (data principle #4).

### Safety Relief Valves — the polymorphic-parent decision

An SRV belongs to exactly one of: compressor, storage vessel, dispenser. Three options were
considered:

| Option | Verdict |
| --- | --- |
| **A.** Three nullable FK columns + `CHECK` that exactly one is non-null | **Chosen** |
| B. Untyped `(parent_type, parent_id)` pair | Rejected — no referential integrity |
| C. Separate `srv_compressor` / `srv_vessel` / `srv_dispenser` tables | Rejected — triples every query and every policy; aggregate views become a 3-way UNION |

Option A keeps **one SRV table** (satisfying "do not duplicate SRV records"), keeps real
foreign keys, and makes the exactly-one-parent rule a database constraint rather than an
application convention.

```
safety_relief_valve (
  id,
  compressor_id      NULL REFERENCES compressor,
  storage_vessel_id  NULL REFERENCES storage_vessel,
  dispenser_id       NULL REFERENCES dispenser,
  tag_number TEXT, serial_number TEXT NULL, set_pressure NUMERIC NULL,
  last_test_date DATE NULL, next_due_date DATE NULL,
  CHECK (num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 1)
)
```

There is **no** `unit_id` or `station_id` on the SRV row. Location is derived — that is what
prevents an SRV from ever becoming an independent station asset, and what guarantees the
Unit tab and the global module read the same truth.

### Derived location view

```sql
CREATE VIEW srv_full AS
SELECT s.*, u.id AS unit_id, st.id AS station_id, r.id AS region_id,
       (s.next_due_date - CURRENT_DATE) AS days_left
FROM safety_relief_valve s
JOIN <parent resolution> ... JOIN unit u JOIN station st JOIN region r;
```

`days_left` is computed here and nowhere else (principles #12, #13). `NULL` next-due-date
yields `NULL` days left — never `0`, never "overdue".

The same pattern gives `vessel_full`, `gas_detector_full`, `hose_full` for the other global
modules. **All four global modules are views; none of them owns records.**

### Hoses

Hoses attach to dispensers (and, where the source data shows it, to other equipment). Same
principle: single owning table, aggregate view for the global module.

### Traceability and review

Two cross-cutting concerns, applied to every imported table:

- `source_raw JSONB` — the original row as read from the source file (principle #6).
- `needs_review BOOLEAN` + `review_reason TEXT` — set by the importer for ambiguous or
  unmappable records (principles #8, #9). These rows are **imported**, visible, and
  filterable, never dropped.
- `region.raw_value` / per-row raw region text preserved where normalization was applied.

---

## 4. Frontend architecture

- **Vite + React + TypeScript**, React Router for routing.
- **Tailwind CSS + shadcn/ui** for the component layer.
- **TanStack Query** for server state (caching, invalidation) over the Supabase client —
  the data is read-heavy with cross-linked views, which is exactly its case.
- Generated Supabase types (`supabase gen types typescript`) give end-to-end type safety
  from the schema; regenerate on every migration.
- A thin `src/lib/data/*` layer wraps queries so components never hand-build filters, and so
  a schema change lands in one file.

### Route shape

```
/                                  dashboard (due/overdue rollup)
/regions                           region list
/stations/:stationId               station overview
/units/:unitId                     unit overview
/units/:unitId/compressor
/units/:unitId/vessels
/units/:unitId/dispensers
/units/:unitId/gas-detectors
/units/:unitId/srvs                SRV tab — aggregate over unit's equipment
/manage/srvs                       global SRV Management
/manage/vessels
/manage/gas-detectors
/manage/hoses
/admin/users
/admin/import
```

`/units/:unitId/srvs` and `/manage/srvs` render the **same table component** against the
same view with a different filter. Keeping one component is the structural guarantee that
the two never diverge.

---

## 5. Scheduled work, email, and push

- **Supabase Cron** (`pg_cron`) fires a daily job that invokes an Edge Function.
- The function queries the `*_full` views for items crossing notification thresholds
  (e.g. 90/30/7 days before due, and overdue), deduplicates against a
  `notification_log` table, and dispatches.
- **Resend** for email; **Web Push** with this project's own VAPID key pair for browser push.
  Subscriptions live in `push_subscription`, keyed by app user.
- Secrets (`RESEND_API_KEY`, `VAPID_PRIVATE_KEY`, service role key) are Supabase Edge
  Function secrets — never in the repository, never shared with another project.

---

## 6. Proposed file structure

```
cng-station-management/
├── CLAUDE.md
├── README.md
├── .env.example
├── index.html
├── package.json
├── vite.config.ts
├── tailwind.config.ts
├── tsconfig.json
├── components.json                  # shadcn/ui config
├── docs/
│   ├── architecture.md              # this file
│   ├── data-model.md                # ERD + column-level reference
│   ├── data-mapping.md              # source file → column mapping, per source
│   ├── rls-policies.md              # policy catalogue and rationale
│   └── operations.md                # deploy, rotate keys, restore
├── public/
│   └── sw.js                        # service worker (web push)
├── src/
│   ├── main.tsx
│   ├── App.tsx
│   ├── routes/
│   │   ├── index.tsx                # route table
│   │   ├── dashboard/
│   │   ├── hierarchy/               # region → station → unit
│   │   │   └── unit/tabs/           # compressor, vessels, dispensers, detectors, srvs
│   │   ├── manage/                  # srvs, vessels, gas-detectors, hoses
│   │   └── admin/                   # users, import
│   ├── components/
│   │   ├── ui/                      # shadcn/ui primitives
│   │   ├── equipment/               # shared tables/forms reused by tab + global view
│   │   └── layout/
│   ├── lib/
│   │   ├── supabase.ts              # client + Clerk token injection
│   │   ├── clerk.ts
│   │   ├── data/                    # typed query modules, one per domain
│   │   ├── dates.ts                 # days-left / status helpers (display only)
│   │   └── normalize/               # deterministic normalizers (region, etc.)
│   ├── types/
│   │   └── database.ts              # generated from Supabase
│   └── hooks/
├── supabase/
│   ├── config.toml
│   ├── migrations/                  # timestamped, additive
│   ├── functions/
│   │   ├── notify-due-dates/
│   │   └── send-push/
│   └── seed/                        # canonical regions only
└── scripts/
    └── import/                      # source-file importers + dry-run reports
```

---

## 7. Implementation phases

Each phase ends in a deployable state.

**Phase 0 — Documentation and decisions** *(this phase)*
CLAUDE.md, architecture, file structure, risks. No code. **← stopping point**

**Phase 1 — Foundation**
Vite/React/TS scaffold, Tailwind + shadcn/ui, React Router shell, Cloudflare Pages project
and first deploy of an empty shell. New Supabase organization and project created. New Clerk
application created and wired; protected routes working. `.env.example` written.

**Phase 2 — Core schema and RLS**
Migrations for `region`, `station`, `unit`, the five equipment types, `safety_relief_valve`
(with the exactly-one-parent constraint), `hose`, `app_user`. Scope helper functions and RLS
policies on every table. Canonical region seed. Generated TypeScript types.

**Phase 3 — Hierarchy browsing**
Region → Station → Unit navigation, Unit equipment tabs, read-only. Derived `*_full` views
including dynamic `days_left`. Empty and NULL states rendered as genuinely empty.

**Phase 4 — SRV model and the two views**
Unit SRVs tab and global SRV Management, both over `srv_full` with one shared table
component. Filtering, sorting, due-status colouring, CSV export.

**Phase 5 — Remaining global modules**
Vessels, Gas Detector, Hoses management on the same pattern.

**Phase 6 — Write operations**
Create/edit/delete for stations, units, equipment, SRVs. Validation that honours the data
principles (nullable job number, nullable serial, TEXT identifiers). Audit trail.

**Phase 7 — Data import**
Importers under `scripts/import/` with a mandatory dry-run report: rows read, rows mapped,
rows flagged `needs_review` with reason, values normalized and by which rule. `source_raw`
populated. Nothing is imported until a dry-run is reviewed. Admin import UI last.

**Phase 8 — Notifications**
`notification_log`, Edge Functions for due-date scanning, Resend email, Web Push with this
project's VAPID keys, Supabase Cron schedule, per-user preferences.

**Phase 9 — Hardening**
Dashboard rollups, reporting, advisor-clean RLS audit, performance indexes, backup/restore
runbook in `docs/operations.md`.

---

## 8. Architecture risks

| # | Risk | Impact | Mitigation |
| --- | --- | --- | --- |
| A1 | **Clerk↔Supabase JWT integration** is the single point of failure for all authorization; template or key misconfiguration silently degrades to anonymous access | Critical | Deny-by-default policies (no anonymous grants at all); an integration test that asserts an unauthenticated client reads **zero** rows from every table |
| A2 | **RLS policy complexity** — scope resolves through 3–4 joins for SRVs; a wrong policy over-exposes or blocks legitimate access | High | Centralize in `SECURITY DEFINER` helper functions; document each policy in `docs/rls-policies.md`; test matrix of role × scope × table |
| A3 | **RLS performance** — deep scope joins evaluated per row on large aggregate views | Medium | Index every FK; wrap scope lookup in a `STABLE` function so the planner caches it; measure the global SRV view early with realistic row counts |
| A4 | **View-vs-source divergence** — someone "fixes" the global SRV module by adding a table or a `unit_id` column, quietly duplicating records | High | Structural: no `unit_id` on SRV; both surfaces render one component over one view; stated as a rule in CLAUDE.md |
| A5 | **Polymorphic SRV parent** makes generic joins awkward and invites a `parent_type` shortcut later | Medium | `CHECK` constraint plus a resolution view that hides the branching from all callers |
| A6 | **Schema-as-public-API** — client talks straight to PostgREST, so renames are breaking | Medium | All access through `src/lib/data/*`; regenerate types on every migration; additive migrations only |
| A7 | **Derived Days Left recomputed on every read**; also timezone-dependent | Medium | Compute in one view with an explicit date basis; decide and document the reference timezone once |
| A8 | **Edge Function notification duplication or silent failure** — cron retries or an unhandled Resend error can double-send or drop alerts | Medium | `notification_log` with a uniqueness key per (item, threshold, day); failures logged and surfaced in an admin view, not swallowed |
| A9 | **Web Push subscription rot** — expired subscriptions accumulate and every send fails | Low | Prune on 404/410 responses |
| A10 | **Cloudflare Pages SPA routing** — deep links 404 without a catch-all rewrite | Low | `_redirects` configured in Phase 1 and verified with a deep link |
| A11 | **Isolation breach** — a copied env var or a Supabase MCP call aimed at the wrong project silently couples this system to the Coding System | Critical | CLAUDE.md rule; verify project/org name before every hosted-resource operation; secrets generated fresh, never copied |
| A12 | **Role model proves too coarse** (e.g. contractor access to one equipment type) | Medium | Scope stored in the database, not in Clerk metadata, so the model can be extended without an identity-provider migration |

---

## 9. Data-mapping risks

| # | Risk | Impact | Mitigation |
| --- | --- | --- | --- |
| D1 | **Excel `Days Left` columns** are stale and will be read as truth | High | Never import the column at all; `days_left` exists only as a computed view field (principles #12, #13) |
| D2 | **Serial numbers coerced to numbers** — Excel strips leading zeros, converts long digit strings to scientific notation, reformats dashes as dates | High | Read all identifier columns as raw strings at the parser level; `TEXT` columns only; assert no numeric coercion in the dry-run report (principle #11) |
| D3 | **Station/Unit names don't match across source files**, so equipment cannot be attached with certainty | High | Never guess (principle #8): import the row, leave the FK null where required or attach to a placeholder, set `needs_review` with the unmatched raw name, and surface it in a review queue |
| D4 | **Region values outside the known alias list** (typos, mixed script, trailing whitespace, `West ` vs `غرب`) | Medium | Deterministic normalization only; unmatched values keep their raw text and flag the row for review (principle #7) |
| D5 | **Missing Job Number** treated as a validation failure | Medium | `job_number` nullable; no code path blocks Station/Unit creation on it (principle #4) |
| D6 | **Missing serial number** discards an otherwise good asset row | Medium | Serial nullable; row imported and flagged, never rejected (principle #5) |
| D7 | **Date parsing ambiguity** — `03/04/2025` is two different dates; Excel serial numbers vs text dates; mixed formats within one column | High | Detect format per column, not per cell; refuse to import a column whose format is ambiguous and escalate; preserve the raw string in `source_raw` |
| D8 | **Duplicate source rows** (same SRV listed in a station sheet and an SRV register) create duplicate records | High | Deterministic dedupe key (parent + tag/serial) where available; where absent, import both and flag as suspected duplicates for human resolution — never silently merge |
| D9 | **An SRV row that names a Unit but not its parent equipment** — tempting to attach it to the Unit and break the hierarchy rule | High | The `CHECK` constraint makes it impossible; such rows import with `needs_review = true` and no parent assignment pending resolution |
| D10 | **Blank vs "N/A" vs "-" vs `0`** — placeholder text imported as real data | Medium | Explicit placeholder list normalized to `NULL`; `0` for a pressure or a date is **never** treated as a placeholder without evidence (principles #1, #14) |
| D11 | **Merged cells / multi-row headers / trailing total rows** in source spreadsheets shift every column | High | Header detection asserted explicitly per file; dry-run prints the detected header row and a sample mapping for human confirmation before any write |
| D12 | **Unit-of-measure inconsistency** (bar vs psi, mm vs inch) in pressure and size columns | Medium | Store the value and its source unit; convert only in the display layer, and only when the source unit is stated — never infer |
| D13 | **Loss of traceability after import** — no way to answer "where did this value come from?" | Medium | `source_raw JSONB` per row plus an import batch id recording file name, sheet, row number, and import timestamp (principle #6) |
| D14 | **Re-import overwrites human corrections** made in the app after the first load | High | Imports are idempotent by batch and never blind-overwrite a field edited in-app; conflicts go to the review queue |
| D15 | **Valid rows dropped by a strict importer** on the first error | High | Importer is row-resilient: it collects errors and continues, reporting counts; a row is never discarded for a field-level problem (principle #10) |

---

## 10. Open questions for the next phase

1. Source files: which spreadsheets/exports are authoritative, and for which equipment types?
2. Maintenance model: are inspection intervals fixed per equipment type, or per asset?
3. Notification thresholds and recipients per role — confirm before Phase 8.
4. Reference timezone for due-date arithmetic (Africa/Cairo assumed unless stated).
5. Does a Hose attach only to Dispensers, or also to other equipment in the source data?
6. Retention: is historical inspection data being imported, or only current status?
