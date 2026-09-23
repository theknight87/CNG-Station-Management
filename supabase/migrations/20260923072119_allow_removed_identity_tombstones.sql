-- cng_admin_remove_user clears auth_user_id for a removed Supabase-only user.
-- Keep identity mandatory for every live profile, while permitting only an
-- inactive tombstone to hold neither an Auth nor legacy Clerk identity.
ALTER TABLE public.app_users
  DROP CONSTRAINT IF EXISTS app_users_identity_ck;

ALTER TABLE public.app_users
  ADD CONSTRAINT app_users_identity_ck
  CHECK (
    (removed_at IS NULL AND (auth_user_id IS NOT NULL OR clerk_user_id IS NOT NULL))
    OR (removed_at IS NOT NULL AND is_active = false)
  );

COMMENT ON CONSTRAINT app_users_identity_ck ON public.app_users IS
  'Live app users require an Auth or legacy Clerk identity. Removed inactive tombstones may clear both identities.';
