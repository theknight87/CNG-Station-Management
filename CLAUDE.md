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

*Import status: the pipeline is built and dry-run verified (Prompt 6) — see
`docs/import-pipeline.md`. The production import of the six workbooks has NOT been performed; it is
Prompt 21. Canonical asset tables are still empty.*

*Hierarchy browsing (Prompt 9) is built: `/regions`, `/regions/:regionId`, `/stations`,
`/stations/:stationId` — see `docs/regions-stations.md`. Migration 0028 fixed a latent defect in
`cng_normalize_name()` that would have corrupted canonical Station and Unit identity at the
Prompt 21 import.*

*Global SRV Management (Prompt 11) is built: `/manage/srvs/installed` and
`/manage/srvs/warehouse` — see `docs/srv-management.md`. It required **no new migration**.
Installed and warehouse valves are never merged. Mapping MUTATION is deliberately deferred:
the database enforces hierarchy consistency, but mapping attribution is still forgeable and
unaudited, so no mapping control is exposed.*

*Gas Detector Management (Prompt 13) is built: `/manage/gas-detectors` — see
`docs/gas-detector-management.md`. **No new migration**; it reads `v_gas_detector_management`
from migration 0011. Two schema truths govern it: `area_type` lives on `gas_detector_presence`,
not on `gas_detectors`, so it classifies the AREA and is never a detector location or a status;
and the view UNIONs installed assets with explicit not-installed EVIDENCE, so the registry
defaults to installed detectors and never counts recorded absence as a device. **A SECOND
PROMPT-21 BLOCKER was confirmed**: `gas_detectors.station_id` is NOT NULL, so the 219 rows
Prompt 6 staged as `needs_station_mapping` cannot enter the canonical table — the same shape as
the vessel blocker (433 Storage, 403 Recovery). Proved by a rejected insert; nothing was relaxed
or dropped. No authoritative calibration interval exists anywhere (`alert_rules` has thresholds
only), so none is hard-coded and the gap is documented. Mapping mutation stays deferred for the
same attribution reason as Prompts 11 and 12.*

*Hoses Management (Prompt 14) is built: `/manage/hoses` — see `docs/hoses-management.md`.
**One additive migration**, 0030, creating `v_hose_registry` (`security_invoker`);
`v_hose_management` is untouched and still serves the Prompt-10 Unit tab. It is the only
registry organised around IDENTITY first, because a hose is individually traceable. Three
facts were verified empirically: `station_id` is NOT NULL, so `needs_station_mapping` is
unreachable and the 49 staged hose rows are a **THIRD Prompt-21 blocker (total now 1,104)**;
`unit_id` is nullable but `resolved` requires it, so Unit mapping is PENDING, never
permanently optional; and `dispenser_id` exists, making the chain
`Region → Station → Unit → Dispenser → Hose`. **No UNIQUE constraint was added on
`serial_number`** — duplicates are REPORTED, never enforced away, and `serial_duplicate` is
computed under the caller's RLS so a cross-region serial collision is shown to an admin but
never to a regional viewer, who would otherwise learn of a row they may not read. NULL
serials are never duplicates of one another. Terminology follows the schema: "Last test" /
"Next test", never relabelled "Calibration". No authoritative test interval exists anywhere,
so none is hard-coded. Mapping mutation stays deferred for the same attribution reason as
Prompts 11-13.*

*Alerts & Notifications (Prompt 15) is built: `/alerts` — see `docs/alerts-notifications.md`.
Migrations **0031** (engine), **0032** (daily pg_cron schedule) and **0033** (a security fix),
plus the `generate-alerts` Edge Function. The system keeps **due status**, **alert** and
**delivery** as three separate layers: a failed delivery never alters an alert, and an asset
becoming current never deletes one. Most of the schema existed from Prompt 4 and was reused —
`alerts_dedupe_uq` makes idempotency a DATABASE property, verified with six concurrent runs
producing exactly one alert. Added: **per-user read state** (`alert_reads`; read is NOT
acknowledgement, and opening an alert does neither), a safe acknowledgement path, and generation
itself. Only `exact_date` precision is eligible, so a year-only date can never raise a countdown;
countdown thresholds match the exact calendar day, so a first run against an already-overdue asset
raises `overdue` alone and back-fills nothing. **A PRE-EXISTING VULNERABILITY WAS FOUND AND
FIXED**: migration 0019 granted `UPDATE (state, acknowledged_by, acknowledged_at, resolved_at)` at
COLUMN level — invisible in `role_table_grants` — and an engineer could attribute an
acknowledgement to an admin with a backdated timestamp. Reproduced by attack; migration 0033
revokes it, leaving the SECURITY DEFINER `cng_acknowledge_alert()` as the only path. Generation is
granted to `service_role` only. `pg_cron` calls the SQL function IN-DATABASE, so no invocation
secret exists in the repository. **Email and Web Push are architected but NOT sent**: this project
has no Resend API key, no verified CNG sender and no VAPID pair, and none was invented — the
Resend ACCOUNT may be shared with the Coding System, its CREDENTIALS may not, and no cross-project
dependency exists.*

*Final live verification (Prompt 15.2) is done — see `docs/alerts-notifications.md` §21. The
hosted database was found **five migrations behind the repository (29 vs 34)**: the alert engine did
not exist in production and **the 0033 acknowledgement fix was unapplied there**, so the §14
vulnerability was still live in the hosted project while the repository considered it closed.
Migrations 0030-0034 were applied and the production posture re-proved: 0 `authenticated` UPDATE
columns on `alerts`, generation and the delivery functions granted to `service_role` only, and the
`cng-generate-alerts` cron job live at `0 1 * * *` calling the SQL function in-database. Both Edge
Functions are deployed ACTIVE with `verify_jwt = false`, which is correct because each
authenticates its caller with the invoke secret. **Secret PRESENCE was proved without reading any
secret**: curl is still 403-blocked at CONNECT, so an unauthenticated POST was sent from inside the
hosted database (pg_net enabled temporarily and dropped again); both functions answered **401**,
which proves core configuration is present — the not_configured branch returns 503 and runs first —
and that neither is an open endpoint. **THE TEST EMAIL WAS NOT SENT AND NOT FAKED**: sending
requires presenting `CNG_ALERT_INVOKE_SECRET`, which this session may not read, and no
authentication was weakened to reach a send. **Web Push is a BUILD-TIME gap**: `VITE_*` values are
inlined by Vite at build time, so the Cloudflare Pages variable requires a REDEPLOY to take effect.
`efares0@gmail.com` stays test-only — it appears in no migration, view, default, seed or frontend
file.*

*CORRECTION (Prompt 15.2A) — **there is no CNG Cloudflare Pages project, and this application has
never been deployed anywhere.** Prompt 15.2's statement that `VITE_VAPID_PUBLIC_KEY` was "set in
Cloudflare Pages" and that only a redeploy remained was FALSE: I could not see Cloudflare (403 at
CONNECT, no tooling) and inferred the project existed. The account holds exactly one Pages project,
`cargas-coding-system` → `coding-system-new.pages.dev`, which is the separate Coding System and
must never be modified, inspected, copied from or attached to. `docs/architecture.md` Phase 1 is
corrected too: the scaffold, Supabase project and Clerk application were created; the Pages project
never was. Settings for the new isolated project were determined by READING the repository and
running a clean build (exit 0), not guessed — npm, `npm run build` (`tsc -b && vite build`, the
typecheck stays), output `dist`, `NODE_VERSION=22` because Vite 8 needs Node >=20.19/22.12, and SPA
routing already handled by `public/_redirects` which Vite copies into `dist` (so NO Cloudflare-side
rewrite rule is to be added). Only the four `VITE_*` publishable values plus `NODE_VERSION` go to
Cloudflare; VAPID private, Resend, invoke secret, test recipient, Clerk secret and the service-role
key never do — a static build inlines whatever it is given, so "encrypted" there is not private.
Full instructions: `docs/deployment-cloudflare.md`. Cloudflare is NOT LIVE VERIFIED and must not be
marked so until the independent project exists and has deployed.*

*Web Push service-worker lifecycle fix (Prompt 15.2B) — the application IS now deployed at
`cng-station-management.pages.dev` (its own isolated Pages project; `cargas-coding-system` remains
untouched), which superseded the 15.2A status and exposed a REAL RUNTIME DEFECT reported from
production: clicking **Enable notifications** failed with *"Subscription failed - no active Service
Worker"*. **Root cause**: `navigator.serviceWorker.register()` resolves as soon as the REGISTRATION
exists, while its worker may still be `installing`; `pushManager.subscribe()` requires an ACTIVE
worker. The old code subscribed on the next line, so a first click on a fresh browser raced
activation and lost, while a later click — with a worker already activated — appeared to work. That
intermittency is why it looked like a configuration problem; **the VAPID keys and the Cloudflare
variables were never wrong and were not changed.** The fix waits for activation via
`registerActiveServiceWorker()` (`registration.active` first, else `navigator.serviceWorker.ready`,
BOUNDED at 15s so a browser that never activates reports a stated failure instead of spinning). The
worker now also `skipWaiting()`s and `clients.claim()`s — safe ONLY because it caches nothing and
intercepts no fetch. `enable()` is now idempotent: an in-flight guard makes a second click start
nothing, and an EXISTING subscription is REUSED rather than re-subscribed, which would mint a new
endpoint and strand the saved row. **Security is unchanged**: permission is still requested only
from an explicit click, `cng_save_push_subscription` still takes no user parameter, and no RLS or
grant was touched. The regression test was **proved to fail against the old code** before being
accepted.*

*Server-side Web Push delivery (Prompt 15.3) is built — see `docs/alerts-notifications.md` §24.
**One migration, 0035**, adding four `service_role`-ONLY SECURITY DEFINER functions with pinned
`search_path`. It EXTENDS the existing delivery system rather than duplicating it: `web_push` has
been in `notification_channel` since 0001, `push_subscriptions` since 0009, and
`cng_enqueue_alert_deliveries`/`cng_record_delivery_result` are reused UNCHANGED; the request's
`channel` defaults to `email`, so every prior caller is unaffected. RFC 8291/8292 are implemented
on Web Crypto alone in `supabase/functions/_shared/webpush.ts` — no dependency, no Node or Deno
API — chosen so the crypto is UNIT-TESTABLE here, which a remote import would not be. **The VAPID
pair was not regenerated and no Cloudflare variable was changed.** The private key is signed with
server-side only and appears in no request, log, row or bundle (asserted). **404/410 is the ONLY
path to deactivating a subscription**, and that is soft, never a DELETE; a transient failure
increments `failure_count` and nothing else, so a push service having a bad minute can never
silently unsubscribe anyone. `service_role` holds NO SELECT on `push_subscriptions` — it acts only
through the four functions. A user with several browsers still has ONE delivery row; reached on at
least one device counts as delivered. The controlled test creates no alert and no delivery record,
accepts no endpoint/user/message from the caller, and answers 409 rather than inventing a
destination. **A NEW Edge Function secret is required: `VAPID_PUBLIC_KEY`** (the public half,
already in Cloudflare; the Edge runtime cannot read a Cloudflare build variable). **NOT LIVE
VERIFIED: no push message has ever reached a real push service**, and the function was deliberately
NOT deployed — this is for review first.*

***PROMPT 15 IS CLOSED (Prompt 15.3C)** — see `docs/alerts-notifications.md` §25. The whole
notification stack is now LIVE-VERIFIED: email delivery END-TO-END, Web Push browser subscription,
and Web Push SERVER DELIVERY END-TO-END — Edge Function → FCM → Chrome/Windows → visible
notification → click → `/alerts`. That discharges the 15.3 caveat that no push had ever reached a
real push service: FCM accepting the bytes validates the RFC 8291 body, the RFC 8292 header, the
`aud` scoping and the ES256 signature **by the provider**, and proves the VAPID pair genuine and
matching without either half being read. The live test also exposed a REAL DEFECT — in
DIAGNOSABILITY, not delivery: the push failure path logged no `result.lastError`, and because a
test send writes no delivery row by design, the sanitized reason existed only in the HTTP response
body and was lost when that body was not captured. Fixed by logging the already-sanitized code on
the test and web_push queue paths. Safe because `lastError` is always
`provider:code:hint` — never an endpoint, `p256dh`, `auth`, VAPID key, authorization header or
provider body. Two regression tests assert that invariant AT ITS SOURCE rather than by spying on
`console`. **Nothing else changed**: delivery behaviour, 404/410 deactivation, retry, dedupe,
acknowledgement semantics, VAPID keys, subscription architecture and the schema are untouched.
Production: 35 migrations, `send-notifications` v3 and `generate-alerts` v1 ACTIVE, cron live.*

