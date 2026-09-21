-- Use the existing audit_action enum value. The earlier function attempted to
-- insert user_removed, which is not part of the deliberately closed enum.
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
  VALUES ('admin_action', 'app_users', p_app_user_id, v_actor,
          (SELECT full_name FROM public.app_users WHERE id = v_actor), 'User removed',
          jsonb_build_object('email', v_before.email, 'role', v_before.role, 'is_active', v_before.is_active),
          jsonb_build_object('is_active', false, 'removed', true));

  IF v_auth_user_id IS NOT NULL THEN
    DELETE FROM auth.users WHERE id = v_auth_user_id;
  END IF;
END $$;

REVOKE ALL ON FUNCTION cng_admin_remove_user(uuid, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_remove_user(uuid, timestamptz) TO authenticated;
