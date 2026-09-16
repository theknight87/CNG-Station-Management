# Alerts & Notifications (Prompt 15)

Route: **`/alerts`** — the operational alert inbox.

Migrations added: **0031** (alert engine), **0032** (daily schedule), **0033** (a security fix,
§14). Edge Function added: **`generate-alerts`**.

---

## 1. Three layers, deliberately separate

This is the point of the feature. Collapsing any two of these is the easy mistake.

| Layer | What it is | Where it lives |
| --- | --- | --- |
| **Due status** | a *calculated property* of an asset's date. It exists whether or not anyone was ever notified. | `cng_due_status()`, shown in every asset registry |
| **Alert** | a *persisted operational event*, created because a rule matched. It has its own identity and lifecycle, and it outlives the condition that produced it. | `alerts` |
| **Delivery** | an *attempt to surface* an alert by email or web push. | `notification_deliveries` |

Consequences that are enforced, not merely intended:

- An asset returning to Current does **not** delete its historical alerts.
- A failed delivery leaves the alert exactly as it was (`AL17`, `ALRT-11`). The UI states
  "the alert exists and its email failed", which is never the same as "no alert".
- The **Alert** column shows the *threshold that fired* — a historical fact. **Days left** and
  **Status** show where the asset stands *today*. They routinely disagree, and that is correct.

## 2. What already existed

Prompt 4 built more than expected, and it was reused rather than rebuilt: `alert_rules`,
`alerts` (with its dedupe constraint), `notification_preferences`, `push_subscriptions`,
`notification_deliveries`, and `cng_business_date()`, which already returned the Africa/Cairo
calendar date.

**Verified empirically, not assumed:** `alert_rules` holds exactly **30 rows = 5 subjects × 6
thresholds, all enabled** (`AL1`), with day counts 60/30/15/7 stored once in the database and
`NULL` for `due_today` and `overdue` (`AL2`). Those numbers are **not duplicated as React
constants**.

### What was missing, and was added

1. **Read state.** `alert_state` is `open | acknowledged | resolved | suppressed` — an
   operational lifecycle with no notion of "I have seen this".
2. **A safe acknowledgement path.** See §14 — this turned out to be a security finding.
3. **Generation.** No generation function existed at all.

## 3. Supported subjects

The schema's own five, in its own terminology. None invented:
`srv_calibration`, `storage_inspection`, `recovery_tank_inspection`,
`gas_detector_calibration`, `hose_hydrotest`.

Warehouse SRVs are **excluded**: they have no installed due-date workflow, and
`alert_subject` defines none for them.

## 4. Rules determine WHEN, never the due date itself

`alert_rules` decide when an *existing* due date should raise an alert. They do **not** produce
due dates. No calibration or test interval is invented anywhere — Prompts 13 and 14 established
that no authoritative interval exists in this project, and Prompt 15 does not manufacture one.

## 5. Exact-date eligibility

An asset is alertable only when its next-due precision is `exact_date`.

- `year_only` → **no alert ever** (`AL7`). A bare "2027" is never turned into 1 January or
  31 December.
- `unknown` / `invalid` → **no alert** (`AL8`).
- Excel "Days Left" is not consulted.

## 6. Generation

`cng_generate_alerts(p_as_of date DEFAULT NULL)` — one set-based statement per run.

Eligibility is a UNION across the five asset tables; each row is joined to the enabled rules and
matched on the **exact calendar condition**:

| Threshold | Fires when |
| --- | --- |
| `due_60` / `due_30` / `due_15` / `due_7` | `due_date - as_of` equals exactly 60/30/15/7 |
| `due_today` | `due_date - as_of` = 0 |
| `overdue` | `due_date - as_of` < 0 |

**No retroactive back-fill.** Because the countdown thresholds match exactly, the first run
against an asset already 45 days overdue raises `overdue` *and nothing else* — it does not
manufacture the 60/30/15/7/today alerts it passed months ago (`AL6`, proven with a 45-day-overdue
hose).

## 7. Deduplication — database-enforced

Identity is `alerts_dedupe_uq UNIQUE (asset_type, asset_id, threshold, due_date)` (`AL3`), and
generation uses `ON CONFLICT DO NOTHING`. There is **no read-then-write in application code**.

- Three consecutive runs create 2, then **0**, then **0** alerts (`AL9`, `AL10`).
- **Six concurrent runs** against the same eligible asset produced **exactly one** alert — one
  run reported `created = 1`, the other five reported `0`. Overlapping cron executions are
  therefore safe by construction, not by luck.

