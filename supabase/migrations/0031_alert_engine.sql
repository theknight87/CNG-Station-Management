-- ---------------------------------------------------------------------------
-- 0031 — Alert engine (Prompt 15). Additive only.
--
-- WHAT ALREADY EXISTED, and is NOT rebuilt here: `alert_rules` (30 rows = 5
-- subjects x 6 thresholds, verified empirically), `alerts` with its
-- `alerts_dedupe_uq UNIQUE (asset_type, asset_id, threshold, due_date)`,
-- `notification_preferences`, `push_subscriptions` and
-- `notification_deliveries` — all from 0009. `cng_business_date()` already
-- returns the Africa/Cairo calendar date.
--
-- WHAT WAS MISSING, and is added here:
--   1. read state. `alert_state` is open/acknowledged/resolved/suppressed —
--      an OPERATIONAL lifecycle with no notion of "I have seen this". Read and
--      acknowledged are different facts, so read state gets its own per-user
--      table rather than being folded into the shared state column.
--   2. a safe acknowledgement path. `authenticated` holds SELECT on `alerts`
--      and no UPDATE grant, so acknowledgement was impossible; granting UPDATE
--      would have let a client write `acknowledged_by` to any value it liked.
--   3. server-side generation. No generation function existed at all.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- alert_reads — PER-USER read state.
--
-- Read is a per-user fact, not a property of the alert. One manager opening an
-- alert must not silently mark it read for every other engineer, so this is a
-- row per (alert, user) rather than a flag on `alerts`. Acknowledgement, which
-- IS a shared operational fact, stays on the alert itself.
-- ---------------------------------------------------------------------------
CREATE TABLE alert_reads (
  alert_id     uuid NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
  app_user_id  uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  read_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (alert_id, app_user_id)
);

COMMENT ON TABLE alert_reads IS
  'Per-user read state. Read is not acknowledgement: reading is "I have seen this notification", acknowledging is an explicit operational act recorded on the alert with a server-derived actor.';

CREATE INDEX alert_reads_user_idx ON alert_reads (app_user_id);

ALTER TABLE alert_reads ENABLE ROW LEVEL SECURITY;
ALTER TABLE alert_reads FORCE ROW LEVEL SECURITY;

-- A user reads, writes and clears ONLY their own read state. The WITH CHECK
-- half matters as much as the USING half: without it a permitted row could be
-- rewritten to carry another user's id.
CREATE POLICY alert_reads_select ON alert_reads FOR SELECT TO authenticated
  USING (app_user_id = cng_current_app_user_id());
CREATE POLICY alert_reads_insert ON alert_reads FOR INSERT TO authenticated
  WITH CHECK (app_user_id = cng_current_app_user_id());
CREATE POLICY alert_reads_delete ON alert_reads FOR DELETE TO authenticated
  USING (app_user_id = cng_current_app_user_id());

GRANT SELECT, INSERT, DELETE ON alert_reads TO authenticated;