***PROMPTS 16, 17 AND 18 ARE CLOSED by reconciliation** — see `docs/alerts-notifications.md`
§26. The Prompt Pack separates Email (16), Web Push (17) and In-App (18); the implementation
delivered most of all three inside Prompt 15-15.3C, because alerts, delivery and channels are one
system. This was a GAP CHECK, NOT A REBUILD: nothing working was refactored. Nine requirements
already passed; **six were PARTIAL or MISSING and were implemented** — message context (Region,
Unit, serial, last completed date, days remaining, all previously unavailable to the sender), an
email DEEP LINK via a new `CNG_APP_URL` Edge Function variable (absent => the old sentence, never
a guessed host), push UNSUBSCRIBE (browser + stored row; doing one alone leaves the server pushing
into a dead endpoint), a `pushsubscriptionchange` handler (re-subscribes but does NOT persist —
`cng_save_push_subscription` needs a session a worker does not have), a notification BELL with an
UNREAD count (a LINK not a dropdown, to avoid a second smaller inbox; unread NEVER
unacknowledged; hidden rather than showing a confident 0 when unreadable), and MARK ALL AS READ
(`cng_mark_all_alerts_read`, SECURITY INVOKER so RLS bounds the set; asserts it acknowledges
nothing). `/settings` is no longer a placeholder: notification preferences are reachable, and
NOBODY IS SUBSCRIBED BY DEFAULT. **Two DEFERRED BY DESIGN with reasons recorded**: Region is NOT a
preference (it is authorization — a preference able to widen it would be privilege escalation in a
settings control), and per-subject targeting is schema-supported but unexposed pending a
precedence UI. **One migration, 0036** — additive; the two delivery claim functions are DROPped and
recreated only because PostgreSQL cannot widen a RETURNS TABLE in place, and both stay
`service_role` only. Live verification is UNCHANGED and nothing new is claimed as live-verified.*

***PROMPTS 16-18 ARE DEPLOYED (Prompt 16-18A)** — see `docs/alerts-notifications.md` §27.
Production: **36 migrations**, `send-notifications` **v5** ACTIVE, `generate-alerts` NOT
redeployed (the reconciliation changed no file under it). Migration 0036 verified IN PRODUCTION by
query: `cng_mark_all_alerts_read` exists with `prosecdef = false` (**SECURITY INVOKER preserved**)
and `authenticated`-only grants, both claim functions remain `service_role` ONLY, 0 `authenticated`
UPDATE columns on `alerts`, 0 public tables without RLS. Both widened claim functions were
EXECUTED against the real schema (0 rows, no state change) so the new SQL is proven to run in
production, not only in replay. **CNG_APP_URL IS NOT VERIFIED, and a controlled test email would
NOT verify it**: test mode sends a FIXED body, while the deep link is built by `alertEmail()` in
QUEUE mode only, and production holds 0 alerts and 0 preferences, so no queue email exists without
fabricating an alert. NO EMAIL WAS SENT and NO PUSH WAS SENT. The push subscription is intact
(1 active, failure_count 0). **THE FRONTEND IS DEPLOYED BUT NOT VERIFIED**: this environment is
403-blocked at CONNECT for `cng-station-management.pages.dev`, so the bell, unread count,
mark-all-as-read, `/settings` preferences and push enable/disable are TEST VERIFIED ONLY and need
owner browser verification. Three words are kept strictly apart in the docs: TEST VERIFIED,
DEPLOYED, LIVE VERIFIED.*

***PROMPT 18A — a REAL PRODUCTION DEFECT on `/settings`**, found by owner browser verification:
*new row violates row-level security policy for table "notification_preferences"*. See
`docs/alerts-notifications.md` §28. **ROOT CAUSE**: `app_user_id` is NOT NULL with NO DEFAULT and
the client insert supplies no user id, so the column was NULL and
`WITH CHECK (app_user_id = cng_current_app_user_id())` evaluated NULL -> not true. RLS is checked
BEFORE the NOT NULL constraint would report, hence the policy message. **RLS VALIDATES OWNERSHIP,
IT NEVER POPULATES IT** — and the Prompt 16-18 test "writes no user identifier" asserted the buggy
behaviour as if it were the security property, passing while production was broken. Reproduced
locally with the identical message before anything was changed. Classification: frontend + schema
combined; the identity mapping was never at fault. **FIX — migration 0037, one statement**:
`ALTER COLUMN app_user_id SET DEFAULT cng_current_app_user_id()`. The client still sends no id so
it cannot spoof one; the database derives the owner from the verified Clerk subject, and the
function additionally requires `is_active`. NO policy weakened, NO grant widened, NO service_role
path. The WITH CHECK is unchanged and is now defence in depth (PREF-5). A SECOND, user-visible
half: a failed SAVE was rendered with the words of a failed LOAD and replaced the whole screen,
which is why it looked like a page that would not load — `loadError` and `saveError` are now
separate. **The regression tests were PROVED to fail against the pre-0037 schema.** 21 SQL
assertions plus 2 frontend tests, one of which caught a genuine slip in the fix itself.
**PROMPT 18 IS NOT CLOSED** until the owner confirms `/settings` works in production.*

*Notification delivery (Prompt 15.1) is built: migration **0034** plus the `send-notifications`
Edge Function and a Web Push opt-in — see `docs/alerts-notifications.md` §17. The
Alert/Delivery separation is unchanged and now asserted: a delivery failure leaves the alert
unchanged, un-acknowledged and un-duplicated, and a retry targets the SAME alert with a cap of
five attempts. **Recipients are opt-in only** — with no `notification_preferences` rows nothing
is enqueued, so nobody is silently subscribed, and production recipient policy remains DEFERRED.
The sender is **not an open relay**: queue mode takes recipients from the database, test mode
accepts only an address matching `CNG_ALERT_TEST_RECIPIENT`, and no browser role (not even admin)
may enqueue, claim or complete a delivery. Push subscriptions are saved by
`cng_save_push_subscription`, which takes no user parameter, so one user can never register, read
or delete another's. Permission is requested ONLY from an explicit click. **The VAPID PUBLIC key
is browser-visible by design** (`VITE_VAPID_PUBLIC_KEY`); the private key stays an Edge Function
secret and appears in no frontend file. **THE LIVE TESTS WERE NOT PERFORMED**: this build
environment answers 403 to CONNECT for `api.resend.com`, `api.supabase.com`, the Supabase project
host and `api.cloudflare.com`, so the test email, hosted secret verification, function deployment
and Cloudflare configuration are documented manual steps rather than completed ones — nothing was
simulated. Cron, the Cairo business date and the invoke-secret model are unchanged.*

*The Admin Module (Prompt 19) is built: `/admin/users`, `/admin/alert-settings`,
`/admin/data-quality`, `/admin/audit-log` — see `docs/admin-module.md`. **One additive
migration, 0038.** The read-first gap analysis found a REAL DEFECT rather than a missing
screen: `authenticated` already held DIRECT `UPDATE (role, is_active)` on `app_users` and full
INSERT/UPDATE/DELETE on `user_region_access`, gated only by `cng_is_admin()`. The policy was
correct; the SHAPE was not — the audit row was a separate client call an admin could simply not
make, nothing stopped an admin demoting or deactivating themselves or removing the LAST ACTIVE
ADMINISTRATOR, and a stale tab could silently overwrite a newer decision. Both grants are
REVOKED and replaced by narrow SECURITY DEFINER functions that verify admin, derive the actor
server-side, check a row-version precondition and write the audit IN THE SAME STATEMENT: **not
even an ADMIN may now change a role or a Region grant directly** (ADMSEC-13/14). Mapping status
is **DERIVED in SQL from what was proven, never supplied**, so a screen cannot declare a record
resolved by asserting it; the pre-existing composite foreign keys and `irv_status_shape_ck` do
the hierarchy enforcement and NONE was relaxed or re-implemented. `cng_admin_map_srv` initially
omitted `resolved_by`/`resolved_at` and `irv_resolved_attribution_ck` REJECTED the resolution —
the constraint doing exactly the job its comment claims. Only `is_enabled` is editable on an
alert rule (subject/threshold/days_before are rule IDENTITY; editing them would reinterpret
alerts already raised), and disabling deletes nothing. **No count is hard-coded**: the 1,104
staged-blocker figure is a PIPELINE fact and a frontend test fails on it appearing as a literal
anywhere in the shipped module. **Deferred with reasons recorded**: engineer Region-scoped
mapping (a definer function bypasses the RLS that would bound them, so the scope needs its own
hostile pass), bulk mapping, and vessel/detector/hose mapping mutation. **NOT DEPLOYED and NOT
LIVE VERIFIED** — 0038 is not applied to the hosted project.*

***PROMPT 19A — the missing Admin scope is now built** — see `docs/preimport-mapping.md`.
**Two additive migrations, 0039 and 0040.** The review checkpoint correctly found Prompt 19
PARTIAL: four of five asset types were count-only, the audit log rendered no before/after, and
there was no admin-level channel policy.

**PRE-IMPORT MAPPING (0039).** The 1,104 staged `needs_station_mapping` rows cannot enter their
canonical tables because `station_id` is NOT NULL — so the resolution moved EARLIER, to the
staging row, where the evidence still lives. **NO canonical `station_id` was made nullable, no
constraint was relaxed and no staged row was dropped** (PREMAP-33 asserts all four columns are
still NOT NULL). `import_mapping_decisions` records one human decision per SOURCE ROW, keyed by
`source_row_key` so it survives a later dry run. **A row decision is NOT an alias**: confirming
one row says nothing about another carrying byte-identical text, and PREMAP-23/24 plus a frontend
test assert no alias or owner-confirmed rule is ever created. A correction SUPERSEDES rather than
overwrites; `imd_one_active_per_source_row` (a partial unique index) makes "exactly one active
decision" a DATABASE property; `imd_unit_station_fk` makes a Unit from another Station
inexpressible; the resulting status is DERIVED in SQL. `p_expected_decision_at` is both the
stale-write AND the duplicate guard. The decision table has **no INSERT/UPDATE/DELETE policy and
no grant** — the SECURITY DEFINER function is the only writer, so not even an admin can forge,
edit or delete a decision. Admin only; engineer/manager Region-scoped mapping stays DEFERRED and
was not opened by accident.

**PROMPT 21 CONSUMPTION** is built and tested but NOT executed: `src/import/mappingDecisions.ts`
plans a commit from `v_import_confirmed_mappings`, using the confirmed ids, holding every row
without a decision, and copying `sourceRaw`/`sourceRowKey`/`sourceRowHash`/provenance through
unchanged.

**CHANNEL POLICY (0040).** `/settings` is a USER saying "I want email"; `notification_channel_policy`
is the ORGANIZATION saying "email is available at all". Effective delivery requires BOTH. Disabling
writes NO preference row, so re-enabling restores the same audience — the entire reason it is a
separate table rather than a bulk preference update. The gate lives in
`cng_enqueue_alert_deliveries`, otherwise byte-for-byte the 0034 logic, so it applies to every
caller. All three ship ENABLED and Prompt 15-18 delivery is unaffected. **IN-APP IS MANDATORY BY
DESIGN**: it is the alert READ surface, not a delivery channel, and `ncp_in_app_mandatory_ck` makes
disabling it impossible — the screen states that instead of offering a toggle that always refuses.
**Severity was NOT invented**: no severity column exists on `alert_rules` or `alerts`, and none was
added to satisfy a checklist. Subject, threshold and days_before stay immutable rule identity.

**HOSTILE GAPS CLOSED**: the Dispenser equipment-parent path (GAP-1/2/3), malformed UUID and
out-of-enum input (GAP-4..7), and cross-Region read vs mutation (GAP-8..11). Prompt 19's user
administration is re-asserted AFTER the new migrations (REG-1..6). The gate now also replays the
UPGRADE path — a production-equivalent database at 37, then 0038/0039/0040 in order, then both SQL
suites against the upgraded database. **NOT DEPLOYED and NOT LIVE VERIFIED.***

***PROMPT 19B — a REAL CORRECTNESS DEFECT in 19A, found by owner review of commit 0ca11c1** —
see `docs/preimport-mapping.md` §2a. **One additive migration, 0041.** 0039 keyed a human mapping
decision on `source_row_key` alone — the stable `(file, sheet, row)` identity. **That says WHERE a
row was, not WHAT the administrator read.** A workbook is a live document: rows are inserted,
deleted, re-ordered and overwritten, so the same file/sheet/row can hold a different asset next
month, and a later dry run would have matched the old decision by key and attached last month's
Station to this month's vessel — **a fabricated physical relationship arrived at without anyone
guessing**, exactly what data principle #8 exists to prevent. `import_staging_rows.source_row_hash`
already existed and already changes with content; it was simply never recorded on the decision.
**FIX**: `reviewed_source_row_hash`, captured SERVER-SIDE — it is a parameter of NO function
(PREHASH-1), so a caller cannot claim to have reviewed evidence it never saw. Reuse now requires
BOTH key and hash. A key match with a hash mismatch is `stale_source_decision`: NOT applied, NOT
silently demoted to "no decision", old Station/Unit NEVER injected, and given its OWN data-quality
queue so the reason a ruling lapsed stays visible. The flag follows the evidence in both
directions (PREHASH-14/15). The UI says *"Previous decision requires re-review because source
evidence changed"* and **pre-fills nothing**, so the old answer cannot be clicked through. **The
regression tests were PROVED to fail against the 0ca11c1 behaviour** — 3 of 21 — before being
accepted.