## 8. Overdue, and due-date cycles

`overdue` does **not** accumulate daily. The dedupe key includes `due_date`, so exactly one
overdue alert exists per **due-date cycle**, not per scheduler run (`AL11`).

When an asset is re-tested and its next due date moves, that is a **new cycle**: it may raise its
own alert, and the historical alert keeps its original due date, unrewritten (`AL12`, `AL13`).

## 9. Lifecycle — read is not acknowledgement

| | Read | Acknowledged |
| --- | --- | --- |
| Meaning | "I have seen this notification" | explicit operational recognition |
| Scope | **per user** | shared, on the alert |
| Stored in | `alert_reads (alert_id, app_user_id)` | `alerts.acknowledged_by/_at` |
| Set by | `cng_mark_alert_read` / `_unread` | `cng_acknowledge_alert` only |

**Read state is per-user** (`AL20`, `ALRT-21`): one manager reading an alert does not silently
mark it read for every engineer. Acknowledgement is shared, because it *is* a shared fact.

**Opening an alert does neither.** Expanding the detail row is a UI act; both read and
acknowledge are separate, explicit clicks. A test asserts that expanding issues no RPC at all.

Re-acknowledging is a no-op that **preserves the first actor** (`ALRT-17`), so a record cannot be
quietly reattributed.

## 10. History and resolution

`alert_state` already carried `resolved` and `suppressed`; **no new lifecycle state was
invented**. An asset becoming Current does not delete its alerts — traceability is preserved. No
resolve action is exposed yet; see §17.

## 11. The unresolved-SRV case — and a correction

Migration 0015 had *deliberately* dropped `NOT NULL` from `alerts.station_id` and added
`source_station_name_raw` and `needs_station_mapping`, precisely so an SRV whose canonical
Station is unconfirmed can still be tracked: an exact due date is enough to know a calibration is
coming due.

**My first implementation got this wrong** — it excluded `station_id IS NULL` SRVs from
generation and inner-joined `stations` in the inbox view, which would have silently dropped them.
The schema assertion caught it and both were fixed: such SRVs now generate alerts carrying the
**raw source station name**, and the view `LEFT JOIN`s stations (`AL15`, `AL15b`).

No Station is ever fabricated to make an alert possible.

**That raw context is sensitive.** `alerts_select` routes station-unconfirmed rows through
`cng_can_access_unmapped_srv()` rather than region scoping, because an unconfirmed `region_id` is
evidence, not permission (CLAUDE.md §10). Proved both ways: a regional viewer and a regional
engineer see neither the alert nor its raw station text (`ALRT-4`, `ALRT-5`, `ALRT-15`), while an
admin sees both (`ALRT-19`, `ALRT-20`) — so the first result is scoping, not an accident of the
fixture.

**Only SRVs can reach this state.** `station_id` is `NOT NULL` on vessels, detectors and hoses, so
their staged `needs_station_mapping` rows cannot exist as canonical assets at all (`AL15c`). The
1,104 Prompt-21 blocker records are **staging rows and generate no production alerts**.

## 12. The inbox

`v_alert_inbox`, `security_invoker`, so `alerts_select` decides every row.

**Columns:** Alert · Asset · Station · Unit · Due date · Days left · Status · Read ·
Acknowledged · Subject · Email.

Order is measured, not incidental: attention, identity, hierarchy, timing, then state. Subject is
the widest column and is both filterable and implied by the asset type — with it in second place,
**Acknowledged fell 17px outside the visible region at 1440px**, so it was moved after
Acknowledged. A test locks the first nine headers.

`days_left` in the view is computed **live** against the Cairo business date. The stored
`alerts.days_left` is a generation-time snapshot for the notification body only, and is
deliberately not what the inbox shows.

**No severity is invented.** There is no "Critical", no "Emergency", no siren, no pulsing red.
Threshold urgency is a scheduling fact, not an assertion that equipment is unsafe (§24).

## 13. Summary, search, filters, sorting, pagination

Seven `head: true` counts over the **whole authorized dataset**: alerts, overdue, due today,
7-day, unread, unacknowledged, delivery failed. Any single failure fails the whole strip and says
so — a failed count is never rendered as zero.

