# Authentication and Authorization

How identity, roles and region access work in the CNG Station Management System.

**Separation of concerns:** Clerk answers *who you are*. The database answers *what you may do*.
A frontend role check is a convenience for the user interface and is never a security control.

Related: [`database.md`](./database.md) · [`architecture.md`](./architecture.md) · [`../CLAUDE.md`](../CLAUDE.md)

---

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
| Clerk domain | *(set once the application exists; non-secret, goes in `supabase/config.toml` and the Supabase dashboard)* |
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

`supabase/functions/clerk-user-sync/` (written; **not deployed yet**).

| Event | Effect |
| --- | --- |
| `user.created` | upsert with `ignoreDuplicates` → creates `role='viewer'`, `is_active=false`. Redelivery is a no-op and can never reset an approved account back to pending |
| `user.updated` | updates **only** `email` and `full_name` |
| `user.deleted` | sets `is_active = false`. **Never deletes** — audit and mapping history reference `app_users` with `ON DELETE RESTRICT`, and that history must outlive the account |

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

### End-to-end tests — **not yet performed**

Requires the Clerk application, the Supabase third-party registration, and a real browser session.
See §12.

---

## 11. Frontend behaviour (minimal by design)

`AuthGate` handles every state explicitly — loading, signed out, signed in but not provisioned,
awaiting approval, error, active — so no state silently renders an empty application. Sign-in and
sign-out use Clerk's components.

This is **UX only**. Hiding a screen is not security; the database refuses unauthorized reads and
writes regardless of what is rendered. The professional interface begins in Prompt 7.

---

## 12. Known deferrals

| Item | Phase | Why |
| --- | --- | --- |
| Clerk application creation | **blocked on owner** | no Clerk API tooling is available in this session |
| Supabase third-party auth registration | **blocked on owner** | needs the Clerk domain, which needs the application |
| End-to-end Clerk-issued auth tests | after the two above | cannot be honestly claimed before then |
| Webhook deployment | after the above | needs the Clerk signing secret as an Edge Function secret |
| First admin bootstrap | after sign-in | needs the owner's verified Clerk user id |
| Moving authz helpers to a non-exposed schema | Prompt 22 | removes RPC exposure of the two DEFINER helpers |
| Manager access to the user directory | business decision | currently manager has none, per "limit to actual operational need" |
| Manager managing region access | business decision | currently admin only |
| Notification delivery (Resend, VAPID, cron) | later phases | out of scope here |