**A SECOND DEFECT, FOUND BY THE SUITE**: `CREATE OR REPLACE VIEW` does NOT preserve reloptions.
Migration 0039 replaced `v_admin_data_quality` without restating
`WITH (security_invoker = true)`, silently turning it into an OWNER-RIGHTS view that bypassed the
RLS meant to bound it — an engineer or viewer could have read Region-wide counts. The GRANT was
never the protection; the invoker setting was. 0041 restates it on all three replaced views, and
the suite now asserts it as a CATALOG property for every admin view (VIEWSEC-*) so it cannot lapse
again. **NOT DEPLOYED and NOT LIVE VERIFIED.***

*The Reports Module (Prompt 20) is built: `/reports` with routed Due & Overdue, SRV, Vessels,
Gas Detectors, Hoses, Data Quality and Notification Activity — see `docs/reports.md`.
**One additive migration, 0042, containing exactly one view.** The read-first gap analysis found
that almost every report was already served by an existing RLS-bounded view
(`v_installed_srv_management`, `v_warehouse_srv_management`, `v_vessel_management`,
`v_gas_detector_management`, `v_hose_registry`, `v_alert_inbox`, `v_data_quality_queue`), so
Reports READ those rather than duplicating them. The ONE genuine gap was a unified cross-family
due list — `v_dashboard_due_summary` counts but does not enumerate — so `v_report_due_compliance`
was added and nothing else. **NO new RPC, NO new table, NO new index** (RPTSEC-10/11), and the
existing partial `*_due_idx ... WHERE precision = 'exact_date'` indexes are already exactly a due
report's predicate.

**DUE SEMANTICS ARE NOT RE-DERIVED**: the unified view carries the family views' own `days_left`
and `due_status`, which come from `cng_days_left()`/`cng_due_status()` — the alert engine's
functions. RPTDUE-15/16 assert every report row equals a fresh evaluation of those functions on
its own date, so there is ONE interpretation and nothing to drift. A YEAR-ONLY date never enters
an exact bucket and yields NO days-remaining figure at all; unknown is neither compliant nor
overdue; boundaries are exact (day 7 is due_7, day 8 is due_15).

**AUTHORIZATION IS THE DATABASE, NOT THE FILTERS**: RPT-9 asserts that an engineer running the
report with NO Region filter still receives only their own Regions, and RPT-12 that a
Station-unconfirmed record stays admin/manager only. Reports MUTATE NOTHING — no RPC, no write,
no acknowledgement, no mapping control; corrections stay in `/admin/data-quality` behind a link.
**VIEWSEC-ALL now asserts from `pg_class.reloptions` that NO view in the schema runs with owner
rights** — not only those a `v_admin%` naming pattern would catch, because a report reads six
views named neither way and the Prompt 19B defect would have been invisible there.

**CSV EXPORT RE-RUNS THE SAME AUTHORIZED QUERY** — same view, same filters, same order, same RLS,
in bounded 1,000-row chunks to a documented 10,000-row ceiling that the UI states when reached.
Formula injection is neutralised by quoting and apostrophe-prefixing TEXT cells only, so a genuine
number still sorts numerically and the guard PREFIXES rather than edits; UTF-8 with a BOM because
Arabic Station names are ordinary data here. Filtering, ordering, counting and paging are all
server-side with a deterministic id tiebreak, so paging cannot duplicate or omit a row. **Empty
production is a first-class state**: "no canonical assets have been imported yet" and "no records
match the selected filters" are told apart and neither is an error. **NOT DEPLOYED and NOT LIVE
VERIFIED.***

***PROMPT 20A — a REAL COMPLETENESS DEFECT in Prompt 20**, found by independent review of
commit 854389d. **One additive migration, 0043, containing two views.** The Data Quality report
read `v_data_quality_queue` alone — CANONICAL assets only. Production has committed none, so the
report read CLEAN while the staged import carried real unresolved evidence, including the
`stale_source_decision` state Prompt 19B added precisely so a lapsed ruling stays visible. A
compliance report saying "nothing to see" while the evidence exists is worse than no report.
`v_report_data_quality` unions THREE layers: canonical (Region-scoped), staged
(`v_admin_staged_mapping_queue`) and open `import_issues`, using the EXISTING `import_issue_type`
enum — DQR-7 asserts no issue type was invented. **NO AUTHORIZATION WAS WEAKENED**: all three
staging sources are already manager/admin-only by their own SELECT policies, and because the view
is `security_invoker` each branch keeps its own RLS, so the layering is automatic — a viewer and an
engineer read the canonical layer alone (DQR-12/13/17) and the Station-unconfirmed protection is
intact (DQR-16). A Region-scoped user is TOLD staging is out of scope rather than left to infer it
is absent. `stale_source_decision` is its own issue kind and its own summary metric, never
collapsed into awaiting or recorded (DQR-4/5/6). Reports stays READ-ONLY: a manager who can now SEE
staged evidence still cannot decide it (DQR-19), supersede it (DQR-20) or alter raw staged evidence
(DQR-21). **SECOND DEFECT**: the gas-detector report read `v_gas_detector_management`, which
deliberately UNIONs recorded ABSENCE — evidence that an area has no detector, carrying
`detector_id IS NULL`. 0042 filtered it from the due report but the ASSET report did not, so
absence could render as an installed detector AND a NULL identity column leaves paginated sorting
without a stable key. `v_report_gas_detectors` applies the filter IN THE DATABASE (GDR-2/3/5); the
due report is unchanged (GDR-6). One pre-existing assertion was corrected: MGR-6 counted
`import_issues = 1` absolutely and so tracked a suite-wide fixture total rather than the access it
means to assert.

