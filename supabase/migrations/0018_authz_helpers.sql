-- 0018_authz_helpers.sql
-- Authorization helper functions for RLS.
--
-- IDENTITY SOURCE
-- ---------------
-- Clerk is the identity provider via Supabase's CURRENT Third-Party Auth
-- integration (the JWT-template approach was deprecated 2025-04-01 and is NOT
-- used). Supabase verifies the Clerk-signed session token and exposes its claims
-- through the `request.jwt.claims` GUC; the Clerk user id is the `sub` claim.
--
-- These helpers read that GUC directly rather than calling Supabase's
-- `auth.jwt()`. Two reasons: the policies stay portable so the full RLS suite
-- can be rebuilt and tested on plain PostgreSQL from zero, and nothing in this
-- schema depends on (or touches) Supabase's `auth` schema.
--
-- SECURITY DEFINER — used deliberately, and only where genuinely required
-- ----------------------------------------------------------------------
-- `app_users` and `user_region_access` are themselves RLS-protected. A policy on
-- `app_users` that needed to read `app_users` to learn the caller's role would
-- recurse infinitely. The three lookup helpers below are therefore
-- SECURITY DEFINER purely to break that recursion.
--
-- They are safe because:
--   * they take NO user-supplied identity parameter — they always resolve the
--     CURRENT `sub` claim, so a caller cannot ask "what are Bob's permissions?";
--   * they return a single boolean or role, never a row of another user's data;
--   * `search_path` is pinned to `pg_catalog, public`, so no user-controlled
--     object resolution is possible;
--   * EXECUTE is granted only to `authenticated`, never to `anon` or PUBLIC;
--   * they are STABLE and side-effect free.
--
-- This is recursion-breaking, not an RLS bypass: every one of them still only
-- ever discloses facts about the caller.

-- Mirror Supabase's API roles so the same grants and the same RLS suite run
-- identically from zero on plain PostgreSQL. No-ops on Supabase, where both
-- roles already exist. This MUST come before any GRANT that names them.
DO $roles$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT;
  END IF;
END;
$roles$;

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cng_jwt_sub()
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '');
$$;

COMMENT ON FUNCTION cng_jwt_sub() IS
  'Clerk user id (the `sub` claim) of the current request, or NULL when unauthenticated.';

-- ---------------------------------------------------------------------------
-- Current user's application role
--
-- Returns NULL for: unauthenticated requests, a Clerk user with no app_users
-- row, and — importantly — a user whose account is not yet activated. A pending
-- user therefore has NO role and fails every authorization predicate below,
-- which is what makes the onboarding state safe by default.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cng_current_role()
RETURNS app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT u.role
  FROM app_users u
  WHERE u.clerk_user_id = cng_jwt_sub()
    AND u.is_active;
$$;

COMMENT ON FUNCTION cng_current_role() IS
  'Application role of the CURRENT authenticated user, or NULL if unauthenticated, unknown, or not yet activated. SECURITY DEFINER solely to break RLS recursion on app_users; takes no identity argument, so it cannot be used to inspect another user.';

CREATE OR REPLACE FUNCTION cng_is_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT cng_current_role() = 'admin';
$$;

CREATE OR REPLACE FUNCTION cng_is_manager_or_admin()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT cng_current_role() IN ('admin', 'manager');
$$;

COMMENT ON FUNCTION cng_is_manager_or_admin() IS
  'True for admin and manager. These two roles are company-wide by policy; engineer and viewer are region-scoped.';

-- ---------------------------------------------------------------------------
-- Region authorization
--
-- Read  : admin/manager company-wide; engineer/viewer only granted regions.
--         Viewer is NOT assumed to have all-region access (prompt §10).
-- Write : admin/manager company-wide; engineer only granted regions; viewer never.
-- Map   : as write, but an engineer additionally needs the `can_map` grant flag.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cng_has_region_grant(p_region_id uuid, p_require_map boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM user_region_access ura
    JOIN app_users u ON u.id = ura.app_user_id
    WHERE u.clerk_user_id = cng_jwt_sub()
      AND u.is_active
      AND ura.region_id = p_region_id
      AND (NOT p_require_map OR ura.can_map)
  );
$$;

COMMENT ON FUNCTION cng_has_region_grant(uuid, boolean) IS
  'Does the CURRENT user hold a region grant for p_region_id (optionally requiring can_map)? Resolves the caller''s own identity only. SECURITY DEFINER to break RLS recursion on user_region_access/app_users.';

CREATE OR REPLACE FUNCTION cng_can_read_region(p_region_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
           WHEN cng_current_role() IN ('admin', 'manager') THEN true
           WHEN cng_current_role() IN ('engineer', 'viewer') THEN cng_has_region_grant(p_region_id, false)
           ELSE false
         END;
$$;

CREATE OR REPLACE FUNCTION cng_can_write_region(p_region_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
           WHEN cng_current_role() IN ('admin', 'manager') THEN true
           WHEN cng_current_role() = 'engineer' THEN cng_has_region_grant(p_region_id, false)
           ELSE false      -- viewer and unauthenticated: never
         END;
$$;

CREATE OR REPLACE FUNCTION cng_can_map_region(p_region_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE
           WHEN cng_current_role() IN ('admin', 'manager') THEN true
           WHEN cng_current_role() = 'engineer' THEN cng_has_region_grant(p_region_id, true)
           ELSE false
         END;
$$;

-- ---------------------------------------------------------------------------
-- Unresolved-SRV authorization (prompt §11, §20, §27)
--
-- An SRV in `needs_station_mapping` has station_id NULL. Its `region_id` came
-- from the source Area column and its `source_station_name_raw` is untouched
-- source text. NEITHER is a confirmed authorization boundary: raw source text is
-- evidence, not a security decision.
--
-- Region-scoped roles therefore get NO access to such a record. Only admin and
-- manager — who are company-wide by policy anyway — may see or map it. An
-- engineer consequently cannot use the mapping workflow to claim an unresolved
-- SRV into their own region, because they cannot see it in the first place.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cng_can_access_unmapped_srv()
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT cng_is_manager_or_admin();
$$;

COMMENT ON FUNCTION cng_can_access_unmapped_srv() IS
  'Access to an SRV whose canonical Station is unconfirmed. Admin/Manager only. Never derived from region_id or source_station_name_raw, which are unverified source evidence.';

-- ---------------------------------------------------------------------------
-- EXECUTE privileges: authenticated only. `anon` gets nothing.
-- ---------------------------------------------------------------------------

DO $$
DECLARE fn text;
BEGIN
  FOREACH fn IN ARRAY ARRAY[
    'cng_jwt_sub()', 'cng_current_role()', 'cng_is_admin()', 'cng_is_manager_or_admin()',
    'cng_has_region_grant(uuid, boolean)', 'cng_can_read_region(uuid)',
    'cng_can_write_region(uuid)', 'cng_can_map_region(uuid)',
    'cng_can_access_unmapped_srv()', 'cng_current_app_user_id()',
    'cng_days_left(date, date_precision)', 'cng_due_status(date, date_precision)',
    'cng_date_display(date, date_precision, text)', 'cng_business_date()',
    'cng_normalize_name(text)', 'cng_owner_confirmed_canonical(text, text)',
    'cng_classify_identifier(text, asset_type)'
  ]
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM PUBLIC', fn);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
      EXECUTE format('REVOKE ALL ON FUNCTION public.%s FROM anon', fn);
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION public.%s TO authenticated', fn);
    END IF;
  END LOOP;
END;
$$;
