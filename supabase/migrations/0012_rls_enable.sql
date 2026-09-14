-- 0012_rls_enable.sql
-- Enable Row Level Security on every table, deny-by-default.
--
-- CLAUDE.md §7: "RLS is enabled on every table from the first migration — no
-- table ships without a policy." The full policy set (role × region × table) is
-- written and reviewed in the dedicated auth/security phase. Until then every
-- table has RLS ENABLED and NO permissive policies, which in PostgreSQL means
-- deny-all for every non-owner role, including Supabase's `anon` and
-- `authenticated`.
--
-- This is the safe ordering: a table can never be exposed by an oversight
-- between being created and being policied. Adding policies later only ever
-- widens access from nothing, so there is no window in which data leaks.
--
-- FORCE ROW LEVEL SECURITY additionally applies policies to the table owner,
-- so a mistakenly-owner-privileged connection is still constrained.

DO $$
DECLARE t text;
BEGIN
  FOR t IN
    SELECT tablename FROM pg_tables WHERE schemaname = 'public'
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE public.%I FORCE ROW LEVEL SECURITY', t);
  END LOOP;
END;
$$;

-- Deny-by-default is intentional and must remain true until the auth phase.
COMMENT ON SCHEMA public IS
  'CNG Station Management. All tables have RLS enabled with no permissive policies yet: deny-all until the auth/security phase adds role- and region-scoped policies.';