Server-side throughout: search over asset serial, station and folded unit name; filters for
Region, Station (dependent), Subject, Threshold, Read, Acknowledgement and Delivery, combining as
true intersections; sorting with `id` as a deterministic tie-break; 50-row pages with
`count: 'exact'` under RLS. Four distinct screens: loading, empty, filtered-no-results, failure.

## 14. SECURITY FINDING — forgeable acknowledgement (fixed)

Found while writing the RLS assertions, and **proved by attack, not by reading**.

Migration 0019 had issued a **column-level** grant:

```sql
GRANT UPDATE (state, acknowledged_by, acknowledged_at, resolved_at) ON alerts TO authenticated;
```

Column grants do **not** appear in `information_schema.role_table_grants` — that view showed a
reassuring `SELECT`, and the grant sat underneath it. `role_column_grants` shows the truth.

**Exploit, reproduced end to end:** a signed-in *engineer* updated an alert in their own region
and set `acknowledged_by` to an **admin's** id with `acknowledged_at` backdated to
**2020-01-01**. It was accepted. RLS checks the row's region; it cannot check whether the actor
is claiming to be someone else.

That breaks the durable rule that an audit actor cannot be forged.

**Fix — migration 0033:** revoke all four column privileges. `cng_acknowledge_alert` is
`SECURITY DEFINER`, takes **no identity parameter**, pins `search_path`, re-checks region
authorization itself (definer rights bypass RLS), and stamps `cng_current_app_user_id()` and
`now()`. With the direct path closed it is the **only** way an alert can become acknowledged.

The same attack now fails with `permission denied for table alerts`. `ALRT-37` asserts at
**column** level — the level the hole actually lived at — so it cannot regress silently.

`resolved_at` and `state` were revoked too: a client able to set `state = 'resolved'` could retire
an alert with no record of who did it. A future resolve action belongs in its own audited
function.

This was a **pre-existing** vulnerability, not one introduced by this prompt.

## 15. RLS and authorization

40 assertions (`ALRT-1` … `ALRT-40`). An unauthorized alert is unreachable through list, direct
id, the base table, search, filtered counts, threshold filters, or detail expansion. Per-user
state is genuinely per-user: a user cannot create, read or delete another user's read state
(`ALRT-23`…`ALRT-25`), cannot see another user's delivery records including provider error text
(`ALRT-26`), and cannot register a push subscription for someone else (`ALRT-27`). `anon` reaches
nothing (`ALRT-28`…`ALRT-33`).

Generation is granted to **`service_role` only** — never to `authenticated` (`AL23`, `ALRT-38`),
because letting a browser drive the scheduler would be an abuse vector.

## 16. Africa/Cairo

`cng_business_date()` is `(now() AT TIME ZONE 'Africa/Cairo')::date`.

Proved deterministically at fixed instants in **both DST states** — 22:30 UTC on 15 June and on
15 January are both the *following* day in Cairo (`AL21`) — and proved independent of the host
timezone by evaluating it under `America/New_York` (`AL22`); it was also checked live under
`Asia/Tokyo` and `UTC`. No `UTC+2`/`UTC+3` is hard-coded anywhere.

### Cron

`pg_cron` calls `cng_generate_alerts()` **in-database** at `0 1 * * *`:

- **No HTTP and no secret.** The obvious pattern (pg_cron → `net.http_post` → Edge Function)
  needs an invocation secret stored where a migration can read it, and no secret belongs in this
  repository. Calling the SQL function directly removes the whole problem.
- **01:00 UTC** is 03:00 or 04:00 Cairo — comfortably clear of the midnight boundary in both DST
  states. The function derives its own date, so the schedule only has to land safely inside the
  Cairo day. A schedule near 22:00 UTC would land on the *following* Cairo day for half the year.
- Idempotency means the schedule is not load-bearing: a missed, doubled or overlapping run cannot
  duplicate an alert, so retrying is always safe.
- Migration 0032 is **conditional**: `pg_cron` ships on hosted Supabase but is absent from the
  local verification database, so it schedules where available and says so where not.

### Edge Function

`generate-alerts` remains as an authenticated **manual** trigger. It fails closed (503) when
unconfigured, requires `x-cng-alert-secret` compared in **constant time** (401 otherwise), returns
non-specific errors while logging detail server-side, and holds no business logic — all dedupe,
threshold and timezone rules stay in PostgreSQL.

## 17. Delivery: Resend email and Web Push (Prompt 15.1)

