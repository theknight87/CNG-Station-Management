# CNG Station Management System

Web application for managing CNG filling-station equipment, its maintenance calendar, and
its safety-critical components — notably Safety Relief Valves (SRVs).

> **Isolation:** this is a standalone project. It shares no repository, database,
> organization, hosting project, identity application, key, or secret with any other
> system. See [`CLAUDE.md`](./CLAUDE.md) §2 before touching any hosted resource.

## Stack

| Concern | Choice |
| --- | --- |
| Frontend | React 19 + TypeScript + Vite |
| Routing | React Router |
| UI | Tailwind CSS + shadcn/ui |
| Linting | ESLint (typescript-eslint, react-hooks, react-refresh) |
| Authentication | Clerk — app `CNG Station Management` *(wired in a later phase)* |
| Database | Supabase PostgreSQL — project `cng-station-management` *(no tables yet)* |
| Authorization | Supabase Row Level Security |
| Hosting | Cloudflare Pages — project `cng-station-management` |
| Email | Resend |
| Web Push | standard Web Push with this project's own VAPID keys |
| Scheduling | Supabase Cron + Edge Functions |

## Getting started

```bash
npm install
cp .env.example .env.local   # fill in THIS project's values only
npm run dev
```

Checks:

```bash
npm run typecheck   # TypeScript, strict, no emit
npm run lint        # ESLint
npm run build       # production build
```

## Structure

```
src/
├── components/     shared components (ui/ = shadcn primitives, layout/ = app shell)
├── features/       one folder per domain area; feature UI lives here
├── pages/          thin route entry points that render a feature view
├── hooks/          shared React hooks
├── lib/            clerk/ and supabase/ configuration and clients
├── services/       data access, one module per domain
├── types/          domain vocabulary; generated DB types land here later
└── utils/          pure helpers (date arithmetic, deterministic normalization)

supabase/           migrations/, functions/, seed.sql
scripts/import/     source-file importers (Phase 7)
docs/               architecture and data-mapping decisions
```

## Documentation

- [`CLAUDE.md`](./CLAUDE.md) — isolation rule, equipment hierarchy, data principles
- [`docs/architecture.md`](./docs/architecture.md) — system design, SRV mapping model,
  implementation phases, architecture and data-mapping risks

## Key domain rules

The physical hierarchy is **Region → Station → Unit → Equipment → SRV**. SRVs are children
of a Compressor, Storage Vessel, or Dispenser — never independent station assets.

Global modules (SRV, Vessels, Gas Detectors, Hoses) are **aggregate views over the same
records**; they never duplicate them.

Imported SRVs whose Unit or parent equipment cannot be determined from the source are
**preserved and flagged**, never guessed and never discarded. See the mapping-status model
in `docs/architecture.md`.

Days Left is always **derived** from the next due date, never read from a source file.

## Current status

Project scaffold. No database tables, no authentication wiring, and no data access yet —
screens render deliberately empty placeholders rather than sample data.
