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

## 17. Delivery, Resend and Web Push — architecture built, sending DEFERRED

In-app alerts are **primary**: an alert is persisted whether or not anything is ever delivered.

### Resend account isolation — verified

The rule is **one account, separate credentials**:

```
Resend account
├── Coding System            → its own API key, its own project secrets   [OFF LIMITS]
└── CNG Station Management   → its OWN dedicated API key and secrets
```

**Verified for this prompt:** the Coding System repository was never read, no credential was
copied, rotated or referenced, and a repository-wide search finds **no Resend key, no VAPID key
and no cross-project configuration dependency** anywhere in this project. The only occurrence of
"Coding System" in non-documentation source is the comment in `supabase/config.toml` forbidding
it.

Sharing the *account* is permitted. Sharing *project credentials* is not.

### External configuration required from the user (§6)

Live email and push are **blocked on configuration that does not exist**, and nothing was
guessed. Each item is server-only and must be entered directly in the Supabase dashboard for
project `cng-station-management` (`ypkggegquetvpsflkaxg`) under
**Edge Functions → Secrets** — never in source, `.env`, `VITE_*`, GitHub or chat.

| Secret | Type | Where to create it | Notes |
| --- | --- | --- | --- |
| `RESEND_API_KEY` | Resend API key | Resend dashboard → API Keys → **new key** | Suggested label `cng-station-management-production`. **Do not reuse the Coding System key.** |
| `CNG_ALERT_FROM_EMAIL` | email address | your verified Resend domain | A CNG-specific sender is preferred. **Not guessed here** — no domain is invented. |
| `CNG_ALERT_INVOKE_SECRET` | random string | generate fresh | Authenticates manual `generate-alerts` calls. |
| `VAPID_PRIVATE_KEY` | VAPID private key | generate a **new** pair for this project | Never copied from anywhere. |
| `VITE_VAPID_PUBLIC_KEY` | VAPID public key | same pair | Browser-safe; already declared in `.env.example`. |

A verified domain **may** be shared at the account level; that is not the same as sharing API
credentials. If a dedicated CNG subdomain is wanted, that is deployment configuration and does
not block anything here.

### Recipient policy — deferred, deliberately

Authorization to *read* an alert is not consent to receive external mail. `notification_preferences`
exists and is user-owned with RLS, so recipients would be users holding an explicit enabled
preference row — an opt-in model. No such rows exist, and **no user is silently subscribed**. No
mail is sent to "every app_user".

### Testing

No real notification is sent by any automated test. Delivery outcomes are fixtures; the provider
boundary is never called.

### Retry

Generation retry and delivery retry are different things. Generation retry is idempotent.
Delivery retry targets the **same** alert — `notif_delivery_uq (alert_id, app_user_id, channel)`
means a retry updates rather than duplicates (`AL19`), and a failed send **never** creates a new
alert.

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
| Live email delivery | needs `RESEND_API_KEY` + a verified CNG sender (§17) | user configuration |
| Live Web Push | needs this project's own VAPID pair (§17) | user configuration |
| External recipient automation | no recipient policy exists; nobody is subscribed silently | a later prompt |
| Bulk read / acknowledge | would need server-side re-authorization of every id and partial-failure reporting | a later prompt |
| Resolve / suppress actions | `state` is now server-only; these need their own audited function | a later prompt |
| Mapping mutation | unchanged — still forgeable elsewhere | a later prompt |
| The 1,104 staged blocker rows | staging only; generate no alerts | Prompt 21 |