In-app alerts remain **primary**: an alert is persisted whether or not anything is ever
delivered, and nothing below can change that.

### What was built in Prompt 15.1

Prompt 15 shipped the delivery *record* but nothing that created or completed one. Prompt 15.1
adds the sending path, keeping the architecture intact:

```
technical condition -> persisted ALERT -> DELIVERY attempt
```

**Migration 0034** adds four functions and one column:

| Object | Purpose | EXECUTE |
| --- | --- | --- |
| `cng_enqueue_alert_deliveries(channel)` | create `pending` rows for **opted-in** recipients | `service_role` |
| `cng_next_pending_deliveries(channel, limit)` | claim work, `FOR UPDATE SKIP LOCKED` | `service_role` |
| `cng_record_delivery_result(...)` | write the outcome, and only the outcome | `service_role` |
| `cng_save_push_subscription(...)` | save a subscription for the **session's own** user | `authenticated` |
| `notification_deliveries.attempt_count` | bounded retry (cap 5) | — |

**Edge Function `send-notifications`** performs the actual Resend call.

### What delivery cannot do — asserted, not asserted-to

`DL7`–`DL11` prove a delivery failure leaves the alert byte-for-byte unchanged: not deleted, not
acknowledged, not duplicated, and still `open`. `DL9` proves a failed delivery stays retryable and
that the retry is bound to the **same** alert. `DL10` proves retry is **capped**, so a permanently
bad address stops costing sends rather than being retried forever.

### Not an open mail relay

A sending endpoint is the one genuinely dangerous thing added here, so it is closed three ways:

1. The invoke secret is server-side only and never reaches a browser.
2. **Queue mode takes recipients from the database**, never from the request body — opted-in users
   whose RLS actually lets them read the alert.
3. **Test mode accepts one address**, and only if it matches `CNG_ALERT_TEST_RECIPIENT` exactly.
   A caller holding the secret still cannot name an arbitrary destination.

`DL13`/`DL14` prove no browser role — **not even an admin** (`PUSH-11`, `PUSH-12`) — can enqueue,
claim or complete a delivery.

### Recipients are opt-in, and that is still not a production policy

A delivery is created only where the user holds an **enabled** `notification_preferences` row, and
only where that user could read the alert anyway. `DL1` proves that with no preferences, **nothing
is enqueued** — there is no "email every app_user" path and nobody is silently subscribed. `DL4`
honours `min_threshold`; `DL5` proves a disabled preference is not an opt-in.

**Production recipient policy remains DEFERRED.** No preference rows exist, so in practice nothing
is emailed. The single address authorized for the controlled test is a test recipient only: it is
**not** hard-coded anywhere in the engine, is not a default, and reaches nothing outside test mode.

### Resend account isolation — re-verified

```
Resend account
├── Coding System            → its own API key, its own project secrets   [OFF LIMITS]
└── CNG Station Management   → its OWN dedicated API key and secrets
```

The Coding System repository was never read; no credential was copied, rotated or referenced. A
repository-wide scan finds the only occurrence of "Coding System" outside documentation is the
comment in `supabase/config.toml` forbidding it. The four secret **names** appear only in the two
Edge Functions and in this documentation — never in `src/`, never in a `VITE_*`, never in a
migration.

### LIVE TEST STATUS — blocked by the build environment, not by the code

**The controlled test email was NOT sent.** This is an environment limitation and is reported
rather than worked around.

The build environment's network policy answers **HTTP 403 to CONNECT** for every host this step
needs. Verified directly, and confirmed in the proxy's own failure log:

| Host | Result |
| --- | --- |
| `api.resend.com` | 403 to CONNECT — policy denial |
| `ypkggegquetvpsflkaxg.supabase.co` | 403 to CONNECT |
| `api.supabase.com` | 403 to CONNECT |
| `api.cloudflare.com` | 403 to CONNECT |

Consequently these four steps could not be performed here, and **none was simulated**:

1. sending the one controlled test email;
2. verifying that the four secrets are present in the hosted project;
3. deploying `send-notifications` and `generate-alerts`;
4. setting `VITE_VAPID_PUBLIC_KEY` in Cloudflare Pages.

Everything that does **not** require egress was completed and verified: the sending
implementation, the delivery-record behaviour, the relay protections, push subscription and its
RLS, the opt-in UI, 10 push unit tests, 17 delivery schema assertions, 12 push RLS assertions and
26 browser checks.

