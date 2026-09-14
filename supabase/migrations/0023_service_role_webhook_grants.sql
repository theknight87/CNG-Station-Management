-- 0023_service_role_webhook_grants.sql
-- The Clerk user-sync webhook could not write `app_users`.
--
-- ROOT CAUSE. PostgREST returned 403 and PostgreSQL logged
-- `permission denied for table app_users` for `service_role`. 0019 rebuilt the
-- privilege layer from a REVOKE baseline and granted `authenticated` exactly
-- what it needs -- but nothing in this schema ever granted `service_role`
-- anything, and this project's tables were not created under the default
-- privileges that would have given it blanket access. `service_role` has
-- BYPASSRLS, so RLS was never the blocker: the SQL GRANT layer was, which is
-- the layer working as designed.
--
-- The fix is NOT to restore Supabase's usual blanket `GRANT ALL ... TO
-- service_role`. That would hand a single leaked key the whole database. The
-- webhook touches exactly one table and three operations, so it is granted
-- exactly those, column by column.
--
-- What `service_role` deliberately still CANNOT do after this migration:
--   * write `role` -- there is no UPDATE(role) and no column-level INSERT
--     privilege beyond the five below, so no Clerk event, and no forged call
--     with a leaked key through PostgREST, can grant a privilege level.
--     Authorization is never synchronized from Clerk (CLAUDE.md s10).
--   * touch ANY other table -- no station, unit, equipment, SRV, audit,
--     import or region-access row is reachable with this key via PostgREST.
--   * DELETE anything, here or anywhere. No hard deletes.

-- `service_role` exists in every hosted Supabase project. It is created here
-- only so a from-zero rebuild on a plain PostgreSQL instance applies the same
-- privileges as the hosted database, rather than silently diverging. BYPASSRLS
-- is deliberately NOT set locally: nothing in this project's own test suites
-- runs as this role, and a local role that can ignore RLS would be a trap.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN NOINHERIT;
  END IF;
END;
$roles$;

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT ON app_users TO service_role;

-- INSERT: the exact five columns `user.created` writes. `role` and `is_active`
-- are included because the webhook must be able to state 'viewer'/false
-- explicitly rather than inherit a default.
GRANT INSERT (clerk_user_id, email, full_name, role, is_active)
  ON app_users TO service_role;

-- UPDATE: identity fields, plus `is_active` for the `user.deleted`
-- deactivation. `role` is absent, and that absence is the escalation guard.
GRANT UPDATE (email, full_name, is_active)
  ON app_users TO service_role;

-- ---------------------------------------------------------------------------
-- Defence in depth: a row that omits `is_active` must not arrive active.
-- ---------------------------------------------------------------------------
-- `is_active` defaulted to true, so any INSERT that failed to name it would
-- have created a LIVE account. The webhook always names it, but the documented
-- rule is that signing up grants nothing, and the default should say so too.
-- Existing rows are unaffected: a default applies only to future INSERTs.

ALTER TABLE app_users ALTER COLUMN is_active SET DEFAULT false;

COMMENT ON COLUMN app_users.is_active IS
  'Activated by an administrator. Defaults to false: a new account, however it '
  'is created, starts with no access until a human activates it.';