-- ---------------------------------------------------------------------------
-- cng_mark_alert_read / cng_mark_alert_unread
--
-- SECURITY INVOKER on purpose. These need no elevated privilege, so they get
-- none: the `SELECT 1 FROM alerts` runs under the caller's own RLS, which means
-- an alert the caller may not see is reported as not found rather than
-- becoming an existence oracle. Writing read state directly against the table
-- would leak that oracle through a foreign-key error instead.
--
-- The actor is never a parameter — it comes from the session (CLAUDE.md §10).
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_mark_alert_read(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE v_user uuid := cng_current_app_user_id();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no active application user';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM alerts a WHERE a.id = p_alert_id) THEN
    RAISE EXCEPTION 'alert not found';
  END IF;
  INSERT INTO alert_reads (alert_id, app_user_id)
  VALUES (p_alert_id, v_user)
  ON CONFLICT (alert_id, app_user_id) DO NOTHING;
END $$;

CREATE FUNCTION cng_mark_alert_unread(p_alert_id uuid)
RETURNS void
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
DECLARE v_user uuid := cng_current_app_user_id();
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no active application user';
  END IF;
  DELETE FROM alert_reads WHERE alert_id = p_alert_id AND app_user_id = v_user;
END $$;

REVOKE ALL ON FUNCTION cng_mark_alert_read(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_mark_alert_unread(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_mark_alert_read(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION cng_mark_alert_unread(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- cng_acknowledge_alert — the ONLY way an alert becomes acknowledged.
--
-- WHY SECURITY DEFINER IS GENUINELY REQUIRED HERE. `authenticated` holds SELECT
-- on `alerts` and deliberately NO UPDATE grant, and none is added. If UPDATE
-- were granted, a client could set `acknowledged_by` to any user id and
-- `acknowledged_at` to any timestamp — exactly the forgeable attribution that
-- CLAUDE.md §9 and §10 forbid. Routing the write through a definer function
-- means the actor and the timestamp are taken from the server and cannot be
-- supplied by the caller.
--
-- The safeguards that make that safe:
--   * no user-supplied identity parameter — the actor is cng_current_app_user_id()
--   * pinned search_path
--   * EXECUTE granted to `authenticated` only, never to anon
--   * it RE-CHECKS authorization itself, because definer rights bypass RLS.
--     The predicate is the same one `alerts_update` uses, so the function
--     cannot become a way round the policy.
--   * re-acknowledging is a no-op, so the FIRST actor is preserved and the
--     record cannot be quietly reattributed to someone else.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_acknowledge_alert(p_alert_id uuid)
RETURNS TABLE (alert_id uuid, acknowledged_by uuid, acknowledged_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_user uuid := cng_current_app_user_id();
  v_row  alerts%ROWTYPE;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'no active application user';
  END IF;

  SELECT * INTO v_row FROM alerts a WHERE a.id = p_alert_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'alert not found';
  END IF;

  -- Definer rights bypassed RLS to read that row, so authorization is checked
  -- explicitly, mirroring the alerts_update policy exactly.
  IF NOT (
    CASE
      WHEN v_row.station_id IS NOT NULL THEN EXISTS (
        SELECT 1 FROM stations s
         WHERE s.id = v_row.station_id AND cng_can_write_region(s.region_id))
      ELSE cng_can_access_unmapped_srv()
    END
  ) THEN
    -- Worded so it cannot distinguish "exists but forbidden" from "absent".
    RAISE EXCEPTION 'alert not found';
  END IF;

  -- Already acknowledged: keep the original actor and time.
  IF v_row.acknowledged_at IS NOT NULL THEN
    RETURN QUERY SELECT v_row.id, v_row.acknowledged_by, v_row.acknowledged_at;
    RETURN;
  END IF;

  UPDATE alerts a
     SET state = 'acknowledged',
         acknowledged_by = v_user,   -- server-derived
         acknowledged_at = now()     -- server-derived
   WHERE a.id = p_alert_id
   RETURNING a.id, a.acknowledged_by, a.acknowledged_at
   INTO v_row.id, v_row.acknowledged_by, v_row.acknowledged_at;

  RETURN QUERY SELECT v_row.id, v_row.acknowledged_by, v_row.acknowledged_at;
END $$;

REVOKE ALL ON FUNCTION cng_acknowledge_alert(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_acknowledge_alert(uuid) TO authenticated;

-- ---------------------------------------------------------------------------
-- cng_generate_alerts — idempotent, server-side alert generation.
--
-- ELIGIBILITY. An asset is alertable only when it has an EXACT next due date.
-- `*_precision = 'exact_date'` is required, so a year-only date such as "2027"
-- can never produce a countdown alert and is never turned into 1 January or
-- 31 December (principle #17). Unknown and invalid precisions are excluded by
-- the same test. Excel "Days Left" is not consulted anywhere.
--
-- THRESHOLD SEMANTICS (prompt §12). A countdown alert fires on the EXACT
-- calendar day the condition is met: days_left = 60/30/15/7, or 0 for
-- due_today. This is what stops the first run against an already-overdue asset
-- from back-filling every threshold it passed months ago — an asset 45 days
-- overdue matches `overdue` and nothing else.
--
-- OVERDUE (prompt §13). `overdue` fires for any negative days_left, but
-- `alerts_dedupe_uq` keys on (asset_type, asset_id, threshold, due_date), so
-- one overdue alert exists per DUE-DATE CYCLE — not one per scheduler run. When
-- the asset is re-tested and its next due date moves, that is a new cycle and
-- may raise its own alert; the historical one is untouched (prompt §15).
--
-- CONCURRENCY (prompt §43). Idempotency is enforced by the database, not by
-- read-then-write in application code: `ON CONFLICT DO NOTHING` against the
-- unique constraint. Two overlapping cron runs cannot create a duplicate.
--
-- WHY SECURITY DEFINER. `service_role` deliberately holds SELECT on `app_users`
-- and nothing else (migration 0024), so the scheduler has no privilege to read
-- assets or write alerts. Rather than granting it broad table access, it gets
-- EXECUTE on this one narrow function. EXECUTE is NOT granted to
-- `authenticated`: alert generation is not a user action, and exposing it would
-- let any signed-in browser drive the scheduler.
--
-- AN UNRESOLVED STATION IS STILL ALERTABLE. Migration 0015 deliberately
-- dropped NOT NULL from `alerts.station_id` and added `source_station_name_raw`
-- and `needs_station_mapping`, precisely so an installed SRV whose canonical
-- Station is not yet confirmed can still be tracked: an exact due date is
-- enough to know a calibration is coming due, and no Station is fabricated to
-- make the alert possible. Such an alert carries the RAW source station name so
-- it names a place without asserting a canonical one.
--
-- That raw context is sensitive. `alerts_select` routes station-unconfirmed
-- rows through `cng_can_access_unmapped_srv()` rather than region scoping,
-- because an unconfirmed `region_id` is evidence, not permission
-- (CLAUDE.md §10) - so those alerts are admin/manager only.
--
-- Only SRVs reach this state: `station_id` is NOT NULL on vessels, detectors
-- and hoses, so their staged needs_station_mapping rows cannot exist as
-- canonical assets at all (the Prompt-21 blockers) and therefore cannot
-- generate alerts either.
-- ---------------------------------------------------------------------------
CREATE FUNCTION cng_generate_alerts(p_as_of date DEFAULT NULL)
RETURNS TABLE (as_of date, created integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_as_of date := coalesce(p_as_of, cng_business_date());  -- Africa/Cairo
  v_created integer;
BEGIN
  WITH eligible AS (
    SELECT 'srv_calibration'::alert_subject AS subject,
           'installed_relief_valve'::asset_type AS asset_type,
           v.id AS asset_id, v.region_id, v.station_id, v.unit_id,
           v.next_calibration_date AS due_date,
           (v.mapping_status <> 'resolved') AS needs_mapping,
           -- Carried only for the station-unconfirmed case, so the alert can
           -- name a place without inventing a canonical Station.
           v.source_station_name_raw,
           (v.station_id IS NULL) AS needs_station_mapping
      FROM installed_relief_valves v
     WHERE v.archived_at IS NULL
       AND v.next_calibration_precision = 'exact_date'
       AND v.next_calibration_date IS NOT NULL

    UNION ALL
    SELECT 'storage_inspection', 'storage_vessel', sv.id, sv.region_id, sv.station_id, sv.unit_id,
           sv.next_inspection_date, (sv.mapping_status <> 'resolved'), NULL, false
      FROM storage_vessels sv
     WHERE sv.archived_at IS NULL
       AND sv.next_inspection_precision = 'exact_date'
       AND sv.next_inspection_date IS NOT NULL

    UNION ALL
    SELECT 'recovery_tank_inspection', 'recovery_tank', rt.id, rt.region_id, rt.station_id, rt.unit_id,
           rt.next_inspection_date, (rt.mapping_status <> 'resolved'), NULL, false
      FROM recovery_tanks rt
     WHERE rt.archived_at IS NULL
       AND rt.next_inspection_precision = 'exact_date'
       AND rt.next_inspection_date IS NOT NULL

    UNION ALL
    SELECT 'gas_detector_calibration', 'gas_detector', g.id, g.region_id, g.station_id, g.unit_id,
           g.next_calibration_date, (g.mapping_status <> 'resolved'), NULL, false
      FROM gas_detectors g
     WHERE g.archived_at IS NULL
       AND g.next_calibration_precision = 'exact_date'
       AND g.next_calibration_date IS NOT NULL

    UNION ALL
    SELECT 'hose_hydrotest', 'hose', h.id, h.region_id, h.station_id, h.unit_id,
           h.next_test_date, (h.mapping_status <> 'resolved'), NULL, false
      FROM hoses h
     WHERE h.archived_at IS NULL
       AND h.next_test_precision = 'exact_date'
       AND h.next_test_date IS NOT NULL
  ),
  inserted AS (
    INSERT INTO alerts (alert_rule_id, subject, threshold, asset_type, asset_id,
                        region_id, station_id, unit_id, due_date, days_left,
                        needs_mapping, source_station_name_raw, needs_station_mapping)
    SELECT r.id, e.subject, r.threshold, e.asset_type, e.asset_id,
           e.region_id, e.station_id, e.unit_id, e.due_date,
           (e.due_date - v_as_of), e.needs_mapping,
           e.source_station_name_raw, e.needs_station_mapping
      FROM eligible e
      JOIN alert_rules r
        ON r.subject = e.subject
       AND r.is_enabled
     WHERE (r.threshold IN ('due_60','due_30','due_15','due_7')
              AND (e.due_date - v_as_of) = r.days_before)
        OR (r.threshold = 'due_today' AND (e.due_date - v_as_of) = 0)
        OR (r.threshold = 'overdue'   AND (e.due_date - v_as_of) < 0)
    ON CONFLICT (asset_type, asset_id, threshold, due_date) DO NOTHING
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_created FROM inserted;

  RETURN QUERY SELECT v_as_of, v_created;
END $$;

REVOKE ALL ON FUNCTION cng_generate_alerts(date) FROM PUBLIC;
-- Deliberately NOT granted to `authenticated`: generation is a scheduled
-- server task, not a user action.
GRANT EXECUTE ON FUNCTION cng_generate_alerts(date) TO service_role;

-- ---------------------------------------------------------------------------
-- v_alert_inbox — the operational inbox.
--
-- `security_invoker`, so `alerts_select` decides every row: an alert outside
-- the caller's regions is ABSENT, not hidden. The per-user read flag and the
-- delivery status are the CALLER'S own — `notification_deliveries` is scoped to
-- `app_user_id = cng_current_app_user_id()`, so one user's delivery failure is
-- never visible as another's.
--
-- `days_left` here is computed LIVE from the due date against the Cairo
-- business date. The stored `alerts.days_left` is a generation-time snapshot
-- used only for the notification body, and is deliberately not what the inbox
-- shows.
-- ---------------------------------------------------------------------------
CREATE VIEW v_alert_inbox
WITH (security_invoker = true) AS
SELECT
  a.id,
  a.subject,
  a.threshold,
  a.state,
  a.asset_type,
  a.asset_id,
  a.region_id,  r.name AS region_name,
  a.station_id, s.station_name,
  a.needs_station_mapping,
  -- Raw source text, shown only to callers `alerts_select` already admits
  -- (admin/manager for station-unconfirmed rows). It names a place; it is
  -- never a canonical Station and never an authorization boundary.
  a.source_station_name_raw,
  a.unit_id,    u.unit_name,
  a.due_date,
  (a.due_date - cng_business_date())            AS days_left,
  cng_due_status(a.due_date, 'exact_date')      AS due_status,
  a.needs_mapping,
  a.acknowledged_by,
  a.acknowledged_at,
  ack.full_name                                  AS acknowledged_by_name,
  a.resolved_at,
  a.created_at                                   AS generated_at,
  (rd.alert_id IS NOT NULL)                      AS is_read,
  rd.read_at,
  -- The caller's own delivery outcome for this alert, per channel.
  (SELECT d.status FROM notification_deliveries d
    WHERE d.alert_id = a.id AND d.channel = 'email'    LIMIT 1) AS email_status,
  (SELECT d.status FROM notification_deliveries d
    WHERE d.alert_id = a.id AND d.channel = 'web_push' LIMIT 1) AS push_status,
  -- The asset's own identifier, from whichever table owns it. Five LEFT JOINs,
  -- evaluated set-based in one pass — never a per-row lookup.
  coalesce(irv.serial_number, sv.serial_number, rt.serial_number,
           gd.serial_number, ho.serial_number)   AS asset_serial,
  coalesce(irv.serial_status, sv.serial_status, rt.serial_status,
           gd.serial_status, ho.serial_status)   AS asset_serial_status
FROM alerts a
JOIN regions  r ON r.id = a.region_id
-- LEFT, not inner: an alert on a station-unconfirmed SRV has no Station row and
-- must still appear for those authorized to see it.
LEFT JOIN stations s ON s.id = a.station_id
LEFT JOIN units u   ON u.id = a.unit_id
LEFT JOIN app_users ack ON ack.id = a.acknowledged_by
LEFT JOIN alert_reads rd
       ON rd.alert_id = a.id AND rd.app_user_id = cng_current_app_user_id()
LEFT JOIN installed_relief_valves irv ON a.asset_type = 'installed_relief_valve' AND irv.id = a.asset_id
LEFT JOIN storage_vessels        sv  ON a.asset_type = 'storage_vessel'         AND sv.id  = a.asset_id
LEFT JOIN recovery_tanks         rt  ON a.asset_type = 'recovery_tank'          AND rt.id  = a.asset_id
LEFT JOIN gas_detectors          gd  ON a.asset_type = 'gas_detector'           AND gd.id  = a.asset_id
LEFT JOIN hoses                  ho  ON a.asset_type = 'hose'                   AND ho.id  = a.asset_id;

COMMENT ON VIEW v_alert_inbox IS
  'Operational alert inbox. security_invoker, so alerts_select governs visibility. is_read and the delivery statuses are the CALLER''S own; days_left is live against the Africa/Cairo business date, not the generation-time snapshot on alerts.days_left.';

GRANT SELECT ON v_alert_inbox TO authenticated;
