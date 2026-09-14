# Authentication and Authorization

How identity, roles and region access work in the CNG Station Management System.

**Separation of concerns:** Clerk answers *who you are*. The database answers *what you may do*.
A frontend role check is a convenience for the user interface and is never a security control.

Related: [`database.md`](./database.md) · [`architecture.md`](./architecture.md) · [`../CLAUDE.md`](../CLAUDE.md)

---

> **Status: Prompt 5 COMPLETE — 2026-09-14.** Verified end to end in a real browser with a
> genuine Clerk-issued session token (§10). Remaining items in §13 are non-blocking and tracked.

## 1. Integration method — current, not deprecated

This project uses **Supabase Third-Party Auth with Clerk**, the current officially supported
integration. Supabase is configured to trust the Clerk issuer and verifies Clerk-signed **session
tokens** itself.

The older **Clerk "Supabase JWT template" approach is deprecated (1 April 2025) and is NOT used**.
Per Supabase's own documentation the deprecated path required sharing the project's JWT secret
with a third party, made secret rotation cause downtime, and added latency by minting a second
token per request. None of that applies here:

- no JWT template exists;
- this project's Supabase JWT secret is never shared with Clerk;
- the browser sends the ordinary Clerk session token, and Supabase verifies its signature against
  Clerk's published asymmetric keys.

### Token flow

```
Clerk sign-in
   └─> Clerk session token  (contains sub = Clerk user id, role = "authenticated")
        └─> supabase-js `accessToken` callback, evaluated per request
             └─> Supabase verifies the signature against the Clerk issuer
                  └─> claims exposed to Postgres as request.jwt.claims
                       └─> cng_jwt_sub() reads `sub`
                            └─> RLS policies decide every row
```

`accessToken` is a callback, so Clerk handles refresh and **no JWT is ever cached, copied between
components, or stored by this application**. The integration lives in one file:
`src/lib/supabase/client.ts`.

### The `role` claim

Supabase inspects the `role` claim to choose the Postgres role for the request. Clerk session
tokens must therefore carry `role: "authenticated"`. Clerk's *Connect with Supabase* setup adds
this automatically; if configured by hand it is added through Clerk's customized session token.

---

## 2. Configuration — non-secret identifiers only

| Item | Value |
| --- | --- |
| Clerk application | `CNG Station Management` — dedicated to this project |
| Clerk instance | **Development** |
| Clerk domain | `joint-lion-2271.clerk.accounts.dev` — non-secret; recorded in `supabase/config.toml` and registered in the Supabase dashboard (scheme stripped: Supabase expects the bare host) |
| Webhook endpoint | `https://ypkggegquetvpsflkaxg.supabase.co/functions/v1/clerk-user-sync` |
| Supabase organization | `CNG Station Management` (`hlzsgygfczzdubcvmkjh`) |
| Supabase project | `cng-station-management` (`ypkggegquetvpsflkaxg`) |
| Frontend package | `@clerk/clerk-react` |
| Client package | `@supabase/supabase-js` |

### Where each secret lives — by category, never by value

| Secret | Location | Reaches the browser? |
| --- | --- | --- |
| Clerk **publishable** key | `.env.local` as `VITE_CLERK_PUBLISHABLE_KEY` | yes — designed for it |
| Supabase URL + **publishable** key | `.env.local` as `VITE_SUPABASE_*` | yes — designed for it |
| Clerk **secret** key | Clerk dashboard; Edge Function secret if ever needed | **never** |
| Clerk **webhook signing secret** | Supabase Edge Function secret `CLERK_WEBHOOK_SIGNING_SECRET` | **never** |
| Supabase **service-role** key | Edge Function secret (injected by the platform) | **never** |
| Database password | Supabase dashboard only | **never** |
| VAPID private key | Edge Function secret (notification phase) | **never** |

No secret value appears in this repository, in any document, or in any log line.

---

## 3. Roles

| Role | Scope | Summary |
| --- | --- | --- |
| `admin` | company-wide | full administration: users, roles, region access, mapping, data quality, audit |
| `manager` | company-wide | all technical data and mapping in every region; data quality; **not** user or role administration |
| `engineer` | **granted regions only** | read and write technical data, and map assets, inside authorized regions |
| `viewer` | **granted regions only** | read-only. Viewer is *not* assumed to see all regions |

