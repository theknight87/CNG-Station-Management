-- ---------------------------------------------------------------------------
-- 0040 — Admin channel policy (Prompt 19A §7).
--
-- THE DISTINCTION THIS MIGRATION EXISTS TO MAKE:
--
--   `notification_preferences` is a USER saying "I want email".
--   This table is the ORGANIZATION saying "email is available at all".
--
--   They are different questions and they compose, they do not override:
--
--       effective delivery  =  admin policy permits the channel
--                        AND  the user has opted in to that channel
--
--   Disabling a channel here therefore suppresses delivery WITHOUT touching a
--   single user preference row. Re-enabling it restores exactly the audience
--   that existed before — nobody is silently unsubscribed, and nobody is
--   silently subscribed either. That is the whole reason this is a separate
--   table rather than a bulk update over `notification_preferences`.
--
-- WHY IN-APP HAS NO OFF SWITCH:
--
--   In-app is not a delivery channel in this product — it is the READ surface.
--   `/alerts` and the notification bell are how an engineer sees that a vessel
--   is overdue. An admin toggle that hid them would remove safety-critical
--   compliance visibility from people who are authorized to see it, and would do
--   it invisibly. `notification_channel` has only ever held `email` and
--   `web_push` (migration 0001), so there is no delivery row to suppress either.
--
--   The row exists so the model is explicit and the UI can state the rule, and
--   `ncp_in_app_mandatory_ck` makes disabling it impossible rather than merely
--   discouraged. A toggle that always refuses would be a lie in the shape of a
--   control; the screen says "always on" and says why.
-- ---------------------------------------------------------------------------

CREATE TABLE notification_channel_policy (
  channel      text PRIMARY KEY,
  is_enabled   boolean NOT NULL DEFAULT true,
  note         text NULL,
  updated_by   uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),

  -- `email` and `web_push` are the real `notification_channel` enum values;
  -- `in_app` is deliberately NOT one, and is recorded here as policy only.
  CONSTRAINT ncp_channel_ck CHECK (channel IN ('email', 'web_push', 'in_app')),
  CONSTRAINT ncp_in_app_mandatory_ck CHECK (channel <> 'in_app' OR is_enabled)
);

COMMENT ON TABLE notification_channel_policy IS
  'Organization-level delivery policy. Composes with notification_preferences (policy AND user opt-in); it never writes a user preference. in_app cannot be disabled — it is the alert READ surface, not a delivery channel, and hiding it would remove safety visibility.';

-- Seeded ENABLED, which changes nothing: delivery is still opt-in, and with no
-- preference rows nothing is enqueued. Seeding disabled would silently break the
-- Prompt 15-18 delivery that is already live-verified.
INSERT INTO notification_channel_policy (channel, is_enabled, note) VALUES
  ('email',    true, 'Delivery via Resend. Requires the user to opt in at /settings.'),
  ('web_push', true, 'Delivery via Web Push. Requires the user to opt in AND grant browser permission.'),
  ('in_app',   true, 'Always on. The alerts page and bell are the read surface for compliance state.');

ALTER TABLE notification_channel_policy ENABLE ROW LEVEL SECURITY;
ALTER TABLE notification_channel_policy FORCE ROW LEVEL SECURITY;

-- Readable by every signed-in user: the /settings screen must be able to say
-- "email is currently disabled by an administrator" instead of accepting an
-- opt-in that will never deliver. It discloses no one's data.
CREATE POLICY ncp_select ON notification_channel_policy FOR SELECT TO authenticated
  USING (true);

-- No INSERT/UPDATE/DELETE policy and no such grant: the function below is the
-- only writer, for the same reason as every other admin mutation in 0038.
GRANT SELECT ON notification_channel_policy TO authenticated;

/**
 * Is this channel permitted by organization policy?
 *
 * A channel with no policy row is PERMITTED. That is deliberate: a future
 * channel must not be silently muted by the absence of a row nobody knew to add.
 */