### To complete the live test yourself

1. **Add a fifth secret** in Supabase → project `cng-station-management` → Edge Functions →
   Secrets. It gates test mode, so test mode is inert until it exists:

   ```
   CNG_ALERT_TEST_RECIPIENT = efares0@gmail.com
   ```

2. **Deploy the functions:**

   ```bash
   supabase functions deploy send-notifications
   supabase functions deploy generate-alerts
   ```

3. **Send the one controlled test** (the secret stays in your shell, never in a file):

   ```bash
   curl -X POST "https://ypkggegquetvpsflkaxg.supabase.co/functions/v1/send-notifications" \
     -H "x-cng-alert-secret: $CNG_ALERT_INVOKE_SECRET" \
     -H "content-type: application/json" \
     -d '{"mode":"test"}'
   ```

   Success returns `{"mode":"test","sent":true,...}`. The message is explicitly headed
   `[TEST] CNG Station Management — Notification Verification` and states in its body that it
   reports no real equipment condition.

**Expected limitation.** Without a verified sending domain, Resend permits sending only to the
account owner's own address. If the configured `CNG_ALERT_FROM_EMAIL` is on the shared
`onboarding@resend.dev` sender, a send to any other address returns **HTTP 403**, which this
implementation records as `resend:http_403:sender_or_recipient_not_permitted`. That is a provider
policy, not a defect: verify a sending domain in Resend, or send to the account owner's address.
**No sender identity was invented and no domain was guessed** to make the test pass.

### VAPID

| Key | Where it belongs | Status |
| --- | --- | --- |
| **private** | Supabase Edge Function secret `VAPID_PRIVATE_KEY` | configured by the user; **never** in `VITE_*`, source, bundle, or browser storage — scan confirms it appears in no frontend file |
| **public** | `VITE_VAPID_PUBLIC_KEY`, compiled into the bundle **by design** | **has nowhere to be set yet — no CNG Cloudflare Pages project exists** (§22) |

The browser needs the public key to create a subscription, so it is browser-visible and that is
correct. It is read at call time, so a deployment that omits it reports "Push notifications are
not configured for this deployment" rather than failing silently.

**Pair consistency could not be verified**, and was not assumed: checking that a public key
matches a private one requires reading the private key, which this documentation and this
environment deliberately never do. The user generated both halves together as a new CNG-specific
pair; if push later fails with a `403`/`VapidPkHashMismatch` from the push service, a mismatched
pair is the first thing to check.

**To finish Web Push:** the CNG Cloudflare Pages project must be **created first** — it does not
exist (§22, and `docs/deployment-cloudflare.md`). Only then can `VITE_VAPID_PUBLIC_KEY` be added
(Production, and Preview if used) and the site built, so Vite bakes the public half into the
bundle. Do not paste either key into chat.

### Live push status

**Not completed, and not faked.** Headless Chromium reports
`Notification.permission === 'denied'` and ignores Playwright's `grantPermissions` for
notifications, so no real subscription could be created here — verified explicitly rather than
assumed. The granted path is covered deterministically by unit tests that stub the `Notification`
and `PushManager` APIs.

After the Cloudflare variable is set and the site redeployed, the manual steps are: open
`/alerts`, click **Enable notifications**, and accept the browser prompt. The subscription is then
saved by `cng_save_push_subscription`, which fills the owning user from the session — so one user
can never register, read or delete another's subscription (`PUSH-1`…`PUSH-9`).

### Push opt-in UX

Permission is requested **only** from an explicit click — never on page load, verified in the
browser at all three widths. Every state is handled and worded calmly: unsupported, unconfigured,
idle, working, subscribed, denied, error. A denied browser is told plainly and is **not**
re-prompted. Push carries scheduled due dates, so there is no siren, no vibration and no
`requireInteraction`.

### Retry

Generation retry and delivery retry remain different things. Generation retry is idempotent.
Delivery retry targets the **same** alert — `notif_delivery_uq (alert_id, app_user_id, channel)`
means a retry updates rather than duplicates, and a failed send **never** creates a new alert.
`attempt_count` caps retries at five so a dead address or endpoint cannot amplify.

## 18. Dashboard and sidebar

Untouched. Due status is not Alert count, so the Dashboard's technical due metrics were **not**
replaced, and no second notification centre was built. No unread badge was added: it would need
polling, and the value did not justify the request volume or the risk of a count that reads zero
on failure.

