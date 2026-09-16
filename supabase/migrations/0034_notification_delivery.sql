-- ---------------------------------------------------------------------------
-- 0034 — Notification delivery plumbing (Prompt 15.1). Additive only.
--
-- Prompt 15 built the ALERT engine and deliberately stopped short of sending:
-- `notification_deliveries` existed as a record, but nothing created or
-- completed a row. This migration adds the narrow server-side path, and the
-- one browser-facing function push needs.
--
-- THE ARCHITECTURE IS UNCHANGED, and that is the point:
--
--     technical condition -> persisted ALERT -> DELIVERY attempt
--
-- Delivery consumes an alert that already exists. No function here can create,
-- modify, acknowledge or delete an alert; a failed send only ever writes to
-- `notification_deliveries`.
--
-- WHY THESE ARE SECURITY DEFINER. `service_role` holds SELECT on `app_users`
-- and nothing else (migration 0024). Rather than widening that to cover alerts,
-- preferences, subscriptions and deliveries, it gets EXECUTE on three narrow
-- functions and no table privileges at all. EXECUTE is NOT granted to
-- `authenticated`: sending is a server task, and a browser that could drive it
-- would be an open mail relay.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- attempt_count — bounded retry.
--
-- Prompt 15 recorded delivery status but nothing counted attempts, so a
-- permanently bad address or a dead push endpoint would have been retried
-- forever. Retry amplification is a real cost and a real abuse surface, so the
-- attempt count lives on the row and the claim function caps it.
-- ---------------------------------------------------------------------------
ALTER TABLE notification_deliveries
  ADD COLUMN attempt_count integer NOT NULL DEFAULT 0,
  ADD CONSTRAINT notif_delivery_attempts_ck CHECK (attempt_count >= 0);

COMMENT ON COLUMN notification_deliveries.attempt_count IS
  'Delivery attempts made for this alert/user/channel. Capped by cng_next_pending_deliveries so a permanently failing recipient stops being retried. A retry always targets the SAME alert and can never create a second one.';

