-- ---------------------------------------------------------------------------
-- 0035 — Server-side Web Push delivery.
--
-- This migration adds NO new notification system. `web_push` has been a value
-- of `notification_channel` since migration 0001, `push_subscriptions` has
-- existed since 0009, and `cng_enqueue_alert_deliveries` /
-- `cng_record_delivery_result` (0034) are channel-agnostic and are reused
-- unchanged. Email behaviour is untouched by this file.
--
-- Four things Web Push needs that email does not:
--
-- 1. ONE DELIVERY, MANY ENDPOINTS. An email recipient has one address; a push
--    recipient has one subscription PER BROWSER. The delivery contract stays
--    `notif_delivery_uq (alert_id, app_user_id, channel)` — one row per user
--    per alert — so the claim function returns that user's active subscriptions
--    AGGREGATED into one row. `cng_next_pending_deliveries` LEFT JOINs
--    push_subscriptions and would emit one row per browser, which would claim
--    and count the same delivery twice; that is why web_push gets its own
--    claim function rather than a widened shared one.
-- 2. SUBSCRIPTIONS EXPIRE. A push service answers 404/410 for an endpoint the
--    browser has discarded. That is permanent and must deactivate the row.
-- 3. TRANSIENT FAILURES MUST NOT. A 500 or a timeout says nothing about the
--    subscription's validity, so it records a failure and nothing more.
-- 4. A CONTROLLED TEST needs to reach the configured test user's own browsers
--    WITHOUT inventing an alert to hang a delivery from.
--
-- Every function here is SECURITY DEFINER with a pinned search_path, REVOKEd
-- from PUBLIC, and granted to `service_role` ONLY. None is reachable from a
-- browser: `authenticated` and `anon` cannot execute any of them, so no
-- signed-in user — admin included — can enumerate endpoints, send to another
-- user, or drive the sender.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Claim pending web_push deliveries.
--
-- Recipients are derived ENTIRELY from stored state: the delivery rows created
-- by cng_enqueue_alert_deliveries from opted-in preferences, joined to that
-- user's own active subscriptions. Nothing about the destination can come from
-- a request.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_next_pending_push_deliveries(p_limit integer DEFAULT 50)
RETURNS TABLE (
  delivery_id   uuid,
  alert_id      uuid,
  subscriptions jsonb,
  subject       alert_subject,
  threshold     alert_threshold,
  due_date      date,
  station_name  text,
  asset_type    asset_type
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN QUERY
  WITH claimed AS (
    SELECT d.id
      FROM notification_deliveries d
     WHERE d.channel = 'web_push'
       AND d.status IN ('pending', 'failed')
       AND d.attempt_count < 5
     ORDER BY d.attempted_at
     LIMIT greatest(p_limit, 0)
     FOR UPDATE SKIP LOCKED
  )
  SELECT d.id, d.alert_id,
         -- One row per delivery whatever the number of browsers. An empty
         -- array is returned rather than NULL so the sender can tell "opted in
         -- but no live browser" from a missing join.
         coalesce(subs.list, '[]'::jsonb),
         a.subject, a.threshold, a.due_date,
         s.station_name,
         a.asset_type
    FROM claimed c
    JOIN notification_deliveries d ON d.id = c.id
    JOIN alerts a    ON a.id = d.alert_id
    LEFT JOIN stations s ON s.id = a.station_id
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object(
               'endpoint', ps.endpoint,
               'p256dh',   ps.p256dh,
               'auth',     ps.auth)) AS list
        FROM push_subscriptions ps
       WHERE ps.app_user_id = d.app_user_id
         AND ps.is_active
    ) subs ON true
   ORDER BY d.attempted_at;
END $$;

COMMENT ON FUNCTION cng_next_pending_push_deliveries(integer) IS
  'Claims pending web_push deliveries for the sender. One row per DELIVERY with the owning user''s active subscriptions aggregated, so a user with several browsers still has exactly one delivery record and one attempt count. service_role only.';

REVOKE ALL ON FUNCTION cng_next_pending_push_deliveries(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_next_pending_push_deliveries(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- A subscription the push service says is GONE.
--
-- Called ONLY for 404/410. Deactivation is a soft state change, never a DELETE:
-- no hard deletes (CLAUDE.md §10), and the row's history stays readable by its
-- owner.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_deactivate_push_subscription(p_endpoint text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_n integer;
BEGIN
  UPDATE push_subscriptions ps
     SET is_active       = false,
         last_failure_at = now(),
         failure_count   = ps.failure_count + 1
   WHERE ps.endpoint = p_endpoint
     AND ps.is_active;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION cng_deactivate_push_subscription(text) IS
  'Marks one expired subscription inactive after a 404/410 from the push service. Never called for a transient failure, and never deletes: the owner keeps the record. service_role only.';

REVOKE ALL ON FUNCTION cng_deactivate_push_subscription(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_deactivate_push_subscription(text) TO service_role;

-- ---------------------------------------------------------------------------
-- Per-endpoint outcome.
--
-- Deliberately CANNOT deactivate. A transient provider failure records itself
-- and leaves the subscription usable, so a push service having a bad minute
-- never silently unsubscribes a user.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_record_push_endpoint_result(p_endpoint text, p_succeeded boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  UPDATE push_subscriptions ps
     SET last_success_at = CASE WHEN p_succeeded THEN now() ELSE ps.last_success_at END,
         last_failure_at = CASE WHEN p_succeeded THEN ps.last_failure_at ELSE now() END,
         failure_count   = CASE WHEN p_succeeded THEN 0 ELSE ps.failure_count + 1 END
   WHERE ps.endpoint = p_endpoint;
END $$;

COMMENT ON FUNCTION cng_record_push_endpoint_result(text, boolean) IS
  'Records a send outcome against one subscription. A failure increments failure_count and nothing else — only cng_deactivate_push_subscription, and only on 404/410, may deactivate. service_role only.';

REVOKE ALL ON FUNCTION cng_record_push_endpoint_result(text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_record_push_endpoint_result(text, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- The controlled test target.
--
-- The email parameter is NOT a caller-chosen destination. This function is
-- executable by service_role alone, and the only caller — the
-- `send-notifications` Edge Function — passes CNG_ALERT_TEST_RECIPIENT from its
-- own environment, never a value from the request body. A browser cannot reach
-- this function at all, so it cannot be used to discover whether an address has
-- an account or to enumerate endpoints.
--
-- It creates NOTHING: no alert, no delivery row, no subscription. A test send
-- is a test, not an operational record.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_test_push_targets(p_email text)
RETURNS TABLE (endpoint text, p256dh text, auth text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF coalesce(btrim(p_email), '') = '' THEN
    RAISE EXCEPTION 'a test recipient is required';
  END IF;
  RETURN QUERY
  SELECT ps.endpoint, ps.p256dh, ps.auth
    FROM push_subscriptions ps
    JOIN app_users u ON u.id = ps.app_user_id
   WHERE lower(u.email) = lower(btrim(p_email))
     AND u.is_active
     AND ps.is_active;
END $$;

COMMENT ON FUNCTION cng_test_push_targets(text) IS
  'Active push subscriptions belonging to the configured live-test user. The address comes from the Edge Function secret CNG_ALERT_TEST_RECIPIENT, never from a request, and no browser role may execute this. Creates no alert and no delivery record.';

REVOKE ALL ON FUNCTION cng_test_push_targets(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_test_push_targets(text) TO service_role;
