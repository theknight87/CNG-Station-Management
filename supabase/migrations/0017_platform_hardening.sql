-- 0017_platform_hardening.sql
-- Platform-specific hardening. Guarded so it is a no-op on a plain PostgreSQL
-- instance and on any environment that does not have these objects.
--
-- Supabase creates `public.rls_auto_enable()` on new projects: a SECURITY
-- DEFINER function backing the `ensure_rls` event trigger, which auto-enables
-- RLS on newly created tables in `public`. It ships with default privileges, so
-- PUBLIC (and therefore the `anon` and `authenticated` API roles) holds EXECUTE
-- on it, and Supabase's security advisor flags it as callable through
-- /rest/v1/rpc/.
--
-- Practical exploitability is essentially nil: the function returns
-- `event_trigger`, and PostgreSQL refuses to invoke such a function outside an
-- event-trigger context. We still revoke EXECUTE as defence in depth — an
-- API-reachable SECURITY DEFINER function should never be callable by
-- unauthenticated roles, regardless of whether today's implementation is inert.
--
-- Revoking EXECUTE does NOT disable the event trigger: PostgreSQL invokes event
-- trigger functions through the trigger mechanism, which does not check EXECUTE
-- privilege on the function. This is verified after applying.
--
-- The application's own nine functions are all SECURITY INVOKER with a pinned
-- search_path, so none of them is affected.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rls_auto_enable'
  ) THEN
    EXECUTE 'REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC';

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE 'REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM anon';
    END IF;

    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE 'REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM authenticated';
    END IF;
  END IF;
END;
$$;