**PROMPT 20 IS DEPLOYED (Prompt 20 merge + deployment).** Main is at `792df36` by fast-forward merge. Production (`cng-station-management`, ref `ypkggegquetvpsflkaxg`) went from **41 to 43 migrations**: 0042 `report_due_compliance` then 0043 `report_data_quality`, applied sequentially, each succeeding. Verified IN PRODUCTION by catalog query: all three report views exist with `security_invoker = true`, `authenticated` holds SELECT and **no write grant** on them (the 9 write grants first observed were `postgres`, the view owner's implicit privileges present on every view in the schema — a defective assertion, not a defective deployment), 0 `authenticated` UPDATE columns on `alerts`, the claim functions remain `service_role` only, `cng_mark_all_alerts_read` is still SECURITY INVOKER, `cng_admin_decide_staged_mapping` is still admin-gated, and 0 public tables lack RLS. **NO DATA WAS CREATED**: every asset table, staging, `import_issues`, `import_mapping_decisions` and `alerts` are 0 rows; `app_users` is 1 and `audit_logs` 1, both pre-existing. A read-only probe as `authenticated` with no verified subject returned 0 rows from every report view and was discarded by a deliberate `RAISE`. **CLOUDFLARE IS NOT OBSERVED**: this environment answers 403 at CONNECT for `api.cloudflare.com` and `cng-station-management.pages.dev`, and the Cloudflare tooling available here covers Workers/D1/KV/R2, not Pages — the push to `main` is confirmed at the GitHub remote, but the Pages build is NOT verified. **THE FRONTEND IS NOT LIVE VERIFIED**: `/reports` needs owner browser acceptance.***

***PROMPT 20B — a REAL PRODUCTION DEFECT in the report contract**, found by owner browser
verification: *column v_report_gas_detectors.station_display does not exist*, with equivalent
failures on Vessels and Hoses. **NO MIGRATION WAS REQUIRED — 0044 was NOT created.** The defect was
entirely frontend: every report shared one `HIERARCHY_COLUMNS` constant naming `station_display`,
which migration 0016 defines as `coalesce(station_name, source_station_name_raw)` and which exists
ONLY where a Station can be unconfirmed — installed SRVs, whose `station_id` is nullable. Storage
vessels, recovery tanks, gas detectors and hoses all carry `station_id NOT NULL`, so there is no
raw fallback to fall back TO and their views correctly never had the column. `v_report_due_compliance`
already said so in SQL: its vessel, detector and hose branches select `v.station_name` into the
`station_display` position. **Adding the alias to three views would have been inventing a column to
satisfy frontend code**; the fix names the Station column per report instead. A FULL SEVEN-REPORT
CONTRACT AUDIT was run before any change, machine-comparing every column each report selects,
renders, filters, searches, orders, identifies and summarises against `information_schema.columns`:
it found **exactly three mismatches, all `station_display`, all on the three reports the owner
observed** — Due, SRV, Warehouse SRV, Data Quality and Notification Activity were clean, so no
latent failure was left behind. **THE REAL GAP WAS THE VERIFICATION BOUNDARY**: the SQL suites do
not know what the browser asks for and the frontend tests do not know what the database exposes, so
the defect passed every check. `scripts/verify-report-contract.mjs` now closes it, wired into the
gate against the database built from zero, and was **PROVED to fail against the defective spec**
before being accepted. Security is untouched: no view, migration, grant, policy or RLS boundary was
changed, and no data was created.***

***PROMPT 20 IS CLOSED — PASS WITH DOCUMENTED POST-IMPORT / ROLE-SPECIFIC VERIFICATION ITEMS
(Prompt 20D).** Owner production browser verification is complete for everything that can be
meaningfully verified BEFORE the controlled import. **LIVE VERIFIED in production**: `/reports`
loads; all seven tabs route; Due & Overdue renders the correct canonical-empty state; the Data
Quality admin view explains the canonical / staging / import-issue layers and the
`stale_source_decision` semantics; Vessels, Gas Detectors and Hoses all render after the 20B
contract fix, with the `station_display` failure gone from each; Reports expose no correction or
mutation control and Data Quality directs corrections to Admin. **`/settings` persisted a changed
notification preference across a full production refresh, which CLOSES PROMPT 18** — the 18A fix
(migration 0037) is confirmed working in production.

**THREE ITEMS ARE DEFERRED TO AFTER THE CONTROLLED IMPORT, and deliberately NOT verified by
manufacturing data**: Arabic CSV content against real Station names, CSV formula-injection
behaviour against real source text, and non-empty deterministic paging and sorting. All three need
REAL ROWS, production holds none, and creating rows to watch a report render them would fabricate
records to produce a passing verification — the precise thing data principle #1 and every prior
prompt's no-fabrication rule forbid. They remain covered by automated tests (the CSV tests assert
the downloaded file's bytes, including the BOM and the apostrophe prefix on text cells only) and
are LIVE-VERIFIABLE the moment Prompt 21 commits real assets.

**ONE ITEM IS DEFERRED AS ROLE-SPECIFIC**: viewer/engineer Data Quality visibility — that a
Region-scoped user reads the canonical layer alone and is TOLD staging is out of scope. It is
asserted in SQL against real RLS (DQR-12/13/16/17), and verifying it live needs a genuine
non-admin account. **The owner's Admin account must NOT be downgraded to perform it**, because
demoting the only active administrator to observe a report is a real authorization change made for
a cosmetic reason, and Prompt 19's own guards exist to prevent exactly that.

This status update changed NO application code, schema, migration, production data, role,
notification setting or security configuration, and created no records.***

***PROMPT 20E CORRECTION, AND PROMPT 20F — THE PERSISTED STAGING WRITE PATH.**
**A 20E STATEMENT WAS WRONG**: I reported the source workbooks as unreachable. I had searched the
REPOSITORY TREE, not the filesystem. All six are present in this session's working area, read-only
and dated 2026-09-14, and the dry run runs against them. The rest of 20E stands — production
staging really is empty, and the reason really is that `src/import/` has no database write path.

**PROMPT 20F CLOSES EXACTLY THAT GAP. One additive migration, 0044, adding NO table, NO column and
NO enum** — `import_runs`, `import_batches` (with `file_checksum`), `import_staging_rows`,
`import_issues` and `import_source_conflicts` have existed since 0004/0026 and already hold
everything needed. Only the WRITER was missing, so a second import architecture was not invented.

**THE CANONICAL FIREWALL IS STRUCTURAL, NOT INTENTIONAL.** `cng_stage_import_batch` contains five
INSERTs whose targets are literals — the allowlist IS the body — and NO dynamic SQL at all, so
`target_table` arrives as DATA in a column and a caller can never name a destination. STG-2 and
STG-3 re-derive this from `pg_proc.prosrc` rather than trusting the comment, and the STG-3 pattern
was PROVED to detect `INSERT INTO stations`, `UPDATE hoses` and `import_mapping_decisions` before
being accepted. Verified empirically too: committing the real 7,163-row payload into a local
database left `stations`, `units`, all five asset tables and `import_mapping_decisions` at **0**.

**IT IS AN OPERATOR ACTION, NOT A BROWSER ACTION.** EXECUTE is granted to `service_role` ONLY — not
even an admin in a browser can call it — and the runner is a server-side CLI
(`scripts/stage-import.mjs preview|commit`). Putting it in the frontend would have meant uploading
workbooks to a browser-reachable endpoint or granting `authenticated` INSERT on the import tables,
adding permanent attack surface for a task one operator performs a handful of times.
**STGSEC-6 asserts `authenticated` still holds ZERO write grants on every import table**, and
STGSEC-7 that all five stay readable so Admin → Data Quality keeps working.

**REPLAY IS A DATABASE PROPERTY.** The manifest fingerprint hashes every filename with its SHA-256,
sorted, so identical content gives an identical value and one changed byte gives a different one;
`import_runs_manifest_fingerprint_uq` makes one completed run per distinct source content
enforceable. Proved by attack: committing the identical payload twice was REFUSED by that index
(psql exit 3), leaving 7,163 rows, 1 run and 7 batches untouched — which also demonstrates
atomicity, since one call is one transaction and a partial batch cannot exist to look ready. The
index is PARTIAL on `completed_at` so a failed run never blocks a corrected retry. Abandonment is a
STATE (`rolled_back`), never a DELETE, is batch-scoped by a required id, and REFUSES a run with
canonically committed rows or referenced mapping decisions.

**STAGING DECIDES NOTHING**: no `import_mapping_decisions` row, so the 0039/0041 content binding is
untouched, and no Station, Unit or asset is created. **NOTHING WAS WRITTEN TO PRODUCTION** — every
write was to an isolated local database.

**RECONCILIATION IS EXACT.** The preview reproduces the historical dry run to the row: 7,163 staged
rows; stations_units 402, unit_attributes 325, installed SRV 2,662, warehouse SRV 2,188, storage
vessels 671, recovery tanks 528, gas detectors 316, hoses 71; and the four NOT-NULL-`station_id`
families give **433 / 403 / 219 / 49 = 1,104** exactly. 3,402 issues, 0 blocking, 0 source
conflicts. The `SS-4R3A` owner rule applied to 48 rows in its one authorized context and nowhere
else; the `Repair Kit` sheet was excluded and staged no row. **ZERO unexplained difference.**
***

***PROMPT 21C — THE STAGE A CANONICAL HIERARCHY PIPELINE IS BUILT AND VERIFIED, AND DELIBERATELY
NOT COMMITTED** — see `docs/stage-a-hierarchy.md`. **One additive migration, 0046**, adding three
functions and exactly ONE column (`import_staging_rows.committed_entity_kind`, nullable, with an
explicit CHECK allowlist). Phase 1 re-confirmed the Stage A source from production READ-ONLY and
every required value matched: 402 `stations_units` rows, 157 Stations, 188 Units, East 42/56,
West 40/58, Delta 75/74, Canal/Alex/Upper 0/0, 0 Region conflicts, 0 job conflicts within a Unit,
0 compressor-model conflicts, 156 Stations with deterministic Unit structure, 1 Station with no
Unit, 4 job numbers reused across Units.

**IDENTITY IS THE DATABASE, NOT THE PIPELINE.** Station = `(region_id, normalized_name)` and Unit =
`(station_id, normalized_name)` were ALREADY `stations_region_norm_uq` and `units_station_norm_uq`,
and `units_station_region_fk` already made a Unit in a different Region from its Station
inexpressible — so uniqueness is relied on, never re-implemented. Job number is NOT identity (4 are
reused in this very run) and a missing one never blocks a Unit. No fuzzy matching, no cross-Region
matching, no Station created from asset data: **Canal, Alex and Upper contribute zero rows and
therefore receive zero Stations**, which is a finding and not a gap to fill.

**THE APPROVAL IS CONTENT-BOUND AND FAILS CLOSED.** `cng_stage_a_commit` REQUIRES both the manifest
fingerprint (source content) and the preview fingerprint (the exact proposal) and re-derives both
inside its own transaction — a NULL, a blank or a stale value REFUSES, so there is no "approve
whatever is current" path that could drift between preview and commit. The preview fingerprint
covers every proposed entity AND the `source_row_hash` of the evidence behind it, so changing the
evidence without changing the conclusion still lapses the approval (the 0041 rule, applied to the
hierarchy). Preview, fingerprint and commit all read ONE function, `cng_stage_a_proposal`, so what
is approved and what is written cannot be two code paths.

**A GUARD FIRED ON MY OWN TEST FIXTURE AND WAS RIGHT TO.** Two `/` spacings of one name are ONE
identity after 0045 but TWO display spellings, and Prompt 21B approved the equivalence for
COMPARISON ONLY, explicitly not the canonical name — so the commit REFUSES rather than tie-breaking
a spelling no human has chosen. Measured on the real run this never arises: **ZERO** Station
identities and **ZERO** Unit identities carry more than one spelling. The fold earns its keep at
Stage B instead.

**VERIFIED AT FULL SCALE LOCALLY** through the real operator runner (`scripts/stage-a.mjs`):
402 rows -> **157 Stations, 188 Units, 1 Station with zero Units, 402 rows linked (340 to a Unit,
62 to a Station), 0 aliases, 0 mapping decisions, 0 assets**, with a drifted approval refused, the
authorized commit succeeding and a replay refused, in that order. The fixture was generated from the
production run's STRUCTURAL SKELETON — per-Station row and Unit counts — with synthetic names: **no
Arabic identity string was hand-transcribed**, that being the corruption risk this project exists to
prevent, and Arabic fidelity is proved separately. Lineage does NOT force a false one-row-one-entity
model: a row points at its FINEST entity and several rows may share one.

**AUTHORIZATION**: all three functions are `service_role` ONLY — an `authenticated` call is refused
with `insufficient_privilege`, proved by attempting it, not by reading a grant table. No function
takes an actor. The commit is SECURITY DEFINER with a pinned `search_path`; the two read functions
are deliberately NOT definer. No dynamic SQL, three literal targets, re-derived from `pg_proc.prosrc`.

**PHASE 8 SIMULATION (read-only, nothing deployed)**: of the 1,104 `needs_station_mapping` rows,
**281 rows** gain exactly one same-Region Station candidate and **0** identities gain more than one.
The count is **78 RAW SPELLINGS = 69 NORMALIZED IDENTITIES** — Prompt 21B's 78 counted raw spellings;
both are right and count different things, and the STOP-listed 281/0 hold under either unit. Kept
strictly distinct: 15 identities match a UNIT name (not a Station match), 1 matches only in ANOTHER
Region (not a match at all — Region is identity), and 801 `needs_equipment_mapping` rows are a third
state Stage A does not touch. Every one stays an explicit human decision.

**NOT DEPLOYED AND NOT COMMITTED.** Production re-verified after the work: **45 migrations**, 0 Stage
A functions, 0 `committed_entity_kind` column, stations 0, units 0, aliases 0, mapping decisions 0,
assets 0, 7,163 staging rows with 0 committed, 0 tables without RLS. Migrations 0044 and 0045 are
byte-identical (0045 SHA-256 `e8b92cc8...` unchanged).*

***PROMPT 21D — THE STAGE A CANONICAL HIERARCHY IS COMMITTED TO PRODUCTION** — see
`docs/stage-a-hierarchy.md` §10. Migration 0046 was deployed in 21C-DEPLOY (45 -> **46**, recorded
once, file SHA-256 `478dd95c...`), and deployment was proved BYTE-EXACT rather than merely applied:
the `pg_proc.prosrc` MD5 of all three functions matched the locally built approved copy, and
`cng_normalize_name` hashed identically so 0045 was demonstrably untouched.

`cng_stage_a_commit` was then invoked **EXACTLY ONCE**, after a final pre-commit guard re-ran the
preview and matched every approved value. Result: **157 Stations, 188 Units, 402 staging rows
linked** — East 42/56, West 40/58, Delta 75/74, Canal/Alex/Upper 0/0. **`stations` and `units` are
no longer empty, and Prompt 21's canonical hierarchy now exists.**

**NOTHING WAS INVENTED.** The 1 Station with zero Units is Delta source row 352, exactly the one
approved, and NO Unit was created for it. All four reused job numbers are each held by 2 Units
across 2 distinct Stations — nothing merged, because job number is an attribute and never identity.
2 Units keep `job_number` NULL and `job_number_raw` matches `job_number` on every row. 0 Stations
carry an invented bay status or note, 0 Units an invented dispenser/hose/storage count, 0 records
are flagged `needs_review`. 0 duplicate identities, 0 names spanning two Regions, 0 Region
mismatches, 0 missing provenance.

**LINEAGE RECONCILES EXACTLY, WITHOUT A FALSE ONE-ROW-ONE-ENTITY MODEL**: 402 linked / 0 unlinked;
340 rows -> a Unit and 62 -> their Station, which matches the 340 rows naming a Unit and the 62 not,
so no row was classified against its own evidence (0 kind/evidence mismatches in either direction).
0 orphans, 0 wrong-type pointers, a SINGLE `committed_at` across all 402 (one transaction), all 188
Units referenced, every Station and Unit source-supported, and **0 non-structural staging rows
touched**.

**THE FIREWALL HELD**: aliases 0, `import_mapping_decisions` 0, all eight canonical asset tables 0,
Canal/Alex/Upper 0/0, and 0 Stations sourced from any batch but the structural workbook.
**REPLAY WAS NOT RE-TESTED DESTRUCTIVELY**: Gate 5's predicate now evaluates TRUE with 402
satisfying rows, both identity unique constraints stand as a second barrier, and STAGEA-27 already
proves the refusal locally. Security re-verified after the commit: 46 migrations, 0 tables without
RLS, Stage A EXECUTE authenticated 0 / anon 0 / service_role 3, commit and normalizer prosrc
unchanged, normalizer still IMMUTABLE, Station uniqueness still Region-scoped and Unit uniqueness
still Station-scoped, 0 browser write grants on `import_staging_rows`.

**STAGE B IS UNBLOCKED AND STILL ENTIRELY A HUMAN DECISION.** Re-measured against the REAL
hierarchy: 78 raw spellings = 69 normalized identities = **281 rows** gain exactly ONE same-Region
Station candidate, **0** gain more than one, and 1 identity (5 rows) matching only in ANOTHER Region
stays unmatched because Region is identity. Of the 281 — storage vessels 100, recovery tanks 91,
gas detectors 64, hoses 26 — 240 sit under a Station with exactly one Unit, 38 under several, 3
under none. **"One Unit under the candidate Station" is a NARROWING, NOT A DETERMINATION**; assigning
those 240 by count is exactly the distribution rule §4 permanently forbids. All 281 remain
`needs_station_mapping`, every lifecycle count is unchanged, and `import_mapping_decisions` is
still 0. No asset was imported, no alias created, no mapping decision written.*

***PROMPT 22A — THE STAGE B BATCH STATION-MAPPING MECHANISM IS BUILT AND VERIFIED, AND NO
PRODUCTION DECISION WAS WRITTEN** — see `docs/stage-b-station-mapping.md`. **One additive migration,
0047**, adding three functions and NO table, column or enum. Phase 1 independently recomputed the
candidate set from production READ-ONLY and it reconciles exactly: the four-family blocker
population is **1,104 = 281 candidates + 823 non-candidates**, with **78 raw spellings = 69
normalized Region-aware identities**, 0 multi-candidate rows, families **100/91/64/26**, and the
1 other-Region-only identity (5 rows) sitting INSIDE the 823. No identity is partly candidate and
partly not, so grouping by identity is safe.

**IT REUSES THE EXISTING ARCHITECTURE, NOT A PARALLEL ONE.** `import_mapping_decisions` (0039) plus
its content binding (0041) already hold one decision per source row, bound to the `source_row_hash`
the decider read, superseding rather than overwriting, with `imd_one_active_per_source_row` making
"exactly one active decision" a DATABASE property. **The resulting status is not a new rule
either**: the batch uses the identical expression `cng_admin_decide_staged_mapping` already
derives, so all four families advance `needs_station_mapping -> needs_unit_mapping` and nothing
else. Station confirmation is NOT Unit confirmation and NOT equipment resolution.

**ONE DELIBERATE DEVIATION, WITH THE REASON RECORDED.** Prompt 22A asked for a `service_role`-only
function; **the schema forbids it**. `import_mapping_decisions.decided_by` is
`NOT NULL REFERENCES app_users(id)` because §9 requires every mapping change to record who made it
and §10 forbids a forgeable actor. A `service_role` caller could satisfy that column only by taking
an actor PARAMETER (which the same prompt forbids) or by making human rulings UNATTRIBUTED. So the
actor is derived server-side from the verified Clerk subject via `cng_require_admin()`, exactly as
the single-row path has since 0039, and EXECUTE is `authenticated` only — where the ADMIN CHECK, not
the grant, is the gate. Viewer, engineer, regional manager, deactivated account, no-subject session
and anon are each refused BY ATTACK (STAGEBSEC-4..9). Stage A stays `service_role`-only because a
Station carries no `created_by` (STAGEBSEC-14).

**THE CANDIDATE SET IS DERIVED, NEVER SUPPLIED.** Exactly one same-Region Station by normalized
name; no similarity, suffix stripping, edit distance or alias lookup. Other-Region matches, unmatched
names, rows past this step, already-decided rows and installed SRVs are excluded BY CONSTRUCTION.
**Same-Region ambiguity is UNREACHABLE, not merely unhandled** — `stations_region_norm_uq` forbids
two Stations sharing a normalized name in one Region, proved by attempting the duplicate
(STAGEB-36). **Equipment inference is STRUCTURALLY IMPOSSIBLE**: the decision table has no equipment
column at all, asserted from `information_schema` (STAGEB-21).

**REVIEW IS GROUPED, THE COMMIT IS NOT.** An owner reads 69 identities carrying every raw spelling,
the exact staging row ids and their hash evidence; the commit stays bound to all 281 individual
rows. The preview fingerprint folds in, PER ROW, the staging row id, Region, Station id, normalized
identity, display name, `source_row_hash`, `mapping_status` and whether a decision already exists —
so one comparison catches every drift the prompt lists, including ambiguity and disappearance via
set membership.

**VERIFIED AT FULL SCALE LOCALLY** over a 1,104-row fixture on the real 157/188 hierarchy:
**281 decisions across 69 Stations, 0 Unit ids, 0 equipment ids, 0 Region mismatches, 0 hash
mismatches, 823 blockers left undecided, 0 other-Region rows decided, hierarchy unchanged, 0
aliases, 0 canonical assets, 281 audit rows**. **ATOMICITY WAS PROVED, NOT ASSUMED**: 281 written
inside an explicit transaction then rolled back left **0**. Replay was refused at the fingerprint
gate. Nine refusal scenarios each left ZERO decisions behind.

**THE REMAINING 823 / 247 (read-only, no fuzzy match proposed)**: Upper 266 rows, Alex 199, Canal
171, Delta 99, West 82, East 6. **631 of the 823 are in Regions with ZERO canonical Stations** —
Alex, Canal and Upper have no structural source, so this is not a mapping problem but a missing
source, and inventing Stations from asset names is what §8 forbids. 178 rows carry a name no Station
in their Region holds, 9 match a UNIT name rather than a Station, 5 match only in another Region.
All 823 retain a raw source name.

**NOT DEPLOYED AND NO PRODUCTION DECISION WRITTEN.** Production re-verified: 46 migrations, 0 Stage
B functions, stations 157, units 188, `import_mapping_decisions` **0** with an all-time
`n_tup_ins` of **0**, aliases 0, canonical assets 0, all 1,104 four-family rows still
`needs_station_mapping`, 0 tables without RLS. The production preview
(**`a014745d...e0cbe769`**, 69 groups / 281 rows, all deterministic) was computed READ-ONLY by
inlining the identical derivation, validated byte-identical to the deployed functions against a
local database. Migrations 0044, 0045 and 0046 are byte-identical.*

***PROMPT 22B — MIGRATION 0047 IS DEPLOYED AND THE STAGE B STATION PREVIEW IS VERIFIED IN
PRODUCTION; NO MAPPING DECISION WAS WRITTEN** — see `docs/stage-b-station-mapping.md` §10-13.
Production went **46 -> 47**, recorded once (`20260917094822 stage_b_station_batch`), file SHA-256
`a9a63f24...` matching the approved commit 9548e87 byte for byte. Deployment was proved BYTE-EXACT:
the `pg_proc.prosrc` MD5 of all FOUR deployed functions matches the locally built approved copy, and
`cng_normalize_name` hashes identically so 0045 is demonstrably untouched. **The migration executes
NO DML** — its only two INSERTs are inside the commit function's body; at migration time it creates
four functions, four comments and twelve grant/revoke statements and changes no table, column, enum,
index or policy.

**THE OWNER APPROVED THE ADMIN-GATED, SERVER-DERIVED-ACTOR SHAPE.** `decided_by` stays NOT NULL, no
actor is accepted from the client, attribution is not weakened, and Stage A's `service_role`-only
architecture is unchanged (Stage A browser EXECUTE 0, service_role 3, re-verified after deployment).

**DEPLOYED SECURITY VERIFIED**: commit `prosecdef` true and the three read paths false and STABLE
(so they cannot write); `search_path` pinned on all four; EXECUTE anon **0**, authenticated 4;
**0** actor parameters; the commit calls `cng_require_admin()`; **0** browser write grants and **0**
write policies on `import_mapping_decisions`; 0 tables without RLS. **NO DYNAMIC SQL**: no `EXECUTE`
and no `quote_ident` in the deployed body; the single `format()` builds the audit summary MESSAGE,
never SQL. **ATTACKS RUN IN PRODUCTION, READ-ONLY**: `cng_require_admin()` (not the commit, which
22B forbids invoking) refused both a claims set with NO subject and a subject mapping to no
`app_user`, each with 42501, and the probe aborted deliberately. **A MINOR FINDING RECORDED**: an
EMPTY-STRING `request.jwt.claims` fails with a JSON parse error (22P02) rather than 42501 — it still
FAILS CLOSED, but the error class differs; no code was changed for it. **Role-specific live refusal
(viewer/engineer/manager/deactivated) is DEFERRED with the reason**: proving it in production would
need either invoking the commit or creating test `app_users`, so it stays asserted against real RLS
with real personas (STAGEBSEC-4..9).

**THE DEPLOYED PREVIEW FINGERPRINT IS `a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769`
— EXACTLY the expected value**, which also confirms the 22A inline reproduction was faithful.
**69 groups / 281 rows, all 69 DETERMINISTIC STATION CANDIDATE, 0 OWNER REVIEW, 0 warnings, 0 rows
already decided.** Delta 60 groups/199 rows, West 9 groups/82 rows; families 100/91/64/26. **69
distinct Station targets**, all existing and Region-correct; **78 raw spellings** across the 69
identities (9 groups carry more than one written form); group sizes 1 to 32. **Hash coverage is
complete and unambiguous: 281/281 rows carry a 64-character `source_row_hash` and all 281 are
DISTINCT**, with every group's hash and row-id arrays matching its row count. **The preview wrote
nothing**, proved by counters either side: decisions `n_tup_ins` 0 -> 0, audit 1 -> 1, staging
`n_tup_upd` 402 -> 402.

**EXPECTED EFFECT IF LATER APPROVED (read-only simulation)**: all 281 rows
`needs_station_mapping -> needs_unit_mapping`, producing exactly **281** decisions, each with the
staged row identity, the confirmed Station, `confirmed_unit_id = NULL`, the server-derived Admin
actor and an audit row. The decision table carries **0** equipment columns, so equipment parentage
is not expressible. **The remaining 823 are provably disjoint — 0 rows in both sets** — and their
reasons are unchanged: 631 in Regions with zero canonical Stations, 178 with no Station of that name
in their Region, 9 matching a Unit name, 5 matching only in another Region.

**PRODUCTION FIREWALL AFTER DEPLOYMENT AND PREVIEW**: 47 migrations, regions 6, stations 157, units
188, `import_mapping_decisions` **0** with an all-time `n_tup_ins` of **0**, aliases 0, canonical
assets 0, all 1,104 four-family rows still `needs_station_mapping`, 7,163 staging rows, 0 tables
without RLS. Migrations 0044, 0045 and 0046 are byte-identical.*

***PROMPT 22C — STOPPED AT THE ADMIN GATE; NO MAPPING DECISION WAS COMMITTED** — see
`docs/stage-b-station-mapping.md` §14-15. The final pre-commit guard PASSED on every approved value
(preview fingerprint `a014745d...e0cbe769`, manifest `764d3c0f...`, 69 groups / 281 rows, families
100/91/64/26, all 281 still `needs_station_mapping`, 0 already decided, baseline 47 migrations /
157 Stations / 188 Units / 0 decisions / 0 aliases / 0 assets / 1,104 blockers).

**PHASE 2 FAILED, AND THE DESIGN INTENDS IT TO.** `cng_stage_b_station_commit` derives its actor
from `cng_require_admin()`, which reads the verified Clerk subject. This session's context is
`current_user = postgres` (an operator connection, not superuser) with **no `request.jwt.claims`, no
verified subject, and `cng_current_app_user_id()` not resolving** — so the gate raises 42501 and the
commit refuses. **The only way to force it through would be to set the claims GUC to the owner's
subject myself, which is FORGING THE ACTOR** — forbidden by Prompt 22C, by the Prompt 22B
authorization decision, and by §10's rule that an audit actor column cannot be forged. Written
approval in a prompt is not an authenticated Admin session, and the approved design exists precisely
so the decision names the human who made it in one. **NOTHING WAS WRITTEN**: `import_mapping_decisions`
is 0 with an all-time `n_tup_ins` of **0**, audit_logs still 1, staging `n_tup_upd` still 402,
stations 157, units 188, aliases 0, canonical assets 0, 1,104 rows still `needs_station_mapping`.
The owner runs the commit from an authenticated active-Admin session with the three approved
arguments; the exact call is recorded in §14.

**FUTURE UNIT WORKLOAD RECOMPUTED (read-only) — 240 / 38 / 3 exactly**, and every Category-B Station
has exactly TWO Units. **A BLOCKING FINDING**: the 281 rows carry **NO Unit-bearing field of any
kind** — 0 rows with a unit name, number or raw unit column, 0 with a non-NULL `unit_id`. The only
context present is `location_raw` and `compressor_context_raw` (191 rows) and `area_type_raw` (64
detectors), and §4 states in terms that `Location` is an equipment-KIND hint and "is not evidence of
Unit membership". **So Category A is NOT resolvable by its own shape** — "the Station has exactly one
Unit" is a fact about the HIERARCHY, not about the ASSET, and treating it as proof is the
distribution rule §4 permanently forbids; 240 rows is exactly the size at which that shortcut
tempts. Category C cannot proceed at all (the Station has no Units, and D7 forbids inventing one).
**A Stage B UNIT batch therefore has no source to run on**: Unit mapping needs NEW evidence naming
the Unit per asset, not a cleverer rule over what is already staged.*

***PROMPT 22C.1 — THE ADMIN EXECUTION SURFACE IS BUILT AND DEPLOYED; THE BATCH IS STILL NOT
COMMITTED** — see `docs/stage-b-station-mapping.md` §16. **NO MIGRATION WAS REQUIRED.** Prompt 22C
stopped because the commit derives its actor from a verified Clerk subject and an operator
connection has none; this adds the authenticated Admin's own path to that one approved batch, at
`/admin/station-batch`.

**THE EXISTING AUTH PATH WAS VERIFIED BEFORE ANY CODE WAS WRITTEN, and no second one was created.**
`src/lib/supabase/client.ts` holds ONE client built from the project URL and the PUBLISHABLE key,
with an `accessToken` callback reading the current Clerk session token per request; Supabase
verifies it against the trusted Clerk issuer and PostgreSQL reads the claims through
`cng_jwt_sub()` -> `cng_current_app_user_id()` -> `cng_require_admin()`. No JWT template, no
service-role key, no hand-built claims. Proved against production READ-ONLY by assuming the owner's
real subject under role `authenticated` in a deliberately aborted transaction: the app user
resolved, `cng_is_admin()` was true, and the deployed preview returned 69 groups / 281 rows with the
approved fingerprints. **The commit was NOT invoked.**

**THE GUARD IS THE LIVE SERVER, NOT THE CONSTANTS.** The approved run, both fingerprints and 69/281
are constants only in the sense that the LIVE preview is compared against them; the control unlocks
solely when the server currently reports all of them, and any drift renders
`APPROVED BATCH HAS CHANGED — EXECUTION BLOCKED` listing EVERY mismatch rather than the first.
**ACCIDENTAL EXECUTION IS IMPOSSIBLE**: opening the dialog sends nothing, and the final action stays
disabled until `CONFIRM 281 STATION MAPPINGS` is typed exactly. **RUNNING IT TWICE IS IMPOSSIBLE**:
the control locks on submit, and **an uncertain result is NEVER a retry** — a thrown request or an
error carrying no PostgreSQL SQLSTATE is classified `uncertain`, which offers only a READ-ONLY
outcome check reading committed (281 decided) / not executed (0 decided, fingerprint unchanged) /
**UNEXPECTED for anything between**, which stops rather than guessing. Replay protection after a
refresh is **SERVER-DERIVED, never localStorage**: once the batch runs every candidate row carries
an active decision, the preview reports it, and the completed state is what any Admin in any
browser sees.

**ONE WORDING PRECISION**: the batch writes a DECISION and does not rewrite
`import_staging_rows.mapping_status` — `v_admin_staged_mapping_queue` deliberately keeps
`staged_mapping_status` (raw evidence) and `confirmed_mapping_status` (from the decision) apart — so
the screen says **"Confirmed mapping status: Needs Unit Mapping"** rather than implying the staged
column moved.

**AUTHORIZATION IS UNCHANGED**: `cng_require_admin()` untouched, no RLS or grant altered, no
service-role key or password in the browser, and the RPC carries exactly four parameters. Tests
assert the payload contains no `actor`, `decided_by`, `clerk`, `sub`, `app_user`, `service_role`,
`password` or `secret` under any key, and that no table is written directly. The section is hidden
from non-Admins for UX only; the database remains the authority.

**Frontend tests 584 -> 617** (33 new); schema 240 and authorization 624 unchanged, correctly, as no
SQL changed. Full gate exit 0. **PRODUCTION IS UNCHANGED**: 47 migrations, `import_mapping_decisions`
**0** with an all-time `n_tup_ins` of **0**, 1,104 rows still `needs_station_mapping`, canonical
assets 0, aliases 0, stations 157, units 188, and the live preview still reports 69/281 with
fingerprint `a014745d...` and 0 rows decided. **The batch awaits the owner's click.***

***PROMPT 22C.2 — THE STAGE B PREVIEW TIMEOUT IS DIAGNOSED AND FIXED; MIGRATION 0048 IS NOT
DEPLOYED** — see `docs/stage-b-station-mapping.md` §17. `/admin/station-batch` failed in production
with *canceling statement due to statement timeout* while loading the READ-ONLY preview; the commit
was never reached and nothing was written.

**IT WAS RLS EVALUATION COUNT, NOT DATA VOLUME**, and it was MEASURED, not guessed: the same call,
same data, same moment, took **225 ms as an operator connection (RLS bypassed)** and **39,371 ms as
the owner's authenticated session (RLS enforced)** — 175x over 7,163 rows and 157 Stations. Under
RLS: staged scan 894 ms, `stations` 27 ms, decisions 0.8 ms, **candidates 9,737 ms**, groups
9,892 ms, preview 39,371 ms. **TWO COMPOUNDING STRUCTURAL CAUSES**: `candidates` asked "how many
Stations in this Region carry this name?" as a CORRELATED SUBQUERY for every one of the 1,104 staged
rows, each re-scanning `stations` THROUGH ITS RLS POLICY (1,104 x ~9 ms = the 9.7 s); and `preview`
then evaluated that FOUR times — its own CTE plus three calls to `groups` (4 x 9.7 s = the 39 s).

**THE OBVIOUS REWRITE WAS FOUR TIMES SLOWER AND IS RECORDED AS REJECTED**: joining once and counting
with a window function measured **37,444 ms**, worse than the original, because the planner still
re-scanned the RLS-protected table and added window overhead. Measured alternatives, same session,
same RLS, all returning the same 281 rows: current 9,795 ms · window rewrite 37,444 ms · materialize
`stations` only 1,321 ms · **materialize `stations` AND the staged set 303 ms**.

**MIGRATION 0048** marks both CTEs `AS MATERIALIZED` so RLS is evaluated ONCE PER TABLE rather than
once per staged row, and has `preview` hold its candidate and group sets in materialized CTEs so
`groups` runs once instead of three times. **THE EXACT NEW BODY, MEASURED IN PRODUCTION UNDER REAL
RLS, READ-ONLY: 307.6 ms, 281 rows, fingerprint `a014745d...e0cbe769` — BYTE-FOR-BYTE THE APPROVED
ONE**, so the owner's approval does NOT lapse and no re-approval is needed. Semantics were proved
unchanged locally at full scale by snapshotting the old output and diffing: **0 rows differ** in
candidates, groups and preview, row ORDER identical, 281 both ways, local fingerprint identical
before and after.

**RLS IS EVALUATED FEWER TIMES, NEVER BYPASSED**: the read paths stay SECURITY INVOKER and STABLE
(STAGEBPERF-6 asserts both from the catalog), no grant, policy, RLS setting or `cng_require_admin()`
was touched, and the commit function is unmodified. **RAISING `statement_timeout` WAS DELIBERATELY
NOT THE FIX** — a preview over 7,163 rows has no business taking 39 s, and a longer timeout would
have left the per-row re-evaluation to bite a larger dataset later; no timeout was changed.

**ONE LIMIT STATED PLAINLY**: the slowness does NOT reproduce locally (~235 ms before AND after
0048, because local RLS is cheap), so the PERFORMANCE evidence is production-measured and the
CORRECTNESS evidence is local — neither is presented as the other. Schema assertions 240 -> 247;
frontend 617 and authorization 624 unchanged. **NOT DEPLOYED**: production stays at 47 migrations,
`import_mapping_decisions` 0 with an all-time `n_tup_ins` of 0, 1,104 rows still
`needs_station_mapping`, canonical assets 0, aliases 0, stations 157, units 188. Migrations 0044,
0045, 0046 and 0047 are byte-identical.*

***PROMPT 22C.3 — MIGRATION 0048 IS DEPLOYED AND THE LIVE ADMIN PREVIEW IS VERIFIED; NO MAPPING
DECISION WAS COMMITTED** — see `docs/stage-b-station-mapping.md` §18. Production went **47 -> 48**,
recorded once (`20260917110814 stage_b_preview_performance`), file SHA-256 `9e3d2c3e...` recomputed
immediately before transmission and matching the approved commit 52d38ec byte for byte.

**DEPLOYMENT PROVED BYTE-EXACT.** The two function bodies were hashed FROM THE APPROVED FILE BEFORE
deploying and compared to `pg_proc.prosrc` after: `cng_stage_b_station_candidates`
`ddf963f6...` and `cng_stage_b_station_preview` `5780e33f...`, both identical.
**EXACTLY TWO FUNCTIONS CHANGED** — the commit (`b040117a...`), `cng_require_admin` (`ff29bdea...`),
`cng_normalize_name` (`3c4d8a93...`) and `cng_stage_b_station_groups` (`4cd1e91e...`) are bit-for-bit
unchanged. The statement inventory was MACHINE-SCANNED: two `CREATE OR REPLACE FUNCTION`, two
`COMMENT`, and ZERO ALTER/DROP/GRANT/REVOKE/INSERT/UPDATE/DELETE/TRUNCATE/POLICY/INDEX; the words
`grant`, `statement_timeout`, `cng_require_admin` and `cng_stage_b_station_commit` occur ONLY on
`--` comment lines. No migration-time DML.

**SECURITY UNCHANGED**: both replaced functions stay SECURITY INVOKER and STABLE (so they cannot
write and RLS still bounds them), `search_path` pinned, EXECUTE authenticated with **anon 0**,
`import_mapping_decisions` still 0 browser write grants and 0 write policies, 0 tables without RLS.
**NO TIMEOUT WAS RAISED** — `authenticated` still carries Supabase's stock 8s and `anon` 3s, and the
verification was run UNDER that 8s budget rather than a relaxed one.

**LIVE AUTHENTICATED PREVIEW: ~670 ms**, read-only as the owner's Admin identity in a deliberately
aborted transaction. Six samples 664.0-712.1 ms, ONE distinct fingerprint across all runs —
`a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769`, EXACTLY the approved value, so
the approval does not lapse. Against the pre-fix 39,371 ms that is **~59x faster, at ~8% of the
8s budget**. **ONE NUMBER IS REPORTED HIGHER THAN 22C.2 PREDICTED**: 22C.2 measured the candidate
body inline at 307.6 ms, while the full deployed preview including its `groups` call measures
~670 ms — the honest figure is ~670 ms and the flattering one is not restated. Semantics exact:
69 groups / 281 rows, 69 deterministic, 0 owner review, 0 already decided, families 100/91/64/26,
**78 raw spellings = 69 normalized identities**.

**THE PREVIEW WROTE NOTHING**: decisions `n_tup_ins` 0 -> 0 (it counts even rolled-back tuples, so
none was ever attempted), audit 1 -> 1, staging `n_tup_upd` 402 -> 402. **Reading as the owner is
NOT forging an actor** — 22C refused the claims GUC because it would have attributed a WRITTEN
decision; the preview takes no actor, writes no row and attributes nothing. The commit was NOT
invoked in any execution context.

**GATE exit 0**: frontend 617, schema 247, authorization 624, 48 migrations from zero, upgrade
replay 47 -> 48. **PRODUCTION AFTER**: 48 migrations, regions 6, stations 157, units 188,
`import_mapping_decisions` 0 (all-time `n_tup_ins` 0), 1,104 rows still `needs_station_mapping`,
canonical assets 0, aliases 0/0, 0 tables without RLS. Migrations 0044-0047 byte-identical.
**The batch awaits the owner's click at `/admin/station-batch`.***

***PROMPT 22D — THE STAGE B STATION MAPPING IS COMMITTED AND INDEPENDENTLY VERIFIED IN
PRODUCTION** — see `docs/stage-b-station-mapping.md` §19. The owner executed the approved batch
from the production Admin UI; this was a READ-ONLY reconciliation that created and modified nothing.

**281 DECISIONS, ALL WELL-FORMED**: all active, `confirmed_station_id` set on 281,
**`confirmed_unit_id` NULL on 281/281**, previous/resulting status correct on every row, a
64-char `reviewed_source_row_hash` with **0 mismatches**, **0 duplicates, 0 orphans, 0
wrong-Region**, 69 distinct Station targets, 1 import run. **ATTRIBUTION IS REAL**: one
`decided_by` resolving to the ACTIVE `admin`, 0 unresolved, and a SINGLE identical `decided_at`
across all 281 — the signature of one transaction.

**STAGED AND CONFIRMED STATUS ARE CORRECTLY SEPARATE**: 281 rows read
`staged_mapping_status = needs_station_mapping` (raw evidence, deliberately unmoved) with
`confirmed_mapping_status = needs_unit_mapping`; 823 carry no decision; 0 stale.

**THE 823 FIREWALL HOLDS EXACTLY** — Upper 266, Alex 199, Canal 171, Delta 99, West 82, East 6,
with **0 decisions among them**, and the 5 other-Region-only rows still unmapped. The 281 are
Delta 199 + West 82. **FAMILIES EXACT** 100/91/64/26. **HIERARCHY UNCHANGED** (6 / 157 / 188,
East 42/56, West 40/58, Delta 75/74, Canal-Alex-Upper 0/0), aliases 0/0. **ALL EIGHT CANONICAL
ASSET TABLES STILL 0** — Station confirmation is a STAGING decision and imports nothing.
**AUDIT**: 282 = 1 pre-existing + 281 new, 1 actor, 1 timestamp, 0 orphans, 0 decisions without
an audit row, 0 actor mismatches.

**REPLAY IS BLOCKED BY THREE INDEPENDENT SERVER-SIDE CONDITIONS**, proved without re-invoking the
commit: the preview fingerprint has CHANGED `a014745d... -> 01390ef4...` because
`has_active_decision` is folded in per row, so the approved constant now FAILS CLOSED — the
content-bound approval working as designed; `imd_one_active_per_source_row` makes a duplicate
active decision impossible at the DATABASE level; and the UI reads 281 >= 281 and renders
`already_executed`, server-derived so it survives any refresh in any browser.

**UNIT WORKLOAD 240 / 38 / 3 EXACTLY** (63 / 5 / 1 Stations; every Category-B Station has exactly
two Units). **THE UNIT EVIDENCE QUESTION IS ANSWERED FROM A FULL KEY CENSUS** of both `normalized`
and `source_raw`: **PROVEN UNIT EVIDENCE = NONE, zero rows in all three categories** — `unit_id` is
non-empty on 0, and NO key named unit/unit name/unit number/unit code/job number exists anywhere in
the 281 rows. **CONTEXT ONLY**: `Location` (191 rows) whose complete value set is exactly
`Recovery | Storage` — an equipment KIND §4 says is not Unit evidence; `Type OF Compressor` (191, 9
values) — a MODEL naming no instance; `area_type_raw` (64) classifying the AREA. **AND A TRAP
CLOSED**: 140 raw names end in a digit, but so do all 140 canonical Stations they matched, because
candidacy required normalized-name equality — the digit is part of the STATION identity committed at
Stage A, not a D2 Unit index, and only 8 of the 73 Units under these Stations carry a digit-suffixed
name. **Category A is NOT resolvable by its own shape**: "the Station has exactly one Unit" is a
fact about the HIERARCHY, not the ASSET, and assigning those 240 on that basis is the distribution
rule §4 permanently forbids. **A Stage B UNIT batch still has no source to run on** — confirmed now
against the real committed decisions rather than a simulation.

**PRODUCTION**: 48 migrations, regions 6, stations 157, units 188, `import_mapping_decisions` 281,
confirmed Station mappings 281, remaining without Station confirmation 823, canonical assets 0,
aliases 0.*

***PROMPT 23A — THE CANONICAL ASSET IMPORT IS BUILT AND LOCALLY VERIFIED; MIGRATION 0049 IS NOT
DEPLOYED AND NO ASSET WAS IMPORTED** — see `docs/asset-import.md`. **One additive migration, 0049**,
adding three functions and NO table, column or enum.

**UNIT_ID NULL IS LEGAL IN ALL FOUR FAMILIES, AND THE SCHEMA IS WHY**: each carries
`<table>_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL)` — that
status REQUIRES a NULL Unit, so Station-level existence with an unknown Unit is the shape these
tables were designed for, not a workaround. **No family is blocked and nothing was relaxed**
(ASSETIMP-14: `station_id` still NOT NULL in all four).

**UNIT IS STRUCTURALLY UNWRITABLE, NOT MERELY DEFAULTED**: the four INSERT statements name no
`unit_id` column at all, re-derived from `pg_proc.prosrc` (ASSETIMP-1), and ASSETIMP-4 PROVES the
detector fires on a violating column list so a pass means something.

**NOTHING IS DEDUPLICATED, BECAUSE THE SCHEMA DELIBERATELY HAS NO IDENTITY**: no family has a
UNIQUE on `serial_number` (Prompt 14, principle 16). 199 of 281 rows carry a serial and **8 groups
covering 16 rows repeat within a family (6 at the same Station)** — they are FLAGGED as duplicate
candidates and imported as DISTINCT assets, because merging them would destroy real equipment on
the strength of a repeated string. Replay is guarded PER SOURCE ROW using lineage that already
existed: `committed_entity_id`/`committed_at`/`committed_entity_kind`, whose allowlist ALREADY
contained all four asset kinds (ASSETIMP-12).

**A REAL FINDING — 279 ELIGIBLE, NOT 281.** 2 of the 64 detector rows carry
`presence = 'not_installed'` with the pipeline's own `creates_detector_record = false`: they are
evidence an area has NO detector, and creating a `gas_detectors` row would manufacture a device the
source explicitly denies. They are classified `E_BLOCKED_BY_TARGET`, stay staging-only, and belong
to `gas_detector_presence` — a different table with a different contract that this prompt did not
authorize building. Production read-only eligibility: **279 ready (sv 100, rt 91, gd 62, hoses 26)
across 68 Stations, 2 blocked, 0 needs-review, 0 already imported, 0 rows with a Unit**.

**DELIBERATELY NOT MAPPED**: `area_type` (lives on `gas_detector_presence`, classifies the AREA,
Prompt 13), `location_raw` (equipment kind), and `model`/`model_raw` — **0 of 281 rows carry any
model value**, so the columns stay NULL rather than being filled from the compressor TYPE, which is
a different thing. Dates map only at `exact_date` precision (the CHECK makes any other value store
NULL and keep its raw text); measured precisions are only `exact_date` and `unknown`, and pressures
are never ranges.

**SECURITY FOLLOWS THE EXISTING ARCHITECTURE**: `service_role` ONLY, matching Stage A, because a
canonical asset carries NO `created_by` — there is no actor to attribute, so no browser path is
opened. SECURITY DEFINER with pinned `search_path`, read paths deliberately not definer, no dynamic
SQL, four literal targets. The region-scoped INSERT policies are the OPERATIONAL path for an
engineer adding one asset by hand and were not touched.

**LINEAGE links on `source_row_key`, not payload equality** — two rows sharing a serial and every
other value would otherwise be indistinguishable and could link to the wrong asset. Stage A's 402
structural rows are disjoint and keep their `station`/`unit` kinds.

**ALL 20 REQUIRED DESTRUCTIVE TESTS PASS LOCALLY** at full scale through the real functions, and
TWO were stronger than intended: a wrong Station and a Unit-bearing decision could not even be
CONSTRUCTED, because `imd_station_region_fk` and `imd_status_shape_ck` already forbid them. Atomicity
proved by rollback (5 created in-transaction -> 0 assets, 0 linked, 0 audit). Replay refused with
both the old and the current fingerprint.

**NO PRODUCTION PREVIEW FINGERPRINT IS CLAIMED**: the 22B rule is that it must come from the
DEPLOYED function, and 0049 is not deployed, so the counts are reproduced read-only and the
fingerprint is left for deployment. Gate exit 0: frontend 617, schema **247 -> 261**, authorization
624, 49 migrations from zero, upgrade replay 48 -> 49. Migrations 0044-0048 byte-identical.
**PRODUCTION UNCHANGED**: 48 migrations, 157 Stations, 188 Units, 281 decisions, canonical assets
**0**, aliases 0, asset lineage rows 0, asset-import functions deployed **0**.*

***PROMPT 23B — MIGRATION 0049 IS DEPLOYED AND THE CANONICAL ASSET PREVIEW IS VERIFIED IN
PRODUCTION; NO ASSET WAS IMPORTED** — see `docs/asset-import.md` §11. Production went **48 -> 49**,
recorded once (`20260917120310 asset_import`), SHA-256 `7fad16bb...` matching approved commit
55e7e18 byte for byte.

**BYTE-EXACT DEPLOYMENT**: all three bodies hashed FROM THE APPROVED FILE BEFORE deploying and
matched after — proposal `7a6394c2...` (5772), preview `9da86e43...` (1829), commit `e759bebb...`
(11594). **THE MIGRATION EXECUTES NO DML**: machine-scanned with function bodies stripped, it runs
3 CREATE FUNCTION, 3 COMMENT, 3 GRANT, 6 REVOKE and ZERO INSERT/UPDATE/DELETE/ALTER/DROP/POLICY/
INDEX; all six DML statements sit INSIDE function bodies, and the file contains no write of any
kind to `stations`, `units`, aliases, `import_mapping_decisions` or `gas_detector_presence`.

**SECURITY AS APPROVED**: commit SECURITY DEFINER, both read paths INVOKER and STABLE, search_path
pinned on all three, EXECUTE **anon 0 / authenticated 0 / service_role 3** — no browser
canonical-import path. No dynamic SQL. **Nothing else moved**: normalizer, Stage A commit, all
four Stage B functions and `cng_require_admin` are bit-identical; Stage A browser EXECUTE 0;
70 policies, 0 tables without RLS; the four operational asset INSERT policies still
`WITH CHECK (cng_can_write_region(region_id))`, untouched.

**DEPLOYED PREVIEW FINGERPRINT `b0d594482b40c21099ba39cb3b9a827cb5dee46cd557fcb676055054bd91104b`**
— obtained from the DEPLOYED function, per the 22B rule. **279 eligible (100 / 91 / 62 / 26),
2 excluded, 0 needs-review, 0 already imported, 16 duplicate-serial warnings, 68 Stations, 0 rows
with a Unit, 0 canonical assets now.** Every 23A expectation reconciles exactly.

**VERIFIED AGAINST THE DEPLOYED PROPOSAL**: 0 payloads carry any unit key; 279/279 take their
Station from the ACTIVE decision with `confirmed_unit_id IS NULL` and a matching
`reviewed_source_row_hash`; 0 Region mismatches; **0 candidates from the remaining 823** and
**0 from the two not-installed rows**; 199 serial-present / 82 no-serial across all 281; and the
279 eligible rows carry **279 distinct source keys and 279 distinct hashes** — one asset per
source row, nothing deduplicated.

**THE TWO EXCLUSIONS, BY PROVENANCE** (no identity text retyped): `Gas detector.xlsx / Sheet1`
rows **75** and **109**, hashes `78a9207b...` and `ea8e6c27...`, both `presence = not_installed`
with `creates_detector_record = false`. Raw Station name RETAINED (lengths 6 and 15) and
`source_raw` intact, so nothing was discarded from provenance; both stay staging-only and
**no `gas_detector_presence` write occurred** (that table still holds 0 rows).

**FIELD/NULL PRESERVATION — 17 checks, 0 violations**: no fabricated serial; **0 model keys
anywhere** and none filled from compressor type; `location` and `area_type` appear in no payload;
a date exists ONLY at `exact_date` precision (three separate rules, 0 violations each); raw date
text retained on non-exact rows; pressure units/values faithful with 0 ranges flattened; no
fabricated notes or status.

**LINEAGE AND WRITE-FREE**: guards present on all 279; Stage A's 402 `station`/`unit` lineage rows
untouched with **0 overlap**; asset lineage rows 0. Counters IDENTICAL either side of the preview —
assets 0, `audit_logs` 282 with 0 `service_role:asset_import` rows, decisions 281, Unit mappings 0,
aliases 0. (Non-zero all-time `n_tup_ins` on storage_vessels/hoses/presence are historical
ROLLED-BACK probe tuples from Prompts 12-14; live counts are 0 and the preview delta is zero.)

**Gate exit 0**: frontend 617, schema 261, authorization 624, 49 from zero, upgrade replay 48 -> 49.
0044-0048 byte-identical. **`cng_asset_import_commit` was NOT invoked in any execution context.**
Production: 49 migrations, 6 / 157 / 188, 281 decisions, 0 Unit mappings, canonical assets 0,
aliases 0, asset lineage 0.*

***PROMPT 23C — THE 279 CANONICAL ASSETS ARE COMMITTED TO PRODUCTION** — see
`docs/asset-import.md` §12. `cng_asset_import_commit` was invoked **EXACTLY ONCE** after a final
pre-commit guard matched every approved value. **The canonical asset tables are no longer empty:
storage_vessels 100, recovery_tanks 91, gas_detectors 62, hoses 26 = 279.**

**COMMIT RETURN**: `assets_created 279`, 100/91/62/26, `rows_linked 279`, fingerprint
`b0d59448...bd91104b`. Unambiguous; no retry needed and none made.

**EVERY RECONCILIATION IS ZERO-DEFECT**: `station_id` NULL 0, **`unit_id` NOT NULL 0**, wrong
status 0, wrong Station vs the active decision 0, wrong Region 0, asset without lineage 0, **279
distinct source keys across 279 assets** and 0 source rows used twice. Compressors, dispensers and
both SRV families remain **0** — no other family was touched.

**LINEAGE**: 279 links with a SINGLE `committed_at` (one transaction), 0 orphans, 0 wrong entity
kinds, 0 wrong pointers, 0 hash mismatches, 0 links without a decision. **Stage A's 402 structural
rows are untouched** and keep their own timestamp.

**THE TWO DETECTOR EXCLUSIONS HELD**: 0 rows with `creates_detector_record = false` were imported
anywhere, their evidence is intact, and `gas_detector_presence` still holds **0** rows.

**DATA PRESERVATION — 17 CHECKS, 0 VIOLATIONS**: no fabricated serial; **0 model values anywhere**
and none from compressor type; no fabricated notes or status; a date exists ONLY at `exact_date`
precision and equals its source value; raw date text retained; pressure unit/value unchanged with
no range flattened; **no `location`, `area_type` or unit key in any stored asset**.
**DUPLICATES WERE NOT MERGED**: 199 assets with a serial, 80 without (82 staged minus the 2
excluded — exact), and the 8 repeated-serial groups produced **16 DISTINCT assets** (principle 16).

**AUDIT**: exactly 1 row, `import_executed` on the import run, `actor_label =
service_role:asset_import` with **`actor_id` NULL** — correct and deliberate, because these tables
carry no `created_by` contract and no human attribution was invented; fingerprint recorded,
0 orphans, timestamp equal to the lineage `committed_at`.

**REPLAY IS BLOCKED BY THREE INDEPENDENT BARRIERS**, proved read-only: the fingerprint moved
`b0d59448... -> e3b0c442...` (the empty-string hash, since no eligible row remains), so the
approved constant fails closed; Gate 5 refuses with `eligible_rows = 0`; and all 279 rows are now
`D_ALREADY_IMPORTED` with `committed_entity_id` set.

**FIREWALLS**: the remaining **823** Station-unconfirmed rows untouched with 0 imported; decisions
281 with **0 Unit mappings**; aliases 0; hierarchy unchanged (6 / 157 / 188 — East 42/56, West
40/58, Delta 75/74, Canal/Alex/Upper 0/0); 0 tables without RLS. **Gate exit 0**: frontend 617,
schema 261, authorization 624, 49 from zero, upgrade replay 48 -> 49. Migrations 0044-0049
byte-identical.*

### Prompt-21 import blockers (must be resolved before the production import)

| Asset | Staged as `needs_station_mapping` | Why it cannot be stored | Found in |
| --- | --- | --- | --- |
| Storage Vessels | 433 | `storage_vessels.station_id` is NOT NULL | Prompt 12 |
| Recovery Tanks | 403 | `recovery_tanks.station_id` is NOT NULL | Prompt 12 |
| Gas Detectors | 219 | `gas_detectors.station_id` is NOT NULL | Prompt 13 |
| Hoses | 49 | `hoses.station_id` is NOT NULL | Prompt 14 |
| **Total** | **1,104** | | |

Do not resolve these by relaxing a constraint, by fabricating a Station mapping, or by dropping
the staged rows. **Prompt 19A built the resolution PATH** — an admin confirms the Station on the
staging row before the import, and Prompt 21 commits with the confirmed ids
(`docs/preimport-mapping.md`). The rows themselves are still unresolved, and working them is
operational work, not a migration.

*Vessels Management (Prompt 12) is built: `/manage/vessels/storage` and
`/manage/vessels/recovery` — see `docs/vessels-management.md`. **No new migration.** Storage
Vessels and Recovery Tanks stay distinct entities. A Recovery Tank cannot own an SRV (no
`recovery_tank_id`, not in `srv_parent_kind`) and none is shown. NOTE: `needs_station_mapping`
is unreachable for vessels because `station_id` is NOT NULL — Prompt 6 staged 433 Storage and
403 Recovery rows in that state, which the canonical tables cannot hold; Prompt 21 must resolve
this. Mapping mutation remains deferred for the same attribution reason as Prompt 11.*

*The Unit workspace (Prompt 10) is built: `/units/:unitId` with routed Overview, Compressor,
Recovery Tank, Dispensers, Storage, Gas Detectors, Hoses and SRVs sections — see
`docs/unit-workspace.md`. It required **no new migration**; every source already existed. The Unit
SRV visibility rule is enforced in `v_unit_srvs` in SQL, not in the UI. Global SRV Management and
the warehouse experience are Prompt 11.*

- Documentation-first: architecture and data-mapping decisions are recorded in `docs/`
  before implementation.
- Migrations are additive and versioned; no destructive migration without explicit approval.
- RLS is enabled on every table from the first migration — no table ships without a policy.
- No secrets in the repository. `.env.example` documents keys with empty values.
- Dynamic computations (Days Left, compliance status) live in SQL views or the query layer,
  never as stale stored columns.

## 7a. Verification Integrity Gate (permanent, from Prompt 11 onward)

Two verification-process defects in Prompts 9-10 caused a PASS to be reported over a
broken build and a silently shrunken test suite. Both had the same root cause: **success
was inferred from filtered text instead of taken from the process.**

These rules are permanent and apply to every future prompt.

1. **The exit code is the only authoritative PASS/FAIL signal.** Never infer success by
   grepping stdout or stderr.
2. Run the real build and the complete test suite **directly**, and require exit code `0`.
3. Never mask a failure with `grep`, a pipe that replaces the exit code, `|| true`,
   command substitution, or any other construct that discards the status.
4. Record the exact discovered / passed / failed counts wherever the tool reports them.
5. **Compare every count against the previous accepted baseline.** A decrease is not
   automatically a failure, but it must be investigated and explicitly justified before
   reporting PASS - a deleted, renamed, skipped or undiscovered test file must never
   silently reduce coverage.
6. Report the actual final command results, never inferred success.

### Accepted baselines

| Prompt | Frontend tests | Schema assertions | Authorization assertions |
| --- | --- | --- | --- |
| 10 | 217 | 72 | 134 |
| 11 | 245 | 72 | 149 |
| 12 | 270 | 72 | 166 |
| 13 | 316 | 82 | 197 |
| 14 | 356 | 102 | 222 |
| 15 | 389 | 129 | 265 |
| 15.1 | 399 | 146 | 277 |
| 15.2 | 399 | 146 | 277 |
| 15.2B | 405 | 146 | 277 |
| 15.3 | 416 | 146 | 302 |
| 15.3C | 418 | 146 | 302 |
| 16-18 | 431 | 146 | 311 |
| 18A | 433 | 146 | 332 |
| 19 | 451 | 146 | 406 |
| 19A | 486 | 146 | 479 |
| 19B | 499 | 146 | 508 |
| 20 | 547 | 146 | 560 |
| 20A | 557 | 146 | 591 |
| 20B | 565 | 146 | 591 |
| 20F | 580 | 152 | 601 |
| 21B | 584 | 166 | 601 |
| 21C | 584 | 203 | 611 |
| 22A | 584 | 240 | 624 |
| 22C.1 | 617 | 240 | 624 |
| 22C.2 | 617 | 247 | 624 |
| 22C.3 | 617 | 247 | 624 |
| 22D | 617 | 247 | 624 |
| 23A | 617 | 261 | 624 |
| 23B | 617 | 261 | 624 |
| 23C | 617 | 261 | 624 |

Update this table when a prompt is accepted, so the next one has a baseline to compare
against.

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

---

## 11. UI/UX rules (durable, from Prompt 7 onward)

*Status: the foundation is built and browser-verified (Prompt 7) — see `docs/ui-foundation.md`;
the operational dashboard is built on it (Prompt 8) — see `docs/dashboard.md`; the hierarchy
browser is built on both (Prompt 9) — see `docs/regions-stations.md`; the Unit workspace is built
on all three (Prompt 10) — see `docs/unit-workspace.md`; Global SRV Management (Prompt 11) — see
`docs/srv-management.md`; Vessels Management (Prompt 12) — see `docs/vessels-management.md`.
The **Cargas brand system**
was established during Prompt 9 and is authoritative — see §11.6 and `docs/ui-foundation.md` §13.
It records which ui-ux-pro-max recommendations were accepted and which were rejected for
conflicting with the rules below.*

### 11.1 Always use the UI/UX review skill

**From Prompt 7 onward, proactively invoke the UI/UX design-review skill for every user-facing
interface task** — new screens, changed screens, component work, layout, tables, forms, filters,
and any styling decision. Do not wait to be asked.

The skill is **`ui-ux-pro-max`** ("UI/UX Pro Max") — a searchable design-intelligence database
covering styles, colour palettes, font pairings, product types, UX guidelines, icons, motion and
chart types across 22 stacks. Invoke it by name via the Skill tool.

It is **vendored into this repository** at `.claude/skills/ui-ux-pro-max/`, together with the
supporting design skills (`ui-styling`, `design-system`, `design`, `brand`) and the engineering
skills the project uses (`security-audit`, `playwright-cli`, the `speckit-*` suite). They travel
with the project and work in every future session on any machine, rather than depending on a
particular account's synced skill set. See `.claude/skills/README.md`.

`ui-ux-critique-pro` is also vendored as a **secondary**, narrower review pass over existing
frontend code. It complements `ui-ux-pro-max`; it does not replace it.

> **Use its rules selectively.** `ui-ux-pro-max` is a general design database and carries motion
> presets, decorative styles and consumer/marketing patterns that §11.3 and §11.4 explicitly rule
> out for this product. Take its structure, spacing, contrast, accessibility, typography and
> data-display guidance; ignore the parts that would make this look like a marketing site.

### 11.2 It is a design and review system — not a mandate to redesign

The skill critiques and improves the *presentation* of what already exists. It has no authority
over the product.

**These remain authoritative and are never changed to satisfy a design suggestion:**

- the equipment hierarchy (§4) and the SRV parentage rules
- authorization, roles and RLS (§10)
- the data principles (§6), including NULL handling and the no-fabrication rule
- database constraints, the mapping lifecycle, and the data-quality workflow (§9)
- the import pipeline's behaviour (`docs/import-pipeline.md`)

A design review never invents a business requirement, never adds a field the schema does not
carry, never displays a value the source did not prove, and never renders a placeholder where the
data is NULL. If a design suggestion conflicts with any rule above, the rule wins and the
suggestion is discarded.

### 11.3 What this product must look like

**Professional industrial engineering software for CNG Station Inspection, Calibration and Asset
Management.** It is a working tool for engineers who spend their day in it, not a product page.

| Required | Meaning in practice |
| --- | --- |
| Industrial/engineering visual language | sober, utilitarian, built for repeated daily use |
| Information-dense but readable | show more rows and more columns, not fewer; density is a feature |
| Excellent technical tables | sortable, alignable, scannable; numerals aligned; units visible; wide tables scroll rather than wrap |
| Strong filtering and search | filtering by Region, Station, Unit, status, due window and mapping status is primary UI, not an afterthought |
| Clear asset hierarchy | `Region → Station → Unit → Equipment → SRV` legible at a glance and never flattened |
| Clear status states | inspection/calibration state, due windows and mapping status readable without decoding a legend |
| Restrained colour | colour carries meaning — status, severity, overdue — and is never decorative |
| Strong accessibility and contrast | meets contrast requirements in light and dark; colour is never the only signal |
| Responsive desktop / tablet / mobile | desktop is the primary target; tablet and mobile must remain usable, not merely not-broken |
| Excellent Arabic support | Arabic Station, Unit and equipment names render correctly at every size, including mixed Arabic/Latin/numeric strings and RTL text inside LTR layout. Never truncate an Arabic name into ambiguity |
| Consistent loading, empty, error and permission states | every one handled explicitly, every time — an empty result is stated, never left blank |
| Keyboard-friendly | tab order, focus visibility, and keyboard paths through tables and filters wherever practical |

### 11.4 What it must never look like

Not a generic AI SaaS dashboard. Not a marketing landing page. Not a consumer mobile app. Not a
template filled with decorative cards.

Specifically avoid: excessive gradients · excessive rounded cards · oversized KPI cards ·
unnecessary animation · decorative visual noise · glassmorphism · whitespace that reduces data
density · AI-generated-dashboard aesthetics.

### 11.6 The Cargas brand system is authoritative

*Established in Prompt 9. Applies to EVERY future UI prompt.*

This application is for **Cargas / NGV**. Its identity is derived from the official
supplied logo, `public/brand/logo.png`, and is recorded in full in
`docs/ui-foundation.md` §13. Future UI work **preserves** that system; it does not
re-derive, re-sample or restyle it.

**The official colours, sampled from the logo — never from memory:**

| Token | Value | Use |
| --- | --- | --- |
| `--brand` | `#089B4B` Cargas green | identity fills ONLY — never behind text |
| `--brand-strong` | `#07833F` derived | everything involving text: links, buttons, active nav, focus ring |
| `--brand-deep` | `#004221` (from the logo) | deep brand ground |
| `--brand-yellow` | `#FFEB00` NGV yellow | fills on DARK grounds and the logo only — 1.17:1 on the working ground |

Rules that must not be broken:

1. **Brand colour and semantic status colour are separate namespaces.** Cargas green
   never means "healthy"; NGV yellow never means "warning". `--status-*` states
   compliance; `--brand-*` marks identity, navigation and selection. A minimum 20°
   hue separation between `--brand` and `--status-ok` is asserted by
   `scripts/verify-brand.mjs`, which must pass.
2. **Never use a raw brand colour where it fails contrast.** `#089B4B` is 3.62:1 with
   white and `#FFEB00` is 1.17:1 on the working ground. Use the documented accessible
   derivatives. Appearing in the logo is not a licence to fail WCAG.
3. **Never redraw, recolour, distort, stretch, regenerate or re-crop the logo.** Use
   the existing assets: `logo-trimmed.png` (full lockup) and `mark.png` (the leaf
   device, already cut from the lockup at its own transparent seam). Preserve the
   aspect ratio; size from height with `w-auto`.
4. **The logo is never a decorative watermark.** Once per surface, as identification.
5. **Restraint is the design.** Brand colour touches the chrome in three places only:
   the logo, the 2px green/yellow keyline, and the active/focus state. The working
   surfaces stay neutral so the data leads. This must not drift into a green/yellow
   marketing aesthetic (§11.4 still governs).
6. **Application identity is fixed:** the browser title is
   `CNG Station Management | Cargas`, and the favicon is the leaf device derived from
   the official logo. `public/brand/favicon.svg` is a non-Cargas placeholder and must
   not be wired up. No invented slogans or taglines.

### 11.5 Displaying unknown data

This is where a design system most often violates the data principles, so it is stated here too:

- a NULL field is shown as genuinely empty, or with a neutral marker that reads as "not recorded"
- **never** `N/A`, `Unknown`, `-`, `0`, or an invented placeholder standing in for missing data
- a `year_only` date shows its year and is never rendered as a full calendar date
- an unresolved mapping is labelled as unresolved; it is never hidden to make a screen look complete
- a record with NULL fields is a complete record with unknown attributes — never badged
  "incomplete" and never visually degraded