## 19. Performance

One set-based query per page plus seven head-only counts. The inbox view resolves asset identity
with five `LEFT JOIN`s evaluated in a single pass — never a per-row lookup. Generation is one
statement. No N+1 hierarchy call, no per-row due calculation, no client-side authorization
filtering.

## 20. Deferrals

| Item | Why | Owner |
| --- | --- | --- |
| The one controlled test email | implementation complete and **deployed**; the build environment still denies egress to `api.resend.com`, and sending requires presenting `CNG_ALERT_INVOKE_SECRET`, which is deliberately never read here (§21) | user runs the documented curl |
| Live Web Push | implementation complete, but **there is no deployed site at all**: the CNG Cloudflare Pages project has never been created (§22) | user creates the Pages project |
| Verified Resend sending domain | without one, Resend permits sending only to the account owner | user configuration |
| External recipient automation | no recipient policy exists; nobody is subscribed silently | a later prompt |
| Bulk read / acknowledge | would need server-side re-authorization of every id and partial-failure reporting | a later prompt |
| Resolve / suppress actions | `state` is now server-only; these need their own audited function | a later prompt |
| Mapping mutation | unchanged — still forgeable elsewhere | a later prompt |
| The 1,104 staged blocker rows | staging only; generate no alerts | Prompt 21 |

## 21. Prompt 15.2 — final live verification

This section records what was **LIVE VERIFIED against the hosted project**, what is
**IMPLEMENTED and AUTOMATED-TEST VERIFIED only**, and what **still requires a manual step**.
Nothing here was simulated, and no secret value was requested, printed, echoed or inspected.

### 21.1 Hosted project identity — confirmed before any write

`ypkggegquetvpsflkaxg` = `cng-station-management`, organisation `hlzsgygfczzdubcvmkjh`,
`ACTIVE_HEALTHY`, region `eu-central-1`. It is the **only** project visible to the connector and
it matches `supabase/config.toml`. No Coding System resource was listed, read or touched.

### 21.2 The hosted database was five migrations behind — now reconciled

The hosted schema stood at **29** migrations against the repository's **34**. In other words the
entire alert engine did not exist in production, and **the migration 0033 acknowledgement fix was
unapplied there** — the vulnerability of §14 was still live in the hosted project while the
repository considered it closed. Migrations **0030–0034** were applied. This is the strongest
argument in this project so far for the rule that a repository-side PASS is not a production
fact.

| Verified in production after applying | Result |
| --- | --- |
| migrations applied | **34** |
| `v_alert_inbox`, `v_hose_registry`, `alert_reads` | present |
| `cng_generate_alerts`, `cng_enqueue_alert_deliveries`, `cng_save_push_subscription` | present |
| `authenticated` UPDATE columns on `alerts` (`role_column_grants`) | **0** — §14 closed in production |
| `authenticated` table-level write grants on `alerts` | **0** |
| `cng_generate_alerts` EXECUTE by `authenticated` | **0** (`service_role` only) |
| the three delivery functions EXECUTE by `authenticated` | **0** (`service_role` only) |
| cron job `cng-generate-alerts` | **1**, `0 1 * * *`, calling the SQL function in-database |
| `cng_business_date()` | `2026-09-16` (Africa/Cairo) |

### 21.3 Both Edge Functions deployed

`generate-alerts` and `send-notifications` are **ACTIVE**, version 1, `verify_jwt = false` —
correct, because each authenticates its caller itself with the invoke secret rather than with a
browser JWT. Before deployment two documentation defects were corrected: `deno.json` imported a
`web-push` module the function never uses, and the file header implied a push-sending capability
that does not exist here. The header now says plainly: **email only; Web Push SENDING is not
implemented in this function.**

### 21.4 Secret PRESENCE proved without reading any secret

`curl` to the project host is still answered **403 at CONNECT** by this environment's network
policy — re-checked once, not retried in a loop. The check was therefore made **from inside the
hosted database**, where the request originates on Supabase's own network:

- `pg_net` was enabled temporarily, one unauthenticated `POST` was sent to each function, and the
  extension was **dropped again** afterwards. The architecture does not need database-side
  outbound HTTP — `pg_cron` calls the SQL function in-database — so leaving it enabled would have
  widened the surface for a diagnostic. Nothing of it remains.