Roles live in `app_users.role` in the database, never in Clerk metadata. This is deliberate: a
Clerk profile edit must not be able to change database privileges.

### Onboarding — safe by default

A newly authenticated Clerk user is created by the webhook as `role = 'viewer'` **and
`is_active = false`**. `cng_current_role()` requires `is_active`, so a pending user resolves to a
NULL role and every authorization predicate fails. They can read exactly one thing: their own
`app_users` row, so the interface can say *"awaiting approval"* rather than showing an
unexplained empty application.

**Signing up grants nothing.** An administrator must activate the account and grant region access.

---

## 4. Region authorization

Six regions: East, West, Canal, Delta, Alex, Upper.

| Predicate | admin / manager | engineer | viewer |
| --- | --- | --- | --- |
| `cng_can_read_region(r)` | always | granted regions | granted regions |
| `cng_can_write_region(r)` | always | granted regions | never |
| `cng_can_map_region(r)` | always | granted regions **with `can_map`** | never |

Authorization follows the hierarchy rather than being duplicated per table. Every asset table
carries `region_id`, and that column is **pinned to its station's region by a composite foreign
key** (`*_station_region_fk`). It therefore cannot drift from the station it belongs to, which is
what makes it a trustworthy authorization key instead of a denormalized copy.

### Unresolved SRVs — raw source text is never an authorization boundary

An SRV in `needs_station_mapping` has `station_id IS NULL`. Its `region_id` came from the source
*Area* column and `source_station_name_raw` is untouched source text. **Neither is confirmed**, so
neither may decide access:

| Role | Access to an unmapped SRV |
| --- | --- |
| admin | yes |
| manager | yes (company-wide data quality) |
| engineer | **no** |
| viewer | **no** |

Because an engineer cannot *see* such a row, the mapping `UPDATE` can never match it — so mapping
cannot be used to **claim** an unresolved SRV into one's own region. This is enforced by policy
and proven by tests `ENG-14`, `ENG-15` (local) and `H-ENG9`, `H-ENG10` (hosted).

The same rule governs alerts: an unmapped-SRV alert is visible to admin and manager only, and an
engineer or viewer gains nothing from raw text that resembles a station in their region.

---

## 5. Authorization helper functions

| Function | Security | Purpose |
| --- | --- | --- |
| `cng_jwt_sub()` | INVOKER | Clerk user id from the verified token |
| `cng_current_role()` | **DEFINER** | caller's role, or NULL if unauthenticated/unknown/inactive |
| `cng_has_region_grant(region, require_map)` | **DEFINER** | does the caller hold this grant? |
| `cng_is_admin()`, `cng_is_manager_or_admin()` | INVOKER | role shorthands |
| `cng_can_read_region/write_region/map_region(region)` | INVOKER | the three region predicates |
| `cng_can_access_unmapped_srv()` | INVOKER | admin/manager only |

### Why two functions are `SECURITY DEFINER`

`app_users` and `user_region_access` are themselves RLS-protected. A policy that had to read
`app_users` to learn the caller's role would recurse infinitely. The two lookups are DEFINER
**purely to break that recursion**, and are constrained so they cannot be abused:

- they take **no identity parameter** — they always resolve the current `sub`, so nobody can ask
  *"what are Bob's permissions?"*;
- they return a single role or boolean, never another user's data;
- `search_path` is pinned to `pg_catalog, public`, preventing user-controlled object resolution;
- EXECUTE is granted to `authenticated` only — `anon` has none;
- both are `STABLE` and side-effect free.

Every other function in the schema is `SECURITY INVOKER`. All 19 pin `search_path`.

> **Known advisor finding, accepted with reasons.** Supabase's linter flags these two as
> SECURITY DEFINER functions callable by signed-in users via `/rest/v1/rpc/`. EXECUTE **cannot**
> be revoked: PostgreSQL checks function EXECUTE privilege while evaluating an RLS policy, so
> revoking it would break every policy (that is exactly how `anon` is denied — it fails with
> *permission denied for function cng_can_read_region*). Calling them directly tells a user only
> their own role or their own region grant, which they can already read from `app_users` and
> `user_region_access` under the self-select policies. **Hardening option for a later phase:**
> move the authorization helpers into a dedicated schema that is not exposed through the API;
> policies can reference any schema, so RPC exposure would disappear without weakening RLS.

---

## 6. GRANT strategy — closed by default

GRANT and RLS are independent layers. A request must satisfy **both**: the SQL privilege *and* a
policy that admits the row.

