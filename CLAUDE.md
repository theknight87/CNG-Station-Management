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
  or Station.
- Every SRV has exactly one parent equipment record; its Unit/Station/Region are **derived**
  from that parent, never stored redundantly as the source of truth.
- The **Unit → SRVs tab** and the **global SRV Management module** are *views* over the same
  source records.
- **Never duplicate SRV records** to make a view easier to build. One SRV = one row.

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
