# Authentication and Authorization

How identity, roles and Region access work in the CNG Station Management System.

**Separation of concerns:** Supabase Auth answers *who you are*. The database answers *what you may
do*. A frontend role check is a convenience for the interface and is never a security control.

Related: [`database.md`](./database.md) · [`architecture.md`](./architecture.md) ·
[`deployment-cloudflare.md`](./deployment-cloudflare.md) · [`../CLAUDE.md`](../CLAUDE.md) ·
history: [`authentication-clerk-history.md`](./authentication-clerk-history.md)

> **Status (2026-09-23):** first-party **Supabase Auth** since migration `0056_supabase_auth`
> (hosted `20260920200509`). Clerk is no longer used. The Clerk-era design is kept only as history.

## 1. Identity provider

| Concern | Implementation |
| --- | --- |
| Provider | Supabase Auth of project `cng-station-management` (`ypkggegquetvpsflkaxg`) |
| Browser client | `src/lib/supabase/client.ts`: one `supabase-js` client, **publishable key only**, `persistSession`, `autoRefreshToken`, `detectSessionInUrl` |
| Session state | `src/features/auth/AuthProvider.tsx`, gated by `AuthGate.tsx` |
| Sign in | `/sign-in`: email + password (`signInWithPassword`); **Sign in with Google** (`signInWithOAuth({ provider: 'google' })`), always shown |
| Sign up | `/sign-up`: `signUp` with `emailRedirectTo = <origin>/dashboard` |
| Sign out | account control in the header |
| Password reset | `/forgot-password` sends `resetPasswordForEmail` (same reply whether or not the account exists); `/reset-password` sets the new password (min 8) from the recovery session |

No service-role key, JWT secret or Auth admin credential exists anywhere in the frontend or the repository.

## 2. Token flow

```
Supabase Auth sign-in
  └─> Supabase session JWT (sub = auth.users.id, role = authenticated)
       └─> supabase-js sends it on every request
            └─> PostgREST verifies it with the project's own keys
                 └─> request.jwt.claims -> cng_jwt_sub()
                      └─> cng_current_app_user_id()  (app_users.auth_user_id = sub AND is_active)
                           └─> RLS policies and cng_require_admin() decide every row and RPC
```

`app_users.auth_user_id` (a unique FK to `auth.users.id`) is the identity key. `app_users.clerk_user_id` is a
**legacy** column, kept only for audit continuity. It is honoured only on a row with no `auth_user_id`, and
Clerk no longer issues tokens to this project, so no live session can present one.

## 3. Sign-up grants nothing

The trigger `cng_auth_user_sync` on `auth.users` (function `cng_handle_auth_user`, SECURITY DEFINER,
EXECUTE revoked from every browser role) creates the matching `app_users` row as **`viewer`, `is_active = false`**.
An inactive user resolves to no app user, so RLS returns nothing. An administrator activates the account and
grants Regions in **Admin → Users**. Role, activation and Region access are never taken from Auth metadata,
an email domain or sign-up order.

The very first production admin was created by the one-off, production-only migration
`20260920204210 bootstrap_initial_admin`. The repository holds a no-op placeholder under the same version (the
original named a personal email). A clean rebuild creates its first admin with `docs/operations-runbook.md` §2a.

## 4. Authorization (unchanged by the provider switch)

- Roles: `admin`, `manager`, `engineer`, `viewer` (`app_role`). Region scope comes from `user_region_access`.
- Every table has RLS. Browser writes go through admin-gated SECURITY DEFINER functions that derive the actor
  server-side (`cng_require_admin()`). No function accepts an actor parameter.
- User administration (`cng_admin_set_user_role`, `_set_user_active`, `_grant_region`, `_revoke_region`,
  `_remove_user`) is row-version guarded and writes its audit row in the same statement. An admin cannot
  demote, deactivate or remove themselves, or the last active admin.
- **Removing a user** deletes the `auth.users` row after writing an inactive, identity-less tombstone and its
  audit row. The history keeps a name, but the login is gone.
- Proven by `supabase/tests/rls_authorization.sql` (703 assertions, including every Advisor-listed
  SECURITY DEFINER function against anon / no app user / inactive / viewer / engineer / manager / admin).

## 5. Configuration

Frontend (Cloudflare Pages build variables; publishable only):

| Variable | Purpose |
| --- | --- |
| `VITE_SUPABASE_URL` | project URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | publishable (anon-equivalent) key |

Supabase dashboard (Authentication), which the owner maintains:
- **URL configuration**: Site URL `https://cng-station-management.pages.dev`. Redirect URLs must include
  `https://cng-station-management.pages.dev/**` (sign-up confirmation and OAuth return to `/dashboard` or the
  requested page).
- **Providers**: Email is enabled. Google is optional and needs its OAuth client configured in Supabase and in Google Cloud.
- **Leaked-password protection**: currently OFF (Security Advisor). Recommended ON (§6).

## 6. Open items

1. **Leaked-password protection is off.** It needs the Pro plan; the owner accepted this and set an 8-character minimum with complexity.
2. **Password reset is built (Phase 5)** but needs one owner setting: Dashboard → Authentication → URL
   Configuration → add `https://cng-station-management.pages.dev/reset-password` to Redirect URLs. Without it
   Supabase sends users to the Site URL instead. Not yet live-verified (needs a real reset email).
3. **Signed-in browser verification from the build environment** needs the environment's network policy to allow
   `ypkggegquetvpsflkaxg.supabase.co` and `cng-station-management.pages.dev`.