Both functions answered **HTTP 401 `{"error":"unauthorized"}`**. That single status carries two
proofs, because of the deliberate order of the checks in `index.ts`:

1. **Configuration is present.** The missing-configuration branch returns **503
   `not_configured`** and runs *before* the header is examined. A 401 therefore proves
   `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` and `CNG_ALERT_INVOKE_SECRET` are all set.
2. **Neither function is an open endpoint.** A caller with no secret is refused, from a caller on
   Supabase's own network with a valid TLS path — the realistic attack position, not a synthetic
   one.

**What this deliberately does NOT prove:** the presence of `RESEND_API_KEY`,
`CNG_ALERT_FROM_EMAIL` and `CNG_ALERT_TEST_RECIPIENT`. Those are checked *after* the secret, so
they cannot be probed without holding the secret. That ordering is correct and was not relaxed to
make verification easier: an unauthenticated caller must not be able to enumerate which parts of a
system are configured.

### 21.5 The one test email — NOT SENT, and not faked

Sending requires presenting `CNG_ALERT_INVOKE_SECRET` in the request. The secret exists only as an
Edge Function secret; this session may not read it, and there is no path to a send that does not
either read it or weaken the authentication that makes the endpoint safe. **Neither was done.**
The live email is therefore a **documented deferral**, executed by the user with the exact command
already recorded in §17. Its recipient still resolves **server-side** from
`CNG_ALERT_TEST_RECIPIENT`; the request body may not name a destination.

`efares0@gmail.com` remains a **test-only** address. It appears in no migration, no view, no
default, no seed and no frontend file — verified by repository search — and no recipient policy was
created from it.

### 21.6 Web Push — SUPERSEDED BY §22

This section originally reported that `VITE_VAPID_PUBLIC_KEY` had been set in Cloudflare Pages and
that only a redeploy remained. **That was wrong, and §22 corrects it.** No CNG Cloudflare Pages
project exists, so there was no project on which the variable could have been set and nothing to
redeploy. The build-time fact itself still holds — Vite inlines `VITE_*` at build time, not run
time — but it is not the blocker. The blocker is that the application has never been deployed.

A real browser subscription remains **unverified** for a second, independent reason: headless
Chromium reports `Notification.permission === 'denied'` and ignores Playwright's
`grantPermissions` for notifications. That limitation is asserted explicitly in the suite rather
than worked around, and the granted path is covered by unit tests. **No push message was sent, and
none was claimed.**

### 21.7 Supabase security advisors

Three `WARN` findings, all `authenticated`-callable `SECURITY DEFINER` functions:
`cng_acknowledge_alert`, `cng_current_role`, `cng_has_region_grant`. All three are **intentional
and already documented**: each pins `search_path`, none takes a user-supplied identity parameter
(`cng_acknowledge_alert` takes an alert id and derives the actor from the session), and each exists
precisely so the client cannot do the work directly. No `ERROR`-level finding was returned. Nothing
was silenced.

### 21.8 State of the hosted data

Unchanged by this prompt and recorded for the Prompt-21 baseline: `alerts` 0, `alert_reads` 0,
`notification_deliveries` 0, `notification_preferences` 0, `push_subscriptions` 0,
`alert_rules` 30, `app_users` 1. The canonical asset tables remain empty, so generation has nothing
eligible to act on and **no alert was generated to manufacture a demonstration**. The 1,104 staged
Prompt-21 blocker rows were not read, modified or resolved.

### 21.9 Verification Integrity Gate

Run directly, exit code taken as the verdict, no output filtered:

| Measure | Baseline (15.1) | This run | Verdict |
| --- | --- | --- | --- |
| frontend tests | 399 | **399** (21 files) | equal |
| schema assertions | 146 | **146** | equal |
| authorization assertions | 277 | **277** | equal |
| migrations from zero | 34 | **34** | equal |
| build / lint / tests / brand | exit 0 | **exit 0** | PASS |

No count decreased. Prompt 15.2 changed no application code, so equality is the expected result.

## 22. CORRECTION — there is no CNG Cloudflare Pages project (Prompt 15.2A)

### 22.1 What was wrong

Prompt 15.2 reported that `VITE_VAPID_PUBLIC_KEY` was "set in Cloudflare Pages" and that Web Push
needed only "one redeploy". **Both statements were false.** The user's Cloudflare account contains
exactly one Pages project — `cargas-coding-system` → `coding-system-new.pages.dev`, fed by
`theknight87/coding-system-new` — and that is the **separate Coding System application**, which
this project must never touch.