CREATE FUNCTION cng_channel_policy_enabled(p_channel text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT coalesce((SELECT is_enabled FROM notification_channel_policy
                    WHERE channel = p_channel), true);
$$;

REVOKE ALL ON FUNCTION cng_channel_policy_enabled(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_channel_policy_enabled(text) TO authenticated, service_role;

CREATE FUNCTION cng_admin_set_channel_policy(
  p_channel    text,
  p_is_enabled boolean,
  p_expected_updated_at timestamptz DEFAULT NULL,
  p_note       text DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_before notification_channel_policy%ROWTYPE;
  v_after  notification_channel_policy%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM notification_channel_policy WHERE channel = p_channel;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'unknown notification channel' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  IF p_channel = 'in_app' AND NOT p_is_enabled THEN
    RAISE EXCEPTION 'in-app alerts are mandatory: they are the read surface for compliance state, not a delivery channel'
      USING ERRCODE = '23514';
  END IF;

  UPDATE notification_channel_policy
     SET is_enabled = p_is_enabled,
         note = coalesce(p_note, note),
         updated_by = v_actor,
         updated_at = now()
   WHERE channel = p_channel
  RETURNING * INTO v_after;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('alert_rule_changed', 'notification_channel_policy', NULL, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('channel %s %s', p_channel,
                 CASE WHEN p_is_enabled THEN 'enabled' ELSE 'disabled' END),
          jsonb_build_object('channel', p_channel, 'is_enabled', v_before.is_enabled),
          jsonb_build_object('channel', p_channel, 'is_enabled', v_after.is_enabled));

  RETURN v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_set_channel_policy(text, boolean, timestamptz, text) IS
  'Admin-only. Enables or disables a delivery channel for the whole organization. It writes NO user preference: disabling suppresses delivery and re-enabling restores the same audience. in_app cannot be disabled.';

REVOKE ALL ON FUNCTION cng_admin_set_channel_policy(text, boolean, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_set_channel_policy(text, boolean, timestamptz, text) TO authenticated;

-- ---------------------------------------------------------------------------
-- The gate itself.
--
-- Replaced, not rewritten: the recipient predicate, the urgency floor, the
-- visibility check and the ON CONFLICT idempotency are byte-for-byte the 0034
-- logic. The ONLY change is the early return. Putting the gate here rather than
-- in the Edge Function means it applies to every caller, including a future one.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_enqueue_alert_deliveries(p_channel notification_channel)
RETURNS TABLE (enqueued integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_n integer;
BEGIN
  -- ORGANIZATION POLICY FIRST. A disabled channel enqueues nothing and, just as
  -- importantly, changes no preference: the audience is intact the moment it is
  -- re-enabled.
  IF NOT cng_channel_policy_enabled(p_channel::text) THEN
    RETURN QUERY SELECT 0;
    RETURN;
  END IF;

  WITH ordered AS (
    SELECT t.threshold, t.rank FROM (VALUES
      ('overdue'::alert_threshold, 1), ('due_today', 2), ('due_7', 3),
      ('due_15', 4), ('due_30', 5), ('due_60', 6)
    ) AS t(threshold, rank)
  ),
  candidate AS (
    SELECT a.id AS alert_id, p.app_user_id
      FROM alerts a
      JOIN notification_preferences p
        ON p.channel = p_channel
       AND p.is_enabled
       AND (p.subject IS NULL OR p.subject = a.subject)
      JOIN app_users u
        ON u.id = p.app_user_id
       AND u.is_active
      LEFT JOIN ordered ao ON ao.threshold = a.threshold
      LEFT JOIN ordered po ON po.threshold = p.min_threshold
     WHERE a.state = 'open'
       AND (p.min_threshold IS NULL OR ao.rank <= po.rank)
       AND (
         CASE
           WHEN a.station_id IS NOT NULL THEN EXISTS (
             SELECT 1 FROM stations s
              JOIN user_region_access ura
                ON ura.region_id = s.region_id AND ura.app_user_id = p.app_user_id
              WHERE s.id = a.station_id)
             OR u.role IN ('admin', 'manager')
           ELSE u.role IN ('admin', 'manager')
         END
       )
  ),
  inserted AS (
    INSERT INTO notification_deliveries (alert_id, app_user_id, channel, status)
    SELECT c.alert_id, c.app_user_id, p_channel, 'pending'
      FROM candidate c
    ON CONFLICT (alert_id, app_user_id, channel) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_n FROM inserted;

  RETURN QUERY SELECT v_n;
END $$;

COMMENT ON FUNCTION cng_enqueue_alert_deliveries(notification_channel) IS
  'Enqueue pending deliveries for opted-in recipients. Effective delivery requires BOTH organization policy (notification_channel_policy) and the user''s own opt-in. Unchanged from 0034 apart from the policy gate.';

REVOKE ALL ON FUNCTION cng_enqueue_alert_deliveries(notification_channel) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_enqueue_alert_deliveries(notification_channel) TO service_role;
