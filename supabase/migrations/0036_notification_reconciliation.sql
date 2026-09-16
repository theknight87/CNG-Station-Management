-- ---------------------------------------------------------------------------
-- 0036 — Prompt 16-18 reconciliation.
--
-- The notification architecture is NOT rebuilt here. Alerts, the three delivery
-- layers, dedupe, retry, the 404/410 rule and acknowledgement semantics are all
-- untouched. This migration closes two evidence-backed gaps found by auditing
-- the delivered system against the original Prompt 16 and Prompt 18 briefs.
--
-- GAP 1 (Prompt 16) — the notification message lacked most of its context.
-- The delivery claim functions returned only subject, threshold, due_date,
-- station_name and asset_type, so an email could not state the Region, the
-- Unit, the asset's serial, the last calibration/inspection, or how many days
-- remain. Those facts all exist already; they simply were not carried to the
-- sender. Both claim functions are widened identically so email and web_push
-- describe the same alert with the same words.
--
-- GAP 2 (Prompt 18) — "mark all as read" had no server-side path. Doing it
-- client-side would mean one RPC per row and would silently mark only the page
-- the user happens to be looking at.
--
-- Widening a RETURNS TABLE signature requires DROP + CREATE; PostgreSQL cannot
-- change a function's result type in place. Nothing else is dropped, and the
-- grants are re-stated exactly as they were: service_role only.
--
-- ONLY exact_date values are carried. Every `last_*_date` column is governed by
-- a CHECK constraint making the date non-NULL exactly when its precision is
-- `exact_date`, so reading the date alone can never leak a year-only or
-- invalid value into a notification (data principle #17).
-- ---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS cng_next_pending_deliveries(notification_channel, integer);

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
  asset_type   asset_type,
  -- Added in 0036. Context the message needs to stand on its own.
  region_name  text,
  unit_name    text,
  asset_serial text,
  last_done_on date,
  days_left    integer
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
         a.asset_type,
         r.name,
         un.unit_name,
         coalesce(irv.serial_number, sv.serial_number, rt.serial_number,
                  gd.serial_number, ho.serial_number),
         coalesce(irv.last_calibration_date, sv.last_inspection_date,
                  rt.last_inspection_date, gd.last_calibration_date,
                  ho.last_test_date),
         (a.due_date - cng_business_date())
    FROM claimed c
    JOIN notification_deliveries d ON d.id = c.id
    JOIN alerts a     ON a.id = d.alert_id
    JOIN app_users u  ON u.id = d.app_user_id
    LEFT JOIN stations s ON s.id = a.station_id
    LEFT JOIN regions  r ON r.id = a.region_id
    LEFT JOIN units   un ON un.id = a.unit_id
    LEFT JOIN push_subscriptions ps
           ON ps.app_user_id = d.app_user_id AND ps.is_active
    LEFT JOIN installed_relief_valves irv ON a.asset_type = 'installed_relief_valve' AND irv.id = a.asset_id
    LEFT JOIN storage_vessels        sv  ON a.asset_type = 'storage_vessel'         AND sv.id  = a.asset_id
    LEFT JOIN recovery_tanks         rt  ON a.asset_type = 'recovery_tank'          AND rt.id  = a.asset_id
    LEFT JOIN gas_detectors          gd  ON a.asset_type = 'gas_detector'           AND gd.id  = a.asset_id
    LEFT JOIN hoses                  ho  ON a.asset_type = 'hose'                   AND ho.id  = a.asset_id
   ORDER BY d.attempted_at;
END $$;

COMMENT ON FUNCTION cng_next_pending_deliveries(notification_channel, integer) IS
  'Claims pending deliveries for the sender, with the context a message needs: Region, Unit, serial, last completed date and live days-left. Only exact_date values can appear. service_role only.';

REVOKE ALL ON FUNCTION cng_next_pending_deliveries(notification_channel, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_next_pending_deliveries(notification_channel, integer) TO service_role;

-- The web_push claim function gets the same context, keeping one delivery row
-- per user however many browsers they have (0035).
DROP FUNCTION IF EXISTS cng_next_pending_push_deliveries(integer);

CREATE FUNCTION cng_next_pending_push_deliveries(p_limit integer DEFAULT 50)
RETURNS TABLE (
  delivery_id   uuid,
  alert_id      uuid,
  subscriptions jsonb,
  subject       alert_subject,
  threshold     alert_threshold,
  due_date      date,
  station_name  text,
  asset_type    asset_type,
  region_name   text,
  unit_name     text,
  asset_serial  text,
  last_done_on  date,
  days_left     integer
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
         coalesce(subs.list, '[]'::jsonb),
         a.subject, a.threshold, a.due_date,
         s.station_name,
         a.asset_type,
         r.name,
         un.unit_name,
         coalesce(irv.serial_number, sv.serial_number, rt.serial_number,
                  gd.serial_number, ho.serial_number),
         coalesce(irv.last_calibration_date, sv.last_inspection_date,
                  rt.last_inspection_date, gd.last_calibration_date,
                  ho.last_test_date),
         (a.due_date - cng_business_date())
    FROM claimed c
    JOIN notification_deliveries d ON d.id = c.id
    JOIN alerts a    ON a.id = d.alert_id
    LEFT JOIN stations s ON s.id = a.station_id
    LEFT JOIN regions  r ON r.id = a.region_id
    LEFT JOIN units   un ON un.id = a.unit_id
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(jsonb_build_object(
               'endpoint', ps.endpoint,
               'p256dh',   ps.p256dh,
               'auth',     ps.auth)) AS list
        FROM push_subscriptions ps
       WHERE ps.app_user_id = d.app_user_id
         AND ps.is_active
    ) subs ON true
    LEFT JOIN installed_relief_valves irv ON a.asset_type = 'installed_relief_valve' AND irv.id = a.asset_id
    LEFT JOIN storage_vessels        sv  ON a.asset_type = 'storage_vessel'         AND sv.id  = a.asset_id
    LEFT JOIN recovery_tanks         rt  ON a.asset_type = 'recovery_tank'          AND rt.id  = a.asset_id
    LEFT JOIN gas_detectors          gd  ON a.asset_type = 'gas_detector'           AND gd.id  = a.asset_id
    LEFT JOIN hoses                  ho  ON a.asset_type = 'hose'                   AND ho.id  = a.asset_id
   ORDER BY d.attempted_at;
END $$;

COMMENT ON FUNCTION cng_next_pending_push_deliveries(integer) IS
  'As cng_next_pending_deliveries, for web_push: one row per DELIVERY with the owning user''s active subscriptions aggregated, plus message context. service_role only.';

REVOKE ALL ON FUNCTION cng_next_pending_push_deliveries(integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_next_pending_push_deliveries(integer) TO service_role;

-- ---------------------------------------------------------------------------
-- Mark every alert the CALLER can see as read.
--
-- SECURITY INVOKER, exactly like cng_mark_alert_read: the alerts_select policy
-- decides which rows exist for this caller, so the set can never reach beyond
-- their own Regions. Reading is not acknowledgement and this touches neither
-- `state`, `acknowledged_by` nor `acknowledged_at` — it only inserts into
-- alert_reads, whose RLS already confines a row to its own owner.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_mark_all_alerts_read()
RETURNS integer
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := cng_current_app_user_id();
  v_n    integer;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no active application user';
  END IF;
  WITH inserted AS (
    INSERT INTO alert_reads (alert_id, app_user_id)
    SELECT a.id, v_user FROM alerts a
    ON CONFLICT (alert_id, app_user_id) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_n FROM inserted;
  RETURN v_n;
END $$;

COMMENT ON FUNCTION cng_mark_all_alerts_read() IS
  'Marks every alert VISIBLE TO THE CALLER as read. SECURITY INVOKER, so alerts_select bounds the set to the caller''s Regions. Read is not acknowledgement: state, acknowledged_by and acknowledged_at are never touched.';

REVOKE ALL ON FUNCTION cng_mark_all_alerts_read() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_mark_all_alerts_read() TO authenticated;