-- ---------------------------------------------------------------------------
-- cng_enqueue_alert_deliveries — create PENDING rows for opted-in recipients.
--
-- RECIPIENTS ARE OPT-IN ONLY. A row is created for a user only where that user
-- has an enabled `notification_preferences` row for the channel, either for the
-- alert's specific subject or as their NULL-subject default. There is no
-- "email every app_user" path: authorization to READ an alert is not consent to
-- receive mail about it, and no user is silently subscribed.
--
-- `min_threshold` quietens low-urgency notices where the user asked for that.
-- Thresholds are ordered by urgency, most urgent first, so "at least due_15"
-- means overdue, due_today, due_7 and due_15.
--
-- VISIBILITY STILL GOVERNS. A delivery is only enqueued when the recipient
-- could actually read the alert: the same predicate `alerts_select` uses. A
-- preference cannot be used to receive mail about a region you may not see.
--
-- IDEMPOTENT: `notif_delivery_uq (alert_id, app_user_id, channel)` plus
-- ON CONFLICT DO NOTHING, so re-running enqueues nothing twice and two
-- overlapping runs cannot double-send.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_enqueue_alert_deliveries(p_channel notification_channel)
RETURNS TABLE (enqueued integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_n integer;
BEGIN
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
      -- Quieten below the user's chosen urgency floor.
      LEFT JOIN ordered ao ON ao.threshold = a.threshold
      LEFT JOIN ordered po ON po.threshold = p.min_threshold
     WHERE a.state = 'open'
       AND (p.min_threshold IS NULL OR ao.rank <= po.rank)
       -- The recipient must be able to READ this alert. Same shape as
       -- alerts_select; a preference is not a way round region scoping.
       AND (
         CASE
           WHEN a.station_id IS NOT NULL THEN EXISTS (
             SELECT 1 FROM stations s
              JOIN user_region_access ura
                ON ura.region_id = s.region_id AND ura.app_user_id = p.app_user_id
              WHERE s.id = a.station_id)
             OR u.role IN ('admin', 'manager')
           -- Station-unconfirmed alerts carry raw source text and stay
           -- admin/manager only, exactly as in the read policy.
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

REVOKE ALL ON FUNCTION cng_enqueue_alert_deliveries(notification_channel) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_enqueue_alert_deliveries(notification_channel) TO service_role;

-- ---------------------------------------------------------------------------
-- cng_next_pending_deliveries — claim work to send.
--
-- Returns pending or previously FAILED deliveries with the minimum the sender
-- needs. Retry is built in: a failed row stays claimable, and because the row
-- is keyed to one alert, a retry always targets the SAME alert and can never
-- produce a second one.
--
-- `FOR UPDATE SKIP LOCKED` so two concurrent senders take disjoint work rather
-- than both sending the same notification.
--
-- A cap on attempts stops infinite retry amplification against a permanently
-- bad address or a dead push endpoint.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_next_pending_deliveries(
  p_channel notification_channel,
  p_limit   integer DEFAULT 50
)
RETURNS TABLE (
  delivery_id  uuid,
  alert_id     uuid,
  recipient    text,
  endpoint     text,
  p256dh       text,
  auth         text,
  subject      alert_subject,
  threshold    alert_threshold,
  due_date     date,
  station_name text,
  asset_type   asset_type
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
     WHERE d.channel = p_channel
       AND d.status IN ('pending', 'failed')
       -- Five attempts is enough to ride out a transient provider outage and
       -- few enough that a permanently bad address stops costing sends.
       AND d.attempt_count < 5
     ORDER BY d.attempted_at
     LIMIT greatest(p_limit, 0)
     FOR UPDATE SKIP LOCKED
  )
  SELECT d.id, d.alert_id,
         u.email,
         ps.endpoint, ps.p256dh, ps.auth,
         a.subject, a.threshold, a.due_date,
         s.station_name,
         a.asset_type
    FROM claimed c
    JOIN notification_deliveries d ON d.id = c.id
    JOIN alerts a     ON a.id = d.alert_id
    JOIN app_users u  ON u.id = d.app_user_id
    LEFT JOIN stations s ON s.id = a.station_id
    LEFT JOIN push_subscriptions ps
           ON ps.app_user_id = d.app_user_id AND ps.is_active
   ORDER BY d.attempted_at;
END $$;

REVOKE ALL ON FUNCTION cng_next_pending_deliveries(notification_channel, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_next_pending_deliveries(notification_channel, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- cng_record_delivery_result — write the outcome, and ONLY the outcome.
--
-- This function cannot touch an alert. A failure records `failed` and leaves
-- the alert untouched, unacknowledged and un-duplicated.
--
-- `p_error` is stored as supplied. The EDGE FUNCTION is responsible for
-- sanitizing provider text before it arrives here; the column is readable only
-- by the delivery's own recipient (RLS), never by other users.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_record_delivery_result(
  p_delivery_id          uuid,
  p_status               delivery_status,
  p_provider_message_id  text DEFAULT NULL,
  p_error                text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  UPDATE notification_deliveries d
     SET status              = p_status,
         provider_message_id = p_provider_message_id,
         -- Truncated defensively: a provider can return a very long body, and
         -- none of it belongs in an operational record.
         error_detail        = left(p_error, 500),
         attempted_at        = now(),
         attempt_count       = d.attempt_count + 1,
         delivered_at        = CASE WHEN p_status = 'sent' THEN now() ELSE d.delivered_at END
   WHERE d.id = p_delivery_id;
END $$;

REVOKE ALL ON FUNCTION cng_record_delivery_result(uuid, delivery_status, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_record_delivery_result(uuid, delivery_status, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- cng_save_push_subscription — the ONE browser-facing function here.
--
-- SECURITY INVOKER on purpose: it needs no elevated privilege, so it gets none,
-- and `push_subscriptions`' RLS still applies.
--
-- `app_user_id` is NOT a parameter. It is filled from the session, so a caller
-- cannot register a subscription on behalf of another user however the request
-- is shaped — the Prompt-15 guarantee, kept.
--
-- Re-subscribing with the same endpoint updates that row rather than
-- accumulating duplicates. If an endpoint somehow already belongs to another
-- user (a shared browser profile, a reinstalled service worker), RLS makes the
-- UPDATE match zero rows and the call reports failure rather than silently
-- reassigning someone else's subscription.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_save_push_subscription(
  p_endpoint   text,
  p_p256dh     text,
  p_auth       text,
  p_user_agent text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := cng_current_app_user_id();
  v_id   uuid;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no active application user';
  END IF;
  IF coalesce(btrim(p_endpoint), '') = '' THEN
    RAISE EXCEPTION 'a push endpoint is required';
  END IF;

  UPDATE push_subscriptions
     SET p256dh = p_p256dh, auth = p_auth, user_agent = p_user_agent,
         is_active = true, failure_count = 0
   WHERE endpoint = p_endpoint AND app_user_id = v_user
   RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    INSERT INTO push_subscriptions (app_user_id, endpoint, p256dh, auth, user_agent)
    VALUES (v_user, p_endpoint, p_p256dh, p_auth, p_user_agent)
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION cng_save_push_subscription(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_save_push_subscription(text, text, text, text) TO authenticated;

-- Removing your own subscription is an ordinary DELETE under RLS; no function
-- is needed and none is added.
