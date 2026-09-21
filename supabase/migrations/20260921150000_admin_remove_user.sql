-- Remove an application user from the Admin UI without damaging immutable audit evidence.
-- The app_users row is retained as a tombstone because audit_logs and historical
-- operational records deliberately RESTRICT its deletion. The linked Supabase Auth
-- identity and Region grants are removed, access is disabled, and the admin list hides it.

ALTER TABLE app_users ADD COLUMN IF NOT EXISTS removed_at timestamptz NULL;

CREATE OR REPLACE FUNCTION cng_admin_remove_user(
  p_app_user_id uuid,
  p_expected_updated_at timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, auth
AS $$
DECLARE
  v_actor uuid := public.cng_require_admin();
  v_before public.app_users%ROWTYPE;
  v_auth_user_id uuid;
BEGIN
  SELECT * INTO v_before FROM public.app_users WHERE id = p_app_user_id FOR UPDATE;
  IF NOT FOUND OR v_before.removed_at IS NOT NULL THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = '42704';
  END IF;
  PERFORM public.cng_check_precondition(v_before.updated_at, p_expected_updated_at);
  IF v_before.id = v_actor THEN
    RAISE EXCEPTION 'an administrator cannot remove themselves' USING ERRCODE = '42501';
  END IF;
  IF v_before.role = 'admin' AND v_before.is_active
     AND NOT EXISTS (SELECT 1 FROM public.app_users u WHERE u.role = 'admin' AND u.is_active AND u.removed_at IS NULL AND u.id <> v_before.id) THEN
    RAISE EXCEPTION 'the last active administrator cannot be removed' USING ERRCODE = '23514';
  END IF;

  v_auth_user_id := v_before.auth_user_id;
  DELETE FROM public.user_region_access WHERE app_user_id = p_app_user_id;
  UPDATE public.app_users
     SET is_active = false, auth_user_id = NULL, removed_at = now(), updated_at = now()
   WHERE id = p_app_user_id;

  INSERT INTO public.audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data)
  VALUES ('user_removed', 'app_users', p_app_user_id, v_actor,
          (SELECT full_name FROM public.app_users WHERE id = v_actor), 'user removed',
          jsonb_build_object('email', v_before.email, 'role', v_before.role, 'is_active', v_before.is_active),
          jsonb_build_object('is_active', false, 'removed', true));

  IF v_auth_user_id IS NOT NULL THEN
    DELETE FROM auth.users WHERE id = v_auth_user_id;
  END IF;
END $$;

REVOKE ALL ON FUNCTION cng_admin_remove_user(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_remove_user(uuid, timestamptz) TO authenticated;

DROP VIEW IF EXISTS v_admin_users;
CREATE VIEW v_admin_users WITH (security_invoker = true) AS
SELECT u.id, u.auth_user_id, u.clerk_user_id, u.email, u.full_name,
       u.role, u.is_active, u.created_at, u.updated_at,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                          'region_id', r.id, 'region_name', r.name,
                          'can_map', ura.can_map) ORDER BY r.name)
                   FROM user_region_access ura
                   JOIN regions r ON r.id = ura.region_id
                  WHERE ura.app_user_id = u.id), '[]'::jsonb) AS region_grants
  FROM app_users u
 WHERE u.removed_at IS NULL;

GRANT SELECT ON v_admin_users TO authenticated;