- **`anon` receives nothing.** No table privileges, no function EXECUTE. It holds schema `USAGE`
  only because `PUBLIC` does by default, and schema usage alone conveys no access to any object —
  verified by tests `H-ANON1`–`H-ANON6`, which show it cannot read stations, SRVs, users, audit,
  regions, or execute an authorization helper.
- **`authenticated` receives only what the application needs**, table by table.
- **No `DELETE` grant exists anywhere** except `user_region_access` (revoking a grant) and a
  user's own notification rows. Hard deletion of operational, import or audit data is impossible
  for every role, including admin.
- **Column-level grants** restrict partial updates: acknowledging an alert can write only
  `state, acknowledged_by, acknowledged_at, resolved_at`; an admin editing a user can write only
  `role, is_active, full_name, email`. `app_users.clerk_user_id` carries **no** UPDATE grant, so
  an identity can never be re-pointed — not even by an admin.
- **No INSERT on `app_users`**: accounts are created only by the server-side webhook, which is why
  a user cannot forge a row claiming another Clerk id.
- **Owner-confirmed rules are read-only through the API for everyone.** They change by migration,
  which keeps every change reviewed and permanently attributable in git.

---

## 7. RLS matrix

| Category | Tables | admin | manager | engineer | viewer | anon |
| --- | --- | --- | --- | --- | --- | --- |
| Hierarchy & equipment | stations, units, compressors, recovery_tanks, storage_vessels, dispensers, gas_detectors, gas_detector_presence, hoses | R/W all | R/W all | R/W granted regions | R granted regions | — |
| Installed SRVs (station confirmed) | installed_relief_valves | R/W/Map | R/W/Map | R/W/Map granted regions | R granted | — |
| Installed SRVs (`needs_station_mapping`) | installed_relief_valves | R/W/Map | R/W/Map | **none** | **none** | — |
| Warehouse SRVs (global) | warehouse_relief_valves | R + create + update | R + update | **read-only** | read-only | — |
| Aliases | station_aliases, unit_aliases | R/W + confirm | R/W + confirm | R/W propose in granted regions; **cannot confirm** | R granted | — |
| Reference | regions, alert_rules | R | R | R (own regions) | R (own regions) | — |
| Owner rules | owner_confirmed_* | **read-only** | read-only | read-only | read-only | — |
| Import / DQ | import_batches, import_issues | R + resolve | R + resolve | **none** | **none** | — |
| Alerts | alerts | R + ack | R + ack | R + ack, granted regions | R granted | — |
| Personal | notification_preferences, push_subscriptions | own rows only | own rows only | own rows only | own rows only | — |
| Authorization | app_users | R all + update role/active | own row | own row | own row | — |
| Authorization | user_region_access | full control | own rows (read) | own rows (read) | own rows (read) | — |
| Audit | audit_logs, asset_mapping_audit | R + append | R + append | append own only | append own only | — |

**DELETE is absent from every cell.** Mapping is available to admin/manager everywhere, to
engineers only inside granted regions with `can_map`, and to viewers never.

---

## 8. User lifecycle sync — the Clerk webhook

`supabase/functions/clerk-user-sync/` — **deployed** (status ACTIVE, version 1) at
`https://ypkggegquetvpsflkaxg.supabase.co/functions/v1/clerk-user-sync`.

`verify_jwt` is deliberately **false**: Clerk sends a Svix-signed request, not a Supabase JWT.
The function implements its own authentication and refuses everything that fails it.

It **fails closed with 503** while `CLERK_WEBHOOK_SIGNING_SECRET`, `SUPABASE_URL` or
`SUPABASE_SERVICE_ROLE_KEY` is absent, so the endpoint is live but inert — it can never process
an unsigned body — until the owner sets the signing secret and registers the endpoint in Clerk.

| Event | Effect |
| --- | --- |
| `user.created` | upsert with `ignoreDuplicates` → creates `role='viewer'`, `is_active=false`. Redelivery is a no-op and can never reset an approved account back to pending |
| `user.updated` | updates **only** `email` and `full_name` |
| `user.deleted` | sets `is_active = false`. **Never deletes** — audit and mapping history reference `app_users` with `ON DELETE RESTRICT`, and that history must outlive the account |

### Incident: the first live delivery failed with HTTP 500

