# CLAUDE.md — CNG Station Management System

Guidance for Claude Code (and any contributor) working in this repository.

## 1. What this project is

**CNG Station Management System** — a web application for managing CNG (Compressed
Natural Gas) filling-station equipment, its maintenance calendar, and its safety-critical
components (notably Safety Relief Valves).

This is a **brand-new, standalone application**. It is **not** the Coding System project
and shares nothing with it.

## 2. CRITICAL ISOLATION RULE — read before touching anything

This project is **completely isolated** from the existing *Coding System* project.

**Do NOT access, modify, reuse, migrate, link, delete, or deploy anything belonging to the
Coding System.**

Never reuse, from any other project:

- GitHub repository
- Supabase Organization
- Supabase project
- Cloudflare Pages project
- Clerk Application
- VAPID keys (Web Push)
- Resend configuration, domains, or API keys
- Database tables
- Migrations
- Environment variables
- API keys
- Secrets of any kind

Consequences of this rule, in practice:

1. A **new Supabase Organization** is created specifically for this project; the Supabase
   project `cng-station-management` lives inside it and nowhere else.
2. A **new Clerk Application** named `CNG Station Management` is created; no existing
   instance, JWT template, or key is reused.
3. **New VAPID keys** are generated for this project alone.
4. Resend uses its **own API key** and its own verified sending identity for this project.
5. All environment variables are defined fresh in this repository's `.env.example`; values
   are never copied from another project's dashboard.
6. Before any operation that touches a hosted resource (Supabase, Cloudflare, Clerk,
   Resend), **verify the target resource name/ID belongs to this project**. If the target
   is ambiguous, stop and ask.
7. This project must remain **independently deployable** and **independently recoverable** —
   it must be possible to rebuild it from this repository plus its own secrets, with no
   dependency on any other project's state.

## 3. Target infrastructure

| Concern | Choice | Name |
| --- | --- | --- |
| Source control | GitHub | `cng-station-management` |
| Frontend | React + TypeScript + Vite | — |
| Routing | React Router | — |
| UI | Tailwind CSS + shadcn/ui | — |
| Authentication | Clerk | App: `CNG Station Management` |
| Database | Supabase PostgreSQL | Project: `cng-station-management` (new org) |
| Authorization | Supabase Row Level Security | — |
| Hosting | Cloudflare Pages | Project: `cng-station-management` |
| Email | Resend | dedicated API key |
| Web Push | standard Web Push | dedicated VAPID key pair |
| Scheduling | Supabase Cron + Edge Functions | — |

## 4. Authoritative equipment hierarchy

The **physical hierarchy** is, and remains:

```
Region
└── Station
    └── Unit
        ├── Compressor
        ├── Recovery Tank
        ├── Gas Detector(s)
        ├── Dispenser(s)
        └── Storage Vessel(s)
```

**Safety Relief Valves (SRVs) are children of their parent equipment**, never independent
station assets. An SRV may belong to a **Compressor**, a **Storage Vessel**, or a
**Dispenser**.

Rules:

- An SRV **must not** appear in the physical hierarchy as a standalone asset under a Unit
  or Station. The UI hierarchy is and remains
  `Region → Station → Unit → Equipment → SRV`.
- A **resolved** SRV has exactly one parent equipment record, and that parent must belong to
  the Unit and Station recorded on the SRV.
- The **Unit → SRVs tab** and the **global SRV Management module** are *views* over the same
  source records.
- **Never duplicate SRV records** to make a view easier to build. One SRV = one row.

### Unresolved imported SRVs (mapping status)

