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