Clerk delivered `user.created` (svix id `msg_3JKe...`) three times on
2026-09-14 ~19:31 UTC; every attempt returned 500 `{"error":"processing failed"}`.

Root cause, from the project's own logs: `POST /rest/v1/app_users` returned **403** and
PostgreSQL logged **`permission denied for table app_users`** for `service_role`. Migration
0019 rebuilt the privilege layer from a REVOKE baseline and granted `authenticated` exactly what
it needs; nothing ever granted `service_role` anything. `service_role` has BYPASSRLS, so RLS was
never the blocker — the GRANT layer was, working exactly as designed.

Notably the failure happened *after* signature verification, which is positive evidence that
`CLERK_WEBHOOK_SIGNING_SECRET`, `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are all present
and that the signing secret matches Clerk's: a missing secret returns 503 and a bad signature
returns 401.

Fixed by migration **0023**, which grants `service_role` only what the webhook needs, column by
column, on `app_users` alone — deliberately *not* Supabase's usual blanket
`GRANT ALL ... TO service_role`. After 0023 `service_role` still cannot write `role`, cannot
touch any other table, and cannot delete. Assertions **SR-1/2/3** lock this in.

A second, smaller defect was fixed at the same time: `err instanceof Error` reported every
database failure as `"unknown"`, because a `PostgrestError` is a plain object. The handler now
logs `message`/`code`/`details`/`hint`. The HTTP response body stays opaque.

0023 also changes `app_users.is_active` to default **false**. It previously defaulted to true, so
any INSERT that omitted the column would have created a live account.

### Hardening: the `service_role` privilege boundary (migration 0024)

Verifying the webhook fix surfaced a pre-existing gap. `service_role` held **TRUNCATE,
REFERENCES, TRIGGER and MAINTAIN on all 35 tables and views in `public`** -- 106 grants. Nothing
in this repository granted them; they came from a stock Supabase default privilege
(`public / grantor postgres / tables -> service_role=Dxtm`). 0019's REVOKE baseline named only
`anon` and `authenticated`, so they survived it.

TRUNCATE is the serious one: a hard delete of an entire table that bypasses RLS, fires no row
trigger and leaves no audit row -- the precise opposite of "records are archived, never removed".
Anyone holding the service-role key could have emptied any table, audit history included.

0024 revokes all four from every application-owned object, and -- the part that makes it stick --
revokes them from the schema's **default privileges**, so the next `CREATE TABLE` cannot silently
re-grant them. Platform schemas (`auth`, `storage`, `realtime`, `graphql`, `extensions`) and the
separate `supabase_admin` default-privilege entries are untouched; this project does not own them
and revoking them would break Supabase internals.

Revoking REFERENCES and TRIGGER cannot break anything that exists: those privileges govern only
the creation of NEW foreign keys and triggers, and every constraint in this schema was created by
the migration role.

**The resulting boundary**, asserted permanently by SR-1 through SR-10:

| `service_role` may | `service_role` may not |
| --- | --- |
| `SELECT` on `app_users` | reach any other table in `public` |
| `INSERT (clerk_user_id, email, full_name, role, is_active)` | write `role` on an existing row |
| `UPDATE (email, full_name, is_active)` | `DELETE` or `TRUNCATE` anything |
| | write `user_region_access` |
| | create foreign keys or triggers |

Security properties:

- **Signature verified** with Svix (Clerk's official mechanism) before the body is trusted.
  Missing headers → 401 without reading the body; invalid signature → 401 with no diagnostic
  detail that would help calibrate a forgery. Timestamp verification provides replay protection.
- **Idempotent** by construction.
- **Cannot grant privileges.** `role` and `is_active` are never written by `user.updated`, so no
  Clerk profile edit — including anything a user puts in their own Clerk metadata — can change
  database authorization. Identity sync and authorization management are separate concerns.
- Uses the service-role key, which bypasses RLS; that is why it does as little as possible and why
  the key is an Edge Function secret that never reaches the browser.

---

## 9. First administrator bootstrap

**Explicitly not** "first user becomes admin", and **not** inferred from an email domain. Either
would let anyone who signs up first take the system.

The chosen mechanism is a **one-time server-side assignment against a verified Clerk user id**:

1. The owner signs in once through the application. The webhook creates their row as
   `viewer` / inactive — no privileges.
2. The owner supplies their **Clerk user id** (`user_...`), read from the Clerk dashboard.
3. A single statement is executed server-side (Supabase SQL editor or the management API), by
   someone with database access:

```sql
-- Bootstrap the first administrator. Run once, with a verified Clerk user id.
UPDATE app_users
   SET role = 'admin', is_active = true
 WHERE clerk_user_id = 'user_REPLACE_WITH_VERIFIED_CLERK_USER_ID';