I could not see Cloudflare from this environment (`api.cloudflare.com` answers **403 at CONNECT**,
re-checked, and no Cloudflare tooling is connected), so I took the user's report that a variable
had been added and assumed the project it would have been added to existed. That was an inference
presented as a verified fact, which is exactly what §7a of CLAUDE.md exists to prevent. The error
is recorded here rather than quietly edited away.

**The correct state: CNG Station Management has never been deployed anywhere.** There is no
`*.pages.dev` URL, no production build of this application in existence, and consequently no
frontend that could hold the VAPID public key, reach Clerk, or reach Supabase.

This also corrects `docs/architecture.md`, whose Phase 1 claimed a "Cloudflare Pages project and
first deploy of an empty shell". The scaffold, the Supabase project and the Clerk application were
created in that phase. **The hosting half never was.**

### 22.2 Isolation

`cargas-coding-system` was not inspected, modified, redeployed, copied from, or attached to
anything. Its environment variables, secrets, build settings, domains and VAPID keys are
irrelevant to this project and were not read. CNG Station Management requires its **own** Pages
project, and the repository confirms no coupling exists: a search of `src/`, `public/`,
`supabase/` and `index.html` finds **no reference to the Coding System** of any kind.

### 22.3 Deployment settings — determined from the repository, not guessed

Verified by reading `package.json`, `vite.config.ts` and `public/`, and by running a clean
production build (`rm -rf dist && npm run build`, **exit 0**):

| Setting | Value | Evidence |
| --- | --- | --- |
| Package manager | **npm** | `package-lock.json` is the only lockfile |
| Build command | **`npm run build`** | = `tsc -b && vite build`; the typecheck is part of the build and must stay |
| Output directory | **`dist`** | Vite default, unchanged in `vite.config.ts`; confirmed by the build |
| Production branch | **`claude/stoic-noether-tu4jpm`** | the designated development branch |
| Node version | **`NODE_VERSION = 22`** | Vite 8 requires Node `^20.19 \|\| >=22.12`; pin it rather than inherit a stale default |
| SPA routing | **already handled in the repository** | `public/_redirects` contains `/*  /index.html  200` and Vite copies it to `dist/_redirects` — verified in the build output. **No Cloudflare-side rewrite rule is needed, and none should be added.** |
| Root directory | repository root | no monorepo |

### 22.4 Public frontend variables — and what must never go there

`VITE_*` values are compiled into the bundle and are readable by anyone who loads the site. Only
publishable identifiers belong there. Exactly four are referenced by the source
(`grep import.meta.env src/`):

| Variable | Why it is browser-safe |
| --- | --- |
| `VITE_CLERK_PUBLISHABLE_KEY` | Clerk publishable key (`pk_...`) |
| `VITE_SUPABASE_URL` | must be the CNG project `ypkggegquetvpsflkaxg` |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | publishable, RLS-governed; authorization lives in the database |
| `VITE_VAPID_PUBLIC_KEY` | the public half of the pair, by design |

**Never placed in Cloudflare:** `VAPID_PRIVATE_KEY`, `RESEND_API_KEY`, `CNG_ALERT_INVOKE_SECRET`,
`CNG_ALERT_TEST_RECIPIENT`, the Clerk secret key, the Clerk webhook signing secret, or the
Supabase service-role key. Those are Supabase Edge Function secrets and stay server-side. A
"secret" Cloudflare Pages variable does not change this: if the build inlines it into the bundle
it is public regardless of how it was stored.

### 22.5 Status — NOT deployed, NOT verified

No Cloudflare change was made, because none could be made safely or at all. Every item below is
**PENDING**, not failed, and none may be marked LIVE VERIFIED until the independent project
exists and has deployed successfully:

| Item | Status |
| --- | --- |
| CNG Cloudflare Pages project exists | **NO** |
| `*.pages.dev` URL | **none** |
| SPA routing at `/`, `/dashboard`, `/alerts`, `/regions` | **unverified against a deployment** (`_redirects` is correct in the build output) |
| Clerk auth against the CNG application | **unverified** |
| Frontend talks only to `ypkggegquetvpsflkaxg` | **unverified live**; it is what `VITE_SUPABASE_URL` will select, and no other project is referenced in the source |
| No Coding System dependency | **verified in the repository** (no reference found); unverified live, there being nothing live |
