-- 0024_service_role_privilege_boundary.sql
-- Remove the destructive and unnecessary privileges `service_role` holds on
-- this project's own objects, and stop future tables from silently regaining
-- them.
--
-- WHAT WAS FOUND. `service_role` held TRUNCATE, REFERENCES and TRIGGER (plus
-- MAINTAIN on PostgreSQL 17) on EVERY table and view in `public` -- 35 objects.
-- Nothing in this repository granted them. They arrive from a stock Supabase
-- default privilege:
--
--   public / grantor postgres / tables -> service_role=Dxtm
--
-- 0019 rebuilt the privilege layer from a REVOKE baseline, but that baseline
-- named only `anon` and `authenticated`, so these were never stripped.
--
-- WHY IT MATTERS. TRUNCATE is a hard delete of an entire table. It bypasses
-- RLS, fires no row triggers, and leaves no audit row -- the exact opposite of
-- this project's rule that operational, import, mapping and audit records are
-- archived, never removed. Anyone holding the service-role key could have
-- emptied any table, audit history included. REFERENCES and TRIGGER are
-- schema-modification privileges (create a foreign key against a table, attach
-- a trigger to it) that no webhook needs.
--
-- SCOPE. Application-owned objects only: every table, view and materialized
-- view in `public`, all of which are owned by the migration role. Platform
-- schemas (auth, storage, realtime, graphql, extensions, vault) and the
-- separate `supabase_admin` default-privilege entries are NOT touched --
-- revoking those would break Supabase internals, and this project does not own
-- them.
--
-- SAFETY. Revoking REFERENCES and TRIGGER does not affect foreign keys or
-- triggers that already exist; those privileges govern only the creation of NEW
-- ones, and every constraint and trigger in this schema was created by the
-- migration role, not by service_role. Revoking TRUNCATE removes an ability
-- nothing in this project has ever used.

DO $revoke$
DECLARE
  obj    record;
  privs  text := 'TRUNCATE, REFERENCES, TRIGGER';
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN
    RETURN;
  END IF;

  -- MAINTAIN (VACUUM/ANALYZE/REINDEX/CLUSTER/REFRESH) exists from PostgreSQL 17
  -- and is part of the same stock default. Named conditionally so this
  -- migration still applies on 16, which the from-zero rebuild uses.
  IF current_setting('server_version_num')::int >= 170000 THEN
    privs := privs || ', MAINTAIN';
  END IF;

  FOR obj IN
    SELECT c.oid::regclass AS ident
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'
       AND c.relkind IN ('r', 'v', 'm')
       AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
  LOOP
    EXECUTE format('REVOKE %s ON %s FROM service_role', privs, obj.ident);
  END LOOP;

  -- Stop the leak at its source. Without this, the next CREATE TABLE in this
  -- schema would hand service_role TRUNCATE again, silently.
  EXECUTE format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA public REVOKE %s ON TABLES FROM service_role',
    current_user, privs);
END;
$revoke$;

-- ---------------------------------------------------------------------------
-- Re-assert the intended boundary, so this file alone states it completely.
-- These are idempotent: 0023 already granted them.
-- ---------------------------------------------------------------------------

GRANT SELECT ON app_users TO service_role;
GRANT INSERT (clerk_user_id, email, full_name, role, is_active) ON app_users TO service_role;
GRANT UPDATE (email, full_name, is_active) ON app_users TO service_role;

COMMENT ON TABLE app_users IS
  'Application accounts. The ONLY table `service_role` (the Clerk user-sync '
  'webhook) can reach: SELECT, INSERT of the five onboarding columns, and '
  'UPDATE of email/full_name/is_active. It can never write `role`, never '
  'delete, and never truncate anything.';
