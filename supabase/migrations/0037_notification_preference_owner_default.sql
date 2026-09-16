-- ---------------------------------------------------------------------------
-- 0037 — fix a PRODUCTION defect on /settings (Prompt 18A).
--
-- THE BUG, as reported from production:
--
--     new row violates row-level security policy for table
--     "notification_preferences"
--
-- ROOT CAUSE. `notification_preferences.app_user_id` is NOT NULL with NO
-- DEFAULT, and the client insert (correctly) supplies no user id. The column is
-- therefore NULL, and the policy
--
--     WITH CHECK (app_user_id = cng_current_app_user_id())
--
-- evaluates `NULL = <uuid>` -> NULL -> not true, so the row is rejected. RLS is
-- checked BEFORE the NOT NULL constraint would report, which is why the message
-- names the policy rather than a null violation.
--
-- The mistake behind it is worth stating plainly, because it is easy to repeat:
-- RLS *validates* ownership, it never *populates* it. "The policy binds the row
-- to its owner" is true of reads and of rejecting bad writes; it does not fill
-- a column in. Something server-side still has to supply the value.
--
-- THE FIX. Give the column a SERVER-DERIVED default. The client continues to
-- send no user id — so it cannot spoof one — and the database fills the owner
-- from the verified Clerk subject:
--
--   * `cng_current_app_user_id()` is STABLE, SECURITY INVOKER, has a pinned
--     search_path, reads `request.jwt.claims ->> 'sub'`, and additionally
--     requires `is_active`. An inactive or unauthenticated session yields NULL,
--     the insert is rejected, and nothing is created.
--   * The WITH CHECK is UNCHANGED and still runs. It is now defence in depth:
--     a client that DID supply another user's id is still rejected, which is
--     asserted by PREF-3.
--
-- This is the smallest change that fixes the defect. No policy is weakened, no
-- grant is widened, no identity is trusted from the client, and no service_role
-- path is introduced. The uniqueness that prevents duplicate default rows
-- (`notif_pref_default_uq`) is untouched and still enforced.
-- ---------------------------------------------------------------------------

ALTER TABLE notification_preferences
  ALTER COLUMN app_user_id SET DEFAULT cng_current_app_user_id();

COMMENT ON COLUMN notification_preferences.app_user_id IS
  'The owning user, DERIVED SERVER-SIDE from the verified Clerk subject by cng_current_app_user_id() (migration 0037). A client never supplies it and so cannot spoof one; notif_pref_all''s WITH CHECK still validates it as defence in depth.';
