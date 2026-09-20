-- Replace Clerk third-party identity with first-party Supabase Auth.
-- Legacy Clerk subjects remain temporarily for rollback and historical tests.

ALTER TABLE app_users
  ALTER COLUMN clerk_user_id DROP NOT NULL,
  ADD COLUMN auth_user_id uuid NULL UNIQUE;

ALTER TABLE app_users
  ADD CONSTRAINT app_users_identity_ck
  CHECK (auth_user_id IS NOT NULL OR clerk_user_id IS NOT NULL);

DO $constraint$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    ALTER TABLE app_users
      ADD CONSTRAINT app_users_auth_user_fk
      FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE RESTRICT;
  END IF;
END
$constraint$;

COMMENT ON COLUMN app_users.auth_user_id IS
  'Supabase Auth user UUID. Production identity key for new sessions.';
COMMENT ON COLUMN app_users.clerk_user_id IS
  'Legacy Clerk subject retained temporarily for rollback and audit continuity.';

CREATE OR REPLACE FUNCTION cng_current_app_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT u.id
  FROM app_users u
  WHERE (u.auth_user_id::text = cng_jwt_sub()
         OR (u.auth_user_id IS NULL AND u.clerk_user_id = cng_jwt_sub()))
    AND u.is_active;
$$;

COMMENT ON FUNCTION cng_current_app_user_id() IS
  'Current active app_users.id from the verified JWT subject. Supabase Auth UUID is authoritative; legacy Clerk subject is rollback-only.';

CREATE OR REPLACE FUNCTION cng_current_role()
RETURNS app_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT u.role
  FROM app_users u
  WHERE (u.auth_user_id::text = cng_jwt_sub()
         OR (u.auth_user_id IS NULL AND u.clerk_user_id = cng_jwt_sub()))
    AND u.is_active;
$$;

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
    WHERE (u.auth_user_id::text = cng_jwt_sub()
           OR (u.auth_user_id IS NULL AND u.clerk_user_id = cng_jwt_sub()))
      AND u.is_active
      AND ura.region_id = p_region_id
      AND (NOT p_require_map OR ura.can_map)
  );
$$;

DROP POLICY app_users_select ON app_users;
CREATE POLICY app_users_select ON app_users FOR SELECT TO authenticated
  USING (
    auth_user_id::text = cng_jwt_sub()
    OR (auth_user_id IS NULL AND clerk_user_id = cng_jwt_sub())
    OR cng_is_admin()
  );

-- User metadata is copied only to display fields, never to authorization data.
CREATE OR REPLACE FUNCTION public.cng_handle_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_full_name text;
BEGIN
  v_full_name := nullif(trim(coalesce(
    NEW.raw_user_meta_data ->> 'full_name',
    NEW.raw_user_meta_data ->> 'name',
    ''
  )), '');

  INSERT INTO public.app_users (auth_user_id, email, full_name, role, is_active)
  VALUES (NEW.id, NEW.email, v_full_name, 'viewer', false)
  ON CONFLICT (auth_user_id) DO UPDATE
    SET email = EXCLUDED.email,
        full_name = coalesce(EXCLUDED.full_name, app_users.full_name);

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.cng_handle_auth_user() FROM PUBLIC, anon, authenticated;

DO $trigger$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    EXECUTE 'DROP TRIGGER IF EXISTS cng_auth_user_sync ON auth.users';
    EXECUTE 'CREATE TRIGGER cng_auth_user_sync
             AFTER INSERT OR UPDATE OF email, raw_user_meta_data ON auth.users
             FOR EACH ROW EXECUTE FUNCTION public.cng_handle_auth_user()';
  END IF;
END
$trigger$;

DROP VIEW v_admin_users;
CREATE VIEW v_admin_users WITH (security_invoker = true) AS
SELECT u.id, u.auth_user_id, u.clerk_user_id, u.email, u.full_name,
       u.role, u.is_active, u.created_at, u.updated_at,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                          'region_id', r.id, 'region_name', r.name,
                          'can_map', ura.can_map) ORDER BY r.name)
                   FROM user_region_access ura
                   JOIN regions r ON r.id = ura.region_id
                  WHERE ura.app_user_id = u.id), '[]'::jsonb) AS region_grants
  FROM app_users u;

GRANT SELECT ON v_admin_users TO authenticated;

-- Existing Supabase users receive safe pending profiles. Legacy Clerk rows are
-- not auto-linked by email; moving privileges requires an explicit admin step.
DO $backfill$
BEGIN
  IF to_regclass('auth.users') IS NOT NULL THEN
    EXECUTE $sql$
      INSERT INTO public.app_users (auth_user_id, email, full_name, role, is_active)
      SELECT au.id, au.email,
             nullif(trim(coalesce(au.raw_user_meta_data ->> 'full_name',
                                  au.raw_user_meta_data ->> 'name', '')), ''),
             'viewer'::public.app_role, false
        FROM auth.users au
       WHERE NOT EXISTS (
         SELECT 1 FROM public.app_users app WHERE app.auth_user_id = au.id
       )
      ON CONFLICT (auth_user_id) DO NOTHING
    $sql$;
  END IF;
END
$backfill$;