Historical source data sometimes proves an SRV's **Station** but not its Unit, and sometimes
proves the Unit but not which Compressor, Vessel, or Dispenser it sits on. Such records are
**preserved, not rejected and not guessed** (data principles #1, #8, #9, #10).

Source analysis confirmed this is the normal case, not the exception: the installed-SRV source
has **no Unit column and no equipment identifier**, so **no installed SRV can be imported as
`resolved`**. See `docs/data-quality-report.md` §4.

The installed-SRV record therefore carries:

| Column | Nullability |
| --- | --- |
| `station_id` | **nullable** — NULL while the canonical Station is unconfirmed |
| `unit_id` | nullable |
| `compressor_id` | nullable |
| `storage_vessel_id` | nullable |
| `dispenser_id` | nullable |
| `expected_parent_kind` | nullable — **resolution hint only** |
| `mapping_status` | required |

`mapping_status` values — the lifecycle runs
`needs_station_mapping → needs_unit_mapping → needs_equipment_mapping → resolved`,
with `conflict` as an evidence-preserving side state:

| Status | Meaning | Shape |
| --- | --- | --- |
| `needs_station_mapping` | canonical Station not yet confirmed | Station NULL; Unit NULL; no equipment parent; raw source Station name **required** |
| `needs_unit_mapping` | Station proven, Unit not | Station set; Unit NULL; no equipment parent |
| `needs_equipment_mapping` | Station and Unit proven, parent equipment not | Station + Unit set; no equipment parent |
| `resolved` | fully mapped | Station + Unit set; exactly one equipment parent |
| `conflict` | source evidence disagrees | held for human resolution |

**An SRV whose Station is unconfirmed is still an installed SRV.** It lives in
`installed_relief_valves`, keeps its raw source Station name, Region, `Location` and full
file/sheet/row provenance, appears in Global SRV Management labelled *Needs Station Mapping*,
and is never shown in a Unit SRV tab. `import_issues` records the *unmatched_station issue*;
it is never the only place the asset exists.

#### `expected_parent_kind` is a hint, never a foreign key

The source `Location` column is preserved verbatim. Where its interpretation is deterministic it
also populates `expected_parent_kind`:

| Source `Location` | `expected_parent_kind` | Meaning |
| --- | --- | --- |
| `Stage` | `compressor` | the parent is *a* compressor — **which one is unknown** |
| `Storage` | `storage_vessel` | the parent is *a* storage vessel — **which one is unknown** |

This value narrows the choices presented to an engineer in the mapping workflow. It **must never
populate an equipment foreign key**, and it is not evidence of Unit membership.

#### Prohibited automatic inferences

These are forbidden at import and at every later stage. Each would fabricate a physical
relationship the source does not prove:

- **Never** map an SRV to a Unit from Station-name similarity alone.
- **Never** assign a `Stage` SRV to a specific Compressor automatically.
- **Never** assign a `Storage` SRV to a specific Storage Vessel automatically.
- **Never** distribute SRVs across a Unit's Units, compressors or vessels by count, order,
  round-robin, or any balancing rule.
- **Never** infer a Dispenser SRV. **No dispenser SRV is proven by any current source.**
- **Never** auto-apply a bulk mapping rule from name similarity or `Location`.

Equipment parentage is set by an explicit human decision, recorded with who and when
(decision D3 — manual/bulk mapping in the application, or a later source that names the parent
for that specific SRV; **default distribution is permanently forbidden**).

Unresolved records:

- **remain stored, searchable, and visible in Global SRV Management**, labelled *Needs Mapping*
- appear in **Admin → Data Quality**
- are **never automatically assigned** to a Unit or to equipment
- **do not appear in any Unit's SRV tab** — that tab queries only `unit_id`-confirmed records

This accommodation exists solely to preserve incomplete historical source data until mapping
is resolved. It does **not** make an SRV an independent station asset: an unresolved record is
explicitly marked as unmapped, is excluded from the physical hierarchy views, and is expected
to become `resolved`.

The same principle applies to the other aggregate modules (Vessels, Gas Detectors, Hoses):
they are read and management views over hierarchy-owned records and must not alter the hierarchy.

## 5. Global management modules

Top-level aggregate modules, in addition to the hierarchy browser:

- **SRV Management** — all SRVs across all Regions and Stations
- **Vessels Management**
- **Gas Detector Management**
- **Hoses Management**

These are aggregate views with filtering, bulk review, and due-date management. They do not
introduce new ownership and do not change parentage.

## 6. Data principles (mandatory)

1. **Never fabricate missing technical data.**
2. Import **every verified value** available in the source files.
3. Missing values remain `NULL`.
4. A missing **Job Number must never block** creation of a Station or Unit.
5. A missing **serial number must not** automatically invalidate the whole asset record.
6. **Preserve original source values** for traceability (raw columns kept alongside
   normalized ones).
7. **Normalize only when normalization is deterministic.**
8. **Never silently guess** Station or Unit mappings.
9. **Ambiguous records are retained** and flagged for review — never dropped.
10. **Never discard valid source rows** because some fields are unavailable.
11. Technical **serial numbers and identifiers are stored as `TEXT`** (never numeric —
    leading zeros, dashes, and mixed alphanumerics must survive).
12. **Do not rely on Excel `Days Left` fields.**
13. **Calculate Days Left dynamically** from the next valid due date.
14. **Empty source data stays empty** in the system.
15. **Identifiers are preserved exactly as the source holds them.** Never pad a missing leading
    zero, never strip decimal-looking characters from a damaged Excel value, never "correct" a
    value that looks wrong (e.g. a part number such as `SS-4R3A` sitting in a serial column) —
    preserve it raw and flag it for review.
16. **Repeated values are not duplicates without supporting evidence.** Six identical relief
    valves on one station may be six real devices. Report duplicate candidates; never merge or
    discard silently.
17. **Date precision is explicit.** Every date carries `exact_date`, `year_only`, `unknown`, or
    `invalid`. Only `exact_date` may drive Days Left, Due Today, 7/15/30/60-day alerts, or
    Overdue status.
18. **No workbook is globally authoritative.** Source precedence is decided per field, only
    where evidence supports it, and conflicts stay visible until a human resolves them.
19. **Missing data never makes an entity invalid.** A Region, Station, Unit or asset with NULL
    fields is a complete record with unknown attributes — it is created, displayed and tracked
    normally. Nothing is marked "incomplete" and nothing is blocked because a field is unknown.
20. **A missing identifier may be a fact, not a gap.** Where an asset type has no serial assigned
    yet (decision D4), `serial_status = 'not_yet_assigned'` records that explicitly — distinct
    from `unknown`, where the source says nothing either way. Serials are never generated
    automatically.
21. **Source status text is kept, not converted.** Values such as `منتهي`/`منتهية` ("expired") in
    a date column are preserved in `source_status_raw` and shown beside the missing date
    (decision D6). They never become a date, and never a computed compliance status.

### Canonical Regions

`East`, `West`, `Canal`, `Delta`, `Alex`, `Upper`

Deterministic normalizations (case/whitespace folding and known aliases only):

| Source | Canonical |
| --- | --- |
| `EAST`, `east` | East |
| `WEST`, `west`, `غرب` | West |
| `DELTA`, `delta` | Delta |
| `CANAL`, `canal` | Canal |
| `ALEX`, `alex` | Alex |
| `UPPER`, `upper` | Upper |

Anything not matching a known alias is **not guessed** — the raw value is preserved and the
row is marked for review.

## 7. Working agreements

- Documentation-first: architecture and data-mapping decisions are recorded in `docs/`
  before implementation.
- Migrations are additive and versioned; no destructive migration without explicit approval.
- RLS is enabled on every table from the first migration — no table ships without a policy.
- No secrets in the repository. `.env.example` documents keys with empty values.
- Dynamic computations (Days Left, compliance status) live in SQL views or the query layer,
  never as stale stored columns.

## 8. Canonical Station and Unit identity

**No single workbook is the Station master.** `Station data base.xlsx` mixes station-level and
unit-level naming in one column (`شبرا 1`…`شبرا 4` alongside single-name stations), so treating
each of its rows as a unique Station would create duplicate and mis-levelled Stations. See
`docs/data-quality-report.md` §3.

The canonical Station/Unit model is **reconciled across all sources**:

- Structure (which Units belong to which Station) comes from the source that states it
  explicitly, currently `Assets DataBase` for East, West and Delta.
- Every other file contributes attributes to entities identified by alias resolution.
- Where no source states the structure (Canal, Alex, Upper), a Station is created with the Units
  the evidence supports and flagged for review — never with invented Units.

**No default Unit, ever (decision D7).** If a Station's Unit is unknown, `unit_id` is `NULL`. A
Unit named after its Station is never created just to have somewhere to attach assets. Because
compressors, dispensers, vessels, recovery tanks and gas detectors are Unit-scoped, they carry
the same `station_id NOT NULL` / `unit_id NULL` / `mapping_status` shape already defined for
SRVs, and are resolved through the same Data Quality workflow. A Station with no Units is a
valid record, not an incomplete one (principle #19).

### Owner-confirmed data rules

Only equivalences the system owner has **explicitly confirmed** may bypass manual review, and
only for the exact values listed. These live as rows in `owner_confirmed_station_aliases` and
`owner_confirmed_part_numbers`, so the full set of owner rulings is always listable by `SELECT`,
auditable, and reversible. **There is no pattern, regex, suffix or similarity rule anywhere.**

| Confirmed ruling | Effect | Explicitly NOT authorized |
| --- | --- | --- |
| `ابنوب` = `ابنوب اسيوط` (same physical Station) | this exact pair resolves without review; the original source name is kept in provenance and `source_raw` | **generic governorate-suffix stripping.** `ابو القمصان`, `ابو تيج- اسيوط`, `الادبيه - السويس` and every other suffixed name still require human confirmation |
| `SS-4R3A` is a Part Number, not a Serial | in the affected SRV serial column it normalizes into `part_number`, `serial_number` becomes NULL where no genuine serial exists, and the raw cell plus file/sheet/row provenance is preserved | moving **any other** serial-looking or part-number-looking value. Shape is not evidence |

`<base> <n>` is Unit *n* of Station `<base>` (decision D2, e.g. `الخمائل` has Units `الخمائل 1`
and `الخمائل 2`) remains the owner's ruling on unit naming; it may **propose** an alias, and a
human confirms it.

Anything not on an owner-confirmed list produces a **proposal** and an import issue — never a
resolution.

### Alias tables, not runtime fuzzy matching

`station_aliases` — and `unit_aliases` where analysis shows it is needed — map a raw source name
(plus its source file and region) to a canonical entity. Rules:

- An alias is an **explicit, stored mapping**, created by import confirmation or by a human.
- Normalization (NFKC, whitespace, Arabic letter folding) may *propose* an alias; it never
  creates one silently.
- **Runtime lookups resolve through the alias table only.** Fuzzy matching is a one-time
  suggestion aid in the review UI, never a permanent resolution mechanism.
- An unmatched name is preserved with an **import issue** and resolved by a human. It is never
  silently merged into an existing Station, and never silently duplicated into a new one where
  that can be avoided.

## 9. Mapping workflow (Admin → Data Quality)

Resolving unresolved imported assets is a **product feature**, not a migration script.

For SRVs the workflow provides: filter by Region, Station, source `Location`, and
`expected_parent_kind`; search by serial, manufacturer, or set pressure; assign a confirmed Unit;
assign confirmed parent equipment; mark resolved.

**Bulk mapping** is supported where an engineer explicitly confirms that the selected records
share the same Unit/equipment context. It always requires explicit human confirmation of the
specific selection, and is never applied automatically from name similarity or `Location`.

### Who may map (decision D8)

| Role | Mapping rights |
| --- | --- |
| `admin` | anywhere |
| `regional_manager` | anywhere |
| `station_engineer` | **only within their authorized Regions** |
| `viewer` | none |

Region scope is enforced in **RLS**, not only in the UI. A bulk action never silently skips
records outside the actor's scope — it reports them.

Every mapping change — single or bulk — records who made it and when, and is retained as **audit
history**. `source_raw` is never altered by a mapping decision.

## 10. Security rules (durable)

*Status: implemented and verified end to end in a real browser on 2026-09-14 (Prompt 5). The
temporary routes `/sign-in`, `/sign-up` and `/auth-test` are retained for acceptance testing and
must be removed before production — see `docs/authentication.md` §11.*

These hold for every future phase.

- **The database is the authorization authority.** Clerk establishes identity; roles, region
  access and every row decision live in PostgreSQL and are enforced by RLS. A frontend check is
  UX, never security. Hiding a button is not protection.
- **Closed by default.** `anon` receives no privileges. `authenticated` receives only the specific
  privileges a feature needs, table by table, with column-level grants where a role should write
  only part of a row. Never issue blanket grants such as `GRANT ALL ... TO authenticated`.
- **Every UPDATE policy carries both `USING` and `WITH CHECK`.** Without the second half an
  allowed row can be edited into a forbidden region.
- **Raw source text is never an authorization boundary.** `source_station_name_raw`,
  unconfirmed `region_id` on an unmapped record, and fuzzy matches are evidence, not permission.
  An SRV awaiting station confirmation is admin/manager only.
- **Authorization is never synchronized from Clerk.** No webhook, profile edit or Clerk metadata
  value may set `role`, `is_active` or region access. Identity sync and authorization management
  are separate concerns.
- **Signing up grants nothing.** New accounts are created inactive with the least-privileged role;
  an administrator must activate them. Never "first user becomes admin", never infer privilege
  from an email domain.
- **No hard deletes.** Operational, import, mapping and audit records are archived, never removed.
  Audit tables are append-only and their actor column cannot be forged.
- **`SECURITY DEFINER` only where genuinely required**, with a pinned `search_path`, no
  user-supplied identity parameter, and EXECUTE granted to `authenticated` only.
- **Use the current Clerk-Supabase third-party auth integration.** The deprecated JWT-template
  approach must not be reintroduced, and this project's JWT secret is never shared with Clerk.