-- Grant all six regions (admin is company-wide anyway; this makes it explicit).
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT u.id, r.id, true
FROM app_users u CROSS JOIN regions r
WHERE u.clerk_user_id = 'user_REPLACE_WITH_VERIFIED_CLERK_USER_ID'
ON CONFLICT (app_user_id, region_id) DO NOTHING;
```

It is not a migration, because a migration would hard-code a personal identifier into version
control and re-apply it on every rebuild. After this, all further role and region administration
happens in-app under RLS, and **ordinary authentication never assigns admin**.

---

### Executed — 2026-09-14

The bootstrap has been performed once, with the owner's explicit approval, against
`user_3JKeiCQiDee4nJSegPpzfqeuywe` (app_users id `31d59e99-70cb-4155-bb91-8f813a70f37b`):
`role` viewer -> admin, `is_active` false -> true. Exactly one row, enforced by a
`GET DIAGNOSTICS ... ROW_COUNT` guard that would have aborted the transaction on any other count.
No `user_region_access` row was created, because `cng_can_read_region()` returns true for `admin`
without one.

Verified afterwards through the real RLS path (role `authenticated`, `request.jwt.claims.sub` set
to that Clerk id): `cng_current_role()` resolves to `admin`, all **six** Regions are visible
(East, West, Canal, Delta, Alex, Upper), and `cng_can_access_unmapped_srv()` is true.

**Audit evidence.** The architecture already supports recording this honestly — `audit_logs.actor_id`
is nullable and `actor_label` is free text — so one `user_role_changed` row was written inside the
same transaction, carrying the full before/after JSON. `actor_id` is **NULL**, because no
application user performed it, and `actor_label` says exactly what did:
*out-of-band database bootstrap (no application actor)*. No actor was invented and no application
identity was claimed. This is the only row in `audit_logs`.

---

## 10. Test strategy — and what each kind of test actually proves

Two categories, deliberately not conflated.

### Database authorization tests — **done**

`supabase/tests/rls_authorization.sql`. Executed as the real `authenticated` Postgres role with
synthetic `request.jwt.claims`, which is the same GUC Supabase populates from a verified Clerk
token. These exercise the genuine GRANT + RLS path.

| Environment | Assertions | Result |
| --- | --- | --- |
| Local PostgreSQL 16, clean rebuild from zero | **87** | all pass |
| Hosted Supabase (PG17) | **49** | all pass |

They prove role behaviour, region scoping, IDOR rejection, cross-region write rejection,
self-escalation rejection, audit immutability and personal-data isolation.

**They do not prove the Clerk → Supabase token exchange.** A synthetic claim is not a Clerk
signature.

### End-to-end tests — **PASSED 2026-09-14, in a real browser**

Performed by the owner, because this environment cannot: Clerk and the Supabase API are both
blocked by its organization egress policy (403 on CONNECT), so no session in this repository can
reach them. The test ran against `/auth-test` with a genuine Clerk-issued session token:

| Observed | Result |
| --- | --- |
| Clerk session token obtained | yes |
| Clerk user id | matches the webhook-synchronized `app_users` row |
| Application role | `admin` |
| `is_active` | `true` |
| `user_region_access` grants | **none** |
| Regions visible under RLS | **East, West, Canal, Delta, Alex, Upper** |
| JWT errors | none |

This is the complete real path: Clerk authentication -> Clerk-issued session token -> Supabase
Third-Party Auth verification -> PostgreSQL -> `app_users` authorization -> RLS -> Admin access to
all six Regions. It is the claim the database suites deliberately could not make, because a
synthetic `request.jwt.claims` is not a Clerk signature.

**Six Regions with zero region grants is the architecture working, not a gap.**
`cng_can_read_region()` short-circuits to true for `admin` and `manager`; `user_region_access` is
how `engineer` and `viewer` are scoped. An admin with grant rows would have been the anomaly.

#### The one defect this test surfaced

The first browser run returned `JWT not yet valid` on the `regions` query while `app_users`
succeeded 3 ms earlier. The hosted edge logs showed the probe running twice (React StrictMode) —
six requests in ~450 ms, one 401 among them, and the same request succeeding 240 ms later.
Root cause in application code: `useSupabaseClient` rebuilt the client inside
`useMemo(..., [session])`, so a new client — an independent token path — appeared per session
object and per StrictMode mount. Six concurrent `accessToken` callbacks across multiple clients is
what let one request carry a just-minted token while its sibling carried the previous one.

Fixed by making the client a singleton that reads the **current** session at request time.
Nothing was weakened: no JWT validation disabled, no RLS change, no anonymous access, no retry or
delay, no `service_role` in the browser. `CLIENT-1..5` pin it permanently.

Because clock skew could not be measured from this environment, it was never asserted: `/auth-test`
now reports `iat`/`nbf`/`exp` as deltas against the Supabase server clock and states a verdict. It
reads only those three claims and never renders, logs or stores the token (`TIMING-1`).

---

## 10a. Verification of the hosted authentication configuration

Performed before any change, over the database (the only channel reachable from this session).

**Ruled out conclusively — every row count was 0:**

| Checked | Rules out |
| --- | --- |
| `auth.custom_oauth_providers` | a Custom OAuth Provider configuration |
| `auth.oauth_clients`, `auth.oauth_authorizations`, `auth.oauth_consents` | Supabase acting as an OAuth server |
| `auth.sso_providers`, `auth.saml_providers`, `auth.sso_domains` | a SAML/SSO provider |
| `auth.users`, `auth.identities`, `auth.sessions`, `auth.refresh_tokens` | any use of Supabase's own Auth user store |

So **no wrong or duplicated authentication configuration exists in any database-visible form**,
and nothing needs to be removed.

**What could not be positively confirmed from here:** the Third-Party Auth registration itself
lives in GoTrue runtime configuration, readable only through the Supabase dashboard,
`api.supabase.com`, or the project's `/auth/v1/settings` — all egress-blocked. The Supabase MCP
server exposes no auth-configuration tool. The owner must confirm visually that
**Authentication → Sign In / Providers → Third-Party Auth** lists exactly one Clerk entry with
domain `joint-lion-2271.clerk.accounts.dev`, and that **no** legacy JWT-template secret is set
under Authentication → JWT settings.

---

## 11. Frontend behaviour (minimal by design)

`AuthGate` handles every state explicitly — loading, signed out, signed in but not provisioned,
awaiting approval, error, active — so no state silently renders an empty application. Sign-in and
sign-out use Clerk's components.

This is **UX only**. Hiding a screen is not security; the database refuses unauthorized reads and
writes regardless of what is rendered. The professional interface begins in Prompt 7.

### TEMPORARY routes — remove before production

`/sign-in`, `/sign-up` and `/auth-test` exist only to perform and repeat the real authentication
test. They are **kept on purpose** for later acceptance testing, and every one of their source
files says TEMPORARY at the top.

They sit **outside `AuthGate`** by design: sign-in must work while signed out, and `/auth-test`
must be reachable while an account is still inactive — the state a first sign-in produces.
Reachability grants nothing. Every value the page shows is what RLS chose to return for that
caller, and an inactive account sees only its own `app_users` row.

Removal checklist for the production cut: delete `src/features/auth/SignInPage.tsx`,
`SignUpPage.tsx`, `AuthTestPage.tsx`, their exports in `src/features/auth/index.ts`, and the three
route entries at the top of `src/routes.tsx`. Nothing else depends on them. Keep
`src/lib/auth/tokenTiming.ts` only if the diagnostic is still wanted.

---

## 13. Known deferrals

| Item | Phase | Why |
| --- | --- | --- |
| Moving authz helpers to a non-exposed schema | Prompt 22 | Supabase's linter WARNs that `cng_current_role()` and `cng_has_region_grant()` are callable by `authenticated` via `/rest/v1/rpc/`. Not exploitable: neither takes a user-supplied identity, both answer only about the caller — so a caller learns their own role and their own grant, which they may already read. Tracked, not blocking |
| Removing `/sign-in`, `/sign-up` and `/auth-test` | before production | temporary Prompt-5 routes, kept deliberately for acceptance testing (§11) |
| Manager access to the user directory | business decision | currently manager has none, per "limit to actual operational need" |
| Manager managing region access | business decision | currently admin only |
| Notification delivery (Resend, VAPID, cron) | later phases | out of scope here |
