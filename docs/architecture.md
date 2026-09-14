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

### Safety Relief Valves — parentage and mapping status

An SRV ultimately belongs to exactly one of: compressor, storage vessel, dispenser. Three
options were considered for modelling that parent:

| Option | Verdict |
| --- | --- |
| **A.** Three nullable FK columns, constrained by `mapping_status` | **Chosen** |
| B. Untyped `(parent_type, parent_id)` pair | Rejected — no referential integrity |
| C. Separate `srv_compressor` / `srv_vessel` / `srv_dispenser` tables | Rejected — triples every query and every policy; aggregate views become a 3-way UNION; unresolved records have no home at all |

Option A keeps **one SRV table** (satisfying "do not duplicate SRV records"), keeps real
foreign keys, and lets the exactly-one-parent rule be a database constraint rather than an
application convention.

#### Why parentage is not unconditionally strict

A strict "exactly one equipment parent, always" constraint is correct for fully resolved
records but **cannot represent historical imported data**, where the source often proves the
Station and no more. Under a strict constraint such a row could only be rejected (violating
principles #9 and #10) or given a fabricated parent (violating principles #1 and #8). Both are
unacceptable, so the constraint is made **conditional on an explicit mapping status** — the
record states how far the evidence goes, and the database enforces the shape that status
implies.

```
installed_srv (
  id                 UUID PRIMARY KEY,

  station_id         UUID NOT NULL REFERENCES station(id),
  unit_id            UUID NULL,
  compressor_id      UUID NULL,
  storage_vessel_id  UUID NULL,
  dispenser_id       UUID NULL,

  mapping_status     srv_mapping_status NOT NULL,   -- resolved | needs_unit_mapping
                                                    -- | needs_equipment_mapping | conflict
  mapping_note       TEXT NULL,        -- why it is unresolved / what the conflict is

  location_raw         TEXT NULL,      -- source `Location` verbatim: 'Stage' | 'Storage'
  expected_parent_kind srv_parent_kind NULL,  -- HINT ONLY: compressor | storage_vessel
                                              -- never populates an equipment FK

  resolved_by        UUID NULL REFERENCES app_user(id),
  resolved_at        TIMESTAMPTZ NULL,

  tag_number         TEXT NULL,
  serial_number      TEXT NULL,        -- TEXT, nullable (principles #5, #11)
  serial_status      serial_status NOT NULL DEFAULT 'unknown',
                                       -- assigned | not_yet_assigned | unknown  (decision D4)
  serial_raw         TEXT NULL,        -- verbatim, even when it is really a part number
  part_number        TEXT NULL,        -- e.g. 'SS-4R3A' relocated here by D4
  source_status_raw  TEXT NULL,        -- e.g. 'منتهية' from a date column (decision D6)
  set_pressure       NUMERIC NULL,
  set_pressure_unit  TEXT NULL,
  last_test_date       DATE NULL,
  last_test_precision  date_precision NOT NULL DEFAULT 'unknown',
  last_test_raw        TEXT NULL,
  next_due_date        DATE NULL,      -- Days Left derived from this, never stored
  next_due_precision   date_precision NOT NULL DEFAULT 'unknown',
  next_due_raw         TEXT NULL,      -- e.g. '2022', 'منتهية', '209/2021'

  source_raw         JSONB NULL,
  import_batch_id    UUID NULL,
  needs_review       BOOLEAN NOT NULL DEFAULT FALSE,
  review_reason      TEXT NULL
)
```

`station_id` is `NOT NULL`: a row is only created once the Station is confidently identified.
Source rows that do not even prove a Station are **not** forced into this table — they land in
the import staging/review queue (§ *Unmappable source rows* below) so that nothing is discarded
and nothing is guessed.

#### Constraint 1 — shape must match mapping status

```sql
CHECK (
  CASE mapping_status
    WHEN 'resolved' THEN
      unit_id IS NOT NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 1
    WHEN 'needs_unit_mapping' THEN
      unit_id IS NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'needs_equipment_mapping' THEN
      unit_id IS NOT NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'conflict' THEN
      num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) <= 1
  END
)
```

This makes every unresolved state **explicit and self-describing**: a NULL parent is never
ambiguous, because the status says whether it means "not yet mapped" or "evidence disputed".
It is impossible to have a half-mapped record that silently reads as resolved, and impossible
for a resolved record to lack a parent.

`conflict` is deliberately the permissive branch — it holds a row whose sources disagree,
including one where a provisional parent was recorded before the disagreement surfaced. It is
never treated as mapped by any view.

#### Constraint 2 — a resolved parent must belong to the stated Unit and Station

A plain FK proves the parent exists, not that it sits in the right Unit. Enforced
declaratively with **composite foreign keys** rather than triggers:

```sql
-- supporting uniqueness on the parents (id is already unique; these make the pairs referenceable)
ALTER TABLE unit            ADD UNIQUE (id, station_id);
ALTER TABLE compressor      ADD UNIQUE (id, unit_id);
ALTER TABLE storage_vessel  ADD UNIQUE (id, unit_id);
ALTER TABLE dispenser       ADD UNIQUE (id, unit_id);

-- on installed_srv
FOREIGN KEY (unit_id, station_id)          REFERENCES unit(id, station_id),
FOREIGN KEY (compressor_id, unit_id)       REFERENCES compressor(id, unit_id),
FOREIGN KEY (storage_vessel_id, unit_id)   REFERENCES storage_vessel(id, unit_id),
FOREIGN KEY (dispenser_id, unit_id)        REFERENCES dispenser(id, unit_id)
```

Under the default `MATCH SIMPLE` semantics a composite FK is **not checked when any of its
columns is NULL**. That is exactly the behaviour required here:

- Parent set (which, by Constraint 1, means `unit_id` is also set) → the pair is checked, so the
  equipment provably belongs to that Unit, and the Unit provably belongs to that Station. The
  chain `SRV → equipment → unit → station` is therefore consistent by construction.
- Parent NULL → the equipment FK is dormant, costing nothing.
- `unit_id` NULL → the unit/station FK is dormant; `station_id` is still guarded by its own
  single-column FK.

So the full strictness applies precisely to resolved records, and no trigger is needed. A later
attempt to move a Unit to another Station, or equipment to another Unit, cannot orphan a
resolved SRV — the composite FK rejects it.

#### Derived location and Days Left

```sql
CREATE VIEW srv_full AS
SELECT s.*,
       COALESCE(c.unit_id, v.unit_id, d.unit_id, s.unit_id) AS effective_unit_id,
       st.region_id,
       CASE WHEN s.next_due_precision = 'exact_date'
             AND s.next_due_date IS NOT NULL
            THEN s.next_due_date - CURRENT_DATE END          AS days_left,
       (s.mapping_status <> 'resolved')                      AS needs_mapping
FROM installed_srv s
JOIN station st          ON st.id = s.station_id
LEFT JOIN compressor c   ON c.id  = s.compressor_id
LEFT JOIN storage_vessel v ON v.id = s.storage_vessel_id
LEFT JOIN dispenser d    ON d.id  = s.dispenser_id;
```

`days_left` is computed here and nowhere else (principles #12, #13). It is NULL unless the due
date is `exact_date` precision — a year-only, unknown or invalid date yields NULL, never `0` and
never "overdue".

Note that `station_id` and `unit_id` on the row are **not a second source of truth competing
with the parent**: for resolved records the composite FKs force them to agree with the parent
chain, so they are a constrained denormalization, not a divergent copy. For unresolved records
they are the only location evidence that exists.

#### Consumers

| Surface | Filter |
| --- | --- |
| Unit → SRVs tab | `unit_id = :unitId AND mapping_status IN ('resolved','needs_equipment_mapping')` — **Unit mapping confirmed only** |
| Station SRV rollup | `station_id = :stationId` (all statuses, unresolved flagged) |
| Global SRV Management | all rows; resolved and unresolved, with a *Needs Mapping* badge and a status filter |
| Admin → Data Quality | `mapping_status <> 'resolved'` plus `needs_review = true`, as a work queue |

One table, one row per SRV, different filters. Both SRV surfaces render the same table
component over `srv_full`.

#### Unmappable source rows

A source row that does not prove even a Station is still never discarded (principle #10). It is
retained in the import staging table with its `source_raw`, its batch/file/row provenance, and
a review reason, and it is surfaced in Admin → Data Quality. It is promoted into
`installed_srv` only when a human confirms its Station.

#### Resolution workflow

Mapping is completed by a human in Admin → Data Quality, or from the SRV record itself:
`needs_unit_mapping` → assign Unit → `needs_equipment_mapping` → assign parent equipment →
`resolved`. Each transition is audited with who and when, and `source_raw` remains untouched
so the original evidence stays inspectable. Nothing auto-promotes.

The same pattern (owning table + aggregate view) gives `vessel_full`, `gas_detector_full`, and
`hose_full` for the other global modules. **All four global modules are views; none of them
owns records.**

#### `expected_parent_kind` — a hint that never becomes a foreign key

Source analysis (`data-quality-report.md` §4) established that the installed-SRV source has no
Unit column and no equipment identifier. Its `Location` column holds only `Stage` (1 805 rows)
and `Storage` (857). The deterministic reading of those values is stored:

| `Location` | `expected_parent_kind` | What it proves | What it does **not** prove |
| --- | --- | --- | --- |
| `Stage` | `compressor` | the parent is a compressor | *which* compressor, or which Unit |
| `Storage` | `storage_vessel` | the parent is a storage vessel | *which* vessel, or which Unit |
| *(absent)* | `NULL` | — | — |

Its only job is to narrow the candidate list in the mapping UI. Constraint 1 still requires
every equipment FK to be NULL unless `mapping_status = 'resolved'`, so a hint physically cannot
leak into parentage: **no import path writes an equipment FK.**

The expected import outcome is therefore:

| `mapping_status` | Expected population at first import |
| --- | --- |
| `resolved` | **0** |
| `needs_equipment_mapping` | rows whose Station resolves to a single-Unit Station |
| `needs_unit_mapping` | rows whose Station resolves only to a multi-Unit Station |
| *(import staging)* | rows whose Station name has no confirmed alias |

#### Prohibited automatic inferences

Forbidden in the importer, in any backfill, and in any later feature:

- mapping an SRV to a Unit from Station-name similarity
- assigning a `Stage` SRV to a specific Compressor, or a `Storage` SRV to a specific Vessel
- distributing SRVs across Units, compressors or vessels by count, order, or balancing rule
- inferring a Dispenser SRV — **none is proven by any current source**
- applying a bulk mapping rule from name similarity or `Location` without explicit confirmation

Each would invent a physical relationship. The `CHECK` constraint blocks the write; this list
states the intent so no one adds a "helpful" backfill later.

#### Mapping workflow (Admin → Data Quality)

Resolution is a product feature with its own screens, not a one-off script.

| Capability | Detail |
| --- | --- |
| Filter | Region · Station · source `Location` · `expected_parent_kind` · `mapping_status` |
| Search | serial number · manufacturer · set pressure |
| Assign Unit | sets `unit_id`; status `needs_unit_mapping` → `needs_equipment_mapping` |
| Assign equipment | sets exactly one parent FK; status → `resolved` |
| Bulk assign | applies one Unit/equipment context to an explicitly selected set |
| Audit | `resolved_by`, `resolved_at`, plus an append-only `asset_mapping_audit` row per change |

**Bulk mapping rules.** The engineer selects specific records and confirms the target context in
a dialogue that restates what will change and how many records it affects. The system may
*suggest* a selection (for example, all `Storage` SRVs at a single-Unit Station) but never
pre-applies one. There is no "apply to all similar" action and no rule persisted for future
imports.

```
asset_mapping_audit (
  id, asset_type, asset_id,
  changed_by UUID REFERENCES app_user(id), changed_at TIMESTAMPTZ NOT NULL,
  from_status, to_status,
  from_unit_id, to_unit_id, from_parent_kind, to_parent_id, to_parent_kind,
  is_bulk BOOLEAN NOT NULL, bulk_batch_id UUID NULL,
  note TEXT NULL
)
```

**Who may map (decision D8).** `admin` and `regional_manager` may map anywhere;
`station_engineer` may map **only within their authorized Regions**; `viewer` not at all. This is
enforced in **RLS** on the mapping columns, not only in the UI — an out-of-scope `UPDATE` fails at
the database. A bulk action never silently skips out-of-scope records; it reports them.

Audit rows are append-only and never touch `source_raw`: the original evidence and the human
decision are separately inspectable, so a wrong mapping can be traced and reversed.

### Canonical Station and Unit identity

`Station data base.xlsx` is **not** the Station master. Its name column mixes unit-level names
(`شبرا 1`…`شبرا 4`) with station-level names, so one row does not equal one Station
(`data-quality-report.md` §3). Identity is reconciled across sources instead:

```
raw source name ──▶ station_aliases ──▶ canonical station
   (+ file, region)     (explicit row)
```

```
station_alias (
  id,
  raw_name        TEXT NOT NULL,      -- verbatim, including qualifiers and spacing
  normalized_name TEXT NOT NULL,      -- NFKC + Arabic folding; for lookup, not identity
  region_id       UUID NOT NULL REFERENCES region(id),
  source_file     TEXT NOT NULL,
  station_id      UUID NULL REFERENCES station(id),   -- NULL until confirmed
  alias_status    alias_status NOT NULL,  -- confirmed | proposed | rejected
  confirmed_by    UUID NULL REFERENCES app_user(id),
  confirmed_at    TIMESTAMPTZ NULL,
  UNIQUE (raw_name, region_id, source_file)
)
```

`unit_alias` follows the same shape and is introduced when the analysis of numbered names
(`الخمائل 1` — unit of `الخمائل`, or its own Station?) is settled.

Rules:

- **Runtime resolution reads `station_alias` only.** Fuzzy matching runs once, in the review UI,
  to *propose* aliases. It never resolves a lookup at runtime and never writes a confirmed row.
- An unmatched name produces an **import issue**, not a merge and not a silent new Station.
- A proposed alias never attaches data; only `alias_status = 'confirmed'` does.
- Confirming an alias is audited like a mapping change.

This means a station name can be spelled four ways across four files and still resolve to one
canonical Station — with every spelling preserved and every link traceable to the person who
confirmed it.

#### Deterministic identity rules (decisions D1, D2)

Two owner-confirmed rules may create aliases without human review, each recorded with its
provenance in `station_alias.alias_source`:

| `alias_source` | Rule | Guard |
| --- | --- | --- |
| `rule:governorate_suffix` | strip a trailing governorate qualifier (`ابنوب اسيوط` → `ابنوب`) | applied only when the remainder resolves to **exactly one** Station in that Region |
| `rule:numbered_unit` | `<base> <n>` is Unit *n* of Station `<base>` (`الخمائل 1` → Unit 1 of `الخمائل`) | applied only when `<base>` resolves to **exactly one** Station |

Ambiguity never fires a rule: it produces a proposal plus an import issue. Because provenance is
stored per alias, every rule-created alias can be listed, audited, and reversed as a set if the
rule is later found wrong — which is the property that makes automating them acceptable at all.

`alias_source` values: `rule:governorate_suffix` · `rule:numbered_unit` · `human` ·
`import_exact_match`.

### The unit-unknown pattern (decision D7)

**There is no default single Unit.** Where a source proves a Station but not a Unit, `unit_id`
stays `NULL` — a Unit named after its Station is never invented to give assets somewhere to live.

This generalizes the SRV mapping model to **every Unit-scoped asset**: compressors, dispensers,
storage vessels, recovery tanks and gas detectors. Each carries:

```
station_id      UUID NOT NULL REFERENCES station(id),
unit_id         UUID NULL,
mapping_status  asset_mapping_status NOT NULL,   -- resolved | needs_unit_mapping | conflict
FOREIGN KEY (unit_id, station_id) REFERENCES unit(id, station_id)   -- dormant while unit_id NULL
CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL)
```

The same composite-FK trick applies: while `unit_id` is NULL the pair constraint is dormant; once
set, the Unit must provably belong to the stated Station.

Consequences, stated plainly:

- Stations in Canal, Alex and Upper may import with **zero Units** and assets attached at Station
  level pending mapping. That is a valid state, not an incomplete one (principle #19).
- Those assets appear in their global management module flagged *Needs Mapping*, and are excluded
  from Unit tabs until resolved — identical handling to SRVs.
- An SRV whose Station has no Units cannot progress past `needs_unit_mapping` until the Unit
  structure itself is established. The Unit queue therefore gates the SRV queue in those regions,
  and should be worked first.
- Where decision D2 proves a Unit from a numbered name, the Unit **is** created. D7 forbids the
  invented default, not an evidenced Unit.

### Manufacturer aliases (decision D5)

A curated `manufacturer_alias` table maps confirmed variants to a canonical name;
`manufacturer_raw` is retained on every record.

| Raw values | Decision |
| --- | --- |
| `NPSAC` / `NPAC` | same — typo |
| `Worthington Cylinders` / `Worthing Cylinders` | same — typo |
| `Anderson` / `Tyco Anderson` | **different manufacturers — never merged** |

No further merges are inferred from string similarity. `Anderson`/`Tyco Anderson` is the standing
counter-example: visual similarity is not identity, so each pair needs its own decision.

### Field-level source precedence

No workbook is globally authoritative. Precedence is declared **per field**, only where the
evidence supports it:

| Field | Preferred source | Why |
| --- | --- | --- |
| Station→Unit structure, Unit Name | `Assets DataBase` | the only source that states the two levels explicitly (East/West/Delta only) |
| Unit Job Number | `Assets DataBase` | the only source carrying it at all |
| Gas detector presence, serial, calibration | `Gas detector.xlsx` | the dedicated source; `Station data base` carries model only |
| Vessel calibration dates and serials | `شهادات الفحص والمعايرة` | the certificate source of record |
| SRV attributes and calibration | `Warehouse Relief Data` | the dedicated SRV register |
| Hose records | `HOSES.xlsx` | the only hose asset source; `No. Of Hoses` elsewhere is a count, not records |
| Operational metrics (running hours, gas sales, bay status) | `Station data base.xlsx` | the only source |

Where two sources disagree on a field with no declared precedence, **both values are retained**,
the record is flagged `conflict`, and the disagreement stays visible in Data Quality until a
human resolves it. Later precedence rules are added only with evidence, and never retro-apply
over a human resolution.

### Date precision

Every date in the system is a triple: value, precision, raw.

```sql
CREATE TYPE date_precision AS ENUM ('exact_date', 'year_only', 'unknown', 'invalid');
```

| Precision | `value` | Source examples | Alerts |
| --- | --- | --- | --- |
| `exact_date` | set | `2026-08-08`, `15/12/2025` | **yes** |
| `year_only` | **NULL** | `2021` (int), `'2022'` (text) | **no** |
| `unknown` | NULL | empty cell | no |
| `invalid` | NULL | `منتهية`, `209/2021`, `16/8/3033`, `______` | no |

Where the invalid value is a **status word** rather than a broken date (`منتهي`, `منتهية` —
"expired"), it is additionally stored in `source_status_raw` and displayed beside the missing date
as *"source marked: منتهية"* (decision D6). It is **not** counted as Overdue: the source says the
item had lapsed at some unknown time, which is not the same as a due date that has passed.

Only `exact_date` participates in **Days Left, Due Today, the 7/15/30/60-day alerts, and Overdue
status**. Everything else renders its raw source value with an explicit label (*"Year only —
exact date unknown"*, *"Unreadable source value"*) and is counted separately from compliance
figures, so an unknown date can never masquerade as compliant or as overdue.

This is enforced in the derived views: `days_left` is computed only
`WHERE next_due_precision = 'exact_date'`, and is NULL otherwise. A year-only date is retained
and visible as source information — it is never expanded to 1 January.


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
/admin/data-quality                unresolved mappings + flagged rows
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
Migrations for `region`, `station`, `unit`, the five equipment types, `installed_srv`
(with its status-conditional parent constraint and composite foreign keys), `hose`,
`app_user`. Scope helper functions and RLS
policies on every table. Canonical region seed. Generated TypeScript types.

**Phase 3 — Hierarchy browsing**
Region → Station → Unit navigation, Unit equipment tabs, read-only. Derived `*_full` views
including dynamic `days_left`. Empty and NULL states rendered as genuinely empty.

**Phase 4 — SRV model and the two views**
`installed_srv` with its status-conditional `CHECK` and composite foreign keys; the
`srv_mapping_status` enum; `srv_full`. Unit SRVs tab (Unit-confirmed records only) and global
SRV Management (all statuses, *Needs Mapping* badge and filter), both over `srv_full` with one
shared table component. Filtering, sorting, due-status colouring, CSV export.

**Phase 5 — Remaining global modules**
Vessels, Gas Detector, Hoses management on the same pattern.

**Phase 6 — Write operations**
Create/edit/delete for stations, units, equipment, SRVs. Validation that honours the data
principles (nullable job number, nullable serial, TEXT identifiers). Audit trail.

**Phase 6b — Identity and mapping workflow**
`station_alias` (and `unit_alias` if needed), `asset_mapping_audit`, and the Admin → Data Quality
screens: filter/search, assign Unit, assign equipment, confirmation-gated bulk assign, alias
confirmation, and audit history. This ships **before** the import so that unresolved records have
somewhere to go the day they land.

**Phase 7 — Data import**
Importers under `scripts/import/` with a mandatory dry-run report: rows read, rows mapped,
rows flagged `needs_review` with reason, rows landing in each `mapping_status`, counts per
`date_precision`, proposed aliases (never auto-confirmed), and values normalized and by which
rule. `source_raw` populated. Identifier columns asserted non-numeric, or the run aborts. Nothing is imported until a dry-run is reviewed. Admin import UI last.

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
| A4 | **View-vs-source divergence** — someone "fixes" the global SRV module by adding a second table, quietly duplicating records | High | Structural: one `installed_srv` table; both surfaces render one component over `srv_full`; stated as a rule in CLAUDE.md |
| A5 | **Polymorphic SRV parent** makes generic joins awkward and invites a `parent_type` shortcut later | Medium | Status-conditional `CHECK` plus `srv_full`, which hides the branching from all callers |
| A5b | **Unresolved SRVs become permanent** — the mapping queue is never worked, and `station_id`/`unit_id` drift into being treated as the real parentage | High | `mapping_status` surfaced on every SRV row and counted on the dashboard; Admin → Data Quality as a standing work queue; composite FKs keep the denormalized columns consistent with the parent for every resolved row |
| A5c | **A Unit or equipment record is re-parented** (Unit moved to another Station), orphaning a resolved SRV's location columns | Medium | Composite foreign keys reject the move rather than allowing silent inconsistency |
| A6 | **Schema-as-public-API** — client talks straight to PostgREST, so renames are breaking | Medium | All access through `src/lib/data/*`; regenerate types on every migration; additive migrations only |
| A7 | **Derived Days Left recomputed on every read**; also timezone-dependent | Medium | Compute in one view with an explicit date basis; decide and document the reference timezone once |
| A8 | **Edge Function notification duplication or silent failure** — cron retries or an unhandled Resend error can double-send or drop alerts | Medium | `notification_log` with a uniqueness key per (item, threshold, day); failures logged and surfaced in an admin view, not swallowed |
| A9 | **Web Push subscription rot** — expired subscriptions accumulate and every send fails | Low | Prune on 404/410 responses |
| A10 | **Cloudflare Pages SPA routing** — deep links 404 without a catch-all rewrite | Low | `_redirects` configured in Phase 1 and verified with a deep link |
| A11 | **Isolation breach** — a copied env var or a Supabase MCP call aimed at the wrong project silently couples this system to the Coding System | Critical | CLAUDE.md rule; verify project/org name before every hosted-resource operation; secrets generated fresh, never copied |
| A13 | **A future "helpful" backfill auto-maps SRVs** from Location or name similarity, fabricating parentage at scale | High | Prohibited-inference list in CLAUDE.md and here; the `CHECK` blocks the write; mapping requires `resolved_by`/`resolved_at`, which a script cannot honestly supply |
| A14 | **Alias table drifts into runtime fuzzy matching** because it is faster than confirming aliases | High | Resolution reads `station_alias` only; fuzzy matching lives in the review UI as a proposal step and has no runtime code path |
| A15 | **A year-only or invalid date leaks into compliance figures**, showing an asset as compliant or overdue on no evidence | High | `date_precision` gates every alert path; `days_left` is NULL unless `exact_date`; unknown-precision items are counted in their own bucket, never folded into compliant/overdue |
| A16 | **An analytical figure is hardcoded** (e.g. the 41 % overdue-vessel finding) and becomes phantom production truth | Medium | No source-analysis count appears in application code, seeds, or fixtures; every operational figure is computed from imported data at read time |
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
| D9 | **An SRV row that names a Station or Unit but not its parent equipment** — tempting to attach it to the Unit (breaking the hierarchy rule) or to reject it (losing the record) | High | Neither: it imports with `mapping_status = 'needs_unit_mapping'` or `'needs_equipment_mapping'`, keeps whatever location the source proves, and is excluded from Unit SRV tabs until the Unit is confirmed. The status-conditional `CHECK` makes a silently half-mapped row impossible |
| D9b | **Sources disagree on an SRV's parent** (two sheets place the same tag on different equipment) | High | `mapping_status = 'conflict'` with `mapping_note`; both readings preserved in `source_raw`; never auto-resolved by precedence or recency |
| D10 | **Blank vs "N/A" vs "-" vs `0`** — placeholder text imported as real data | Medium | Explicit placeholder list normalized to `NULL`; `0` for a pressure or a date is **never** treated as a placeholder without evidence (principles #1, #14) |
| D11 | **Merged cells / multi-row headers / trailing total rows** in source spreadsheets shift every column | High | Header detection asserted explicitly per file; dry-run prints the detected header row and a sample mapping for human confirmation before any write |
| D12 | **Unit-of-measure inconsistency** (bar vs psi, mm vs inch) in pressure and size columns | Medium | Store the value and its source unit; convert only in the display layer, and only when the source unit is stated — never infer |
| D13 | **Loss of traceability after import** — no way to answer "where did this value come from?" | Medium | `source_raw JSONB` per row plus an import batch id recording file name, sheet, row number, and import timestamp (principle #6) |
| D13b | **Numeric-typed identifiers** — 958 SRV, 452 vessel and 1 170 warehouse serials stored as Excel integers; 3 gas-detector serials and 41 part numbers as floats | High | Read raw, cast to TEXT with no numeric formatting; never pad a lost leading zero speculatively; dry-run asserts no identifier became a float or scientific-notation string |
| D13c | **A part number in the serial column** (`SS-4R3A` on 48 rows) read as a duplicate serial | Medium | Preserve raw, flag for review; never auto-correct and never merge on it |
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
7. Who owns the mapping queue, and is there a target for clearing `needs_unit_mapping` /
   `needs_equipment_mapping` backlogs? With ~2 662 SRVs expected to arrive unresolved, throughput
   here determines when SRV compliance reporting becomes trustworthy.
8. The nine source questions in `data-quality-report.md` §13, of which items 1–3 (governorate
   suffixes, numbered station names, SRV parent resolution) gate the largest record volumes.
