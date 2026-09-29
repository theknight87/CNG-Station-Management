-- SRV issue undo, and the SRV Log movements Issue / Awaiting return / Return (owner report and request 2026-09-29).
--
-- THE DEFECT. "Back to its station" on an SRV Log entry reinstated the REPLACED valve but left the issue itself in
-- place, so the ISSUED valve stayed installed at the same Unit: the Station showed two valves in one position
-- (production: 260328 reinstated at ابو المطامير كتكوت while 255832 stayed installed there). The two halves of a
-- replacement are one decision and are now undone together.
--
-- (1) cng_srv_issue_undo(issue, action) — admin only, SECURITY DEFINER, actor derived server-side, audited:
--       the replaced valve goes back to its position (its open SRV Log entry is closed as archived); the issued
--       valve leaves the Station, and the admin says where it is:
--         'to_stock'      it never left / is already back: warehouse stock again with the status it had before the
--                         issue (read from the issue's own audit row), same record, same serial and code;
--         'await_return'  it is still at the Station: it goes to the SRV Log (reason 'issue_undone') until it is
--                         received like any other valve.
--       The issue is marked cancelled (cancelled_at / cancelled_by / cancel_action), never deleted. It is refused
--       when the replaced valve is already back in the warehouse (reinstating it would put one serial in two places)
--       and when the issued valve has already left the "sent to station" state.
-- (2) cng_srv_log_restore_to_station refuses an entry that belongs to an issue, and says to undo the issue instead,
--     so an open browser tab cannot create the duplicate again. Its grants are unchanged.
-- (3) v_srv_issue_log: the Issue movement — every issued valve with where its replaced valve is (awaiting return,
--     returned, none, entry removed). Rows are HIDDEN, never deleted, once they are older than six months and
--     nothing is still awaited. security_invoker, so srv_issues' own RLS bounds it.
-- (4) v_srv_field_log: status 'at_station' also for 'issue_undone'; issue_cancelled appended. v_srv_emergency: a
--     cancelled issue leaves the list. Both restated verbatim otherwise (md5 723d009b..., 9383ef3c..., identical
--     locally and in production), security_invoker restated.

ALTER TABLE srv_issues
  ADD COLUMN IF NOT EXISTS cancelled_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS cancelled_by uuid NULL REFERENCES app_users(id),
  ADD COLUMN IF NOT EXISTS cancel_action text NULL;
ALTER TABLE srv_issues ADD CONSTRAINT si_cancel_action_ck CHECK (cancel_action IN ('to_stock', 'await_return'));
ALTER TABLE srv_issues ADD CONSTRAINT si_cancelled_shape_ck
  CHECK ((cancelled_at IS NULL) = (cancelled_by IS NULL) AND (cancelled_at IS NULL) = (cancel_action IS NULL));

ALTER TABLE srv_field_log DROP CONSTRAINT srv_field_log_reason_check;
ALTER TABLE srv_field_log ADD CONSTRAINT srv_field_log_reason_check
  CHECK (reason IN ('replaced_on_issue', 'reconcile_other_serial', 'reconcile_station_not_found', 'issue_undone'));
-- An 'issue_undone' entry names its issue and carries the WAREHOUSE record (the valve's own stock row).
ALTER TABLE srv_field_log ADD CONSTRAINT sfl_issue_undone_shape_ck
  CHECK (reason <> 'issue_undone' OR (issue_id IS NOT NULL AND warehouse_valve_id IS NOT NULL));

ALTER TABLE srv_history DROP CONSTRAINT srv_history_event_check;
ALTER TABLE srv_history ADD CONSTRAINT srv_history_event_check
  CHECK (event IN ('issued', 'replaced', 'logged', 'received', 'sent_to_calibration', 'returned_from_calibration',
                   'certified', 'code_corrected', 'issue_undone'));

-- (4) The SRV Log view.
CREATE OR REPLACE VIEW v_srv_field_log WITH (security_invoker = true) AS
 SELECT l.id,
    l.reason,
        CASE
            WHEN (l.returned_at IS NOT NULL) THEN 'returned'::text
            WHEN (l.reason = ANY (ARRAY['replaced_on_issue'::text, 'issue_undone'::text])) THEN 'at_station'::text
            ELSE 'location_unconfirmed'::text
        END AS status,
    l.is_emergency,
    l.issue_id,
    l.installed_valve_id,
    l.warehouse_valve_id,
    l.region_id,
    r.name AS region_name,
    l.station_id,
    s.station_name,
    l.station_name_raw,
    COALESCE(s.station_name, l.station_name_raw) AS station_display,
    l.unit_id,
    u.unit_name,
    COALESCE(i.serial_number, w.serial_number) AS serial_number,
    COALESCE(i.manufacturer, w.manufacturer) AS manufacturer,
    COALESCE(i.part_number, w.part_number) AS part_number,
    COALESCE(i.warehouse_code, w.warehouse_code) AS warehouse_code,
    COALESCE(i.size_type, w.size_type) AS size_type,
    COALESCE(i.inlet_size, w.inlet_size) AS inlet_size,
    COALESCE(i.outlet_size, w.outlet_size) AS outlet_size,
    COALESCE(i.set_pressure_raw, w.set_pressure_raw) AS set_pressure_raw,
    COALESCE(i.pressure_min, w.pressure_min) AS pressure_min,
    COALESCE(i.pressure_max, w.pressure_max) AS pressure_max,
    COALESCE(i.pressure_unit, w.pressure_unit) AS pressure_unit,
    w.warehouse_issue_date,
    l.logged_at,
    l.returned_at,
    l.returned_warehouse_valve_id,
    (si.cancelled_at IS NOT NULL) AS issue_cancelled
   FROM ((((((srv_field_log l
     LEFT JOIN installed_relief_valves i ON ((i.id = l.installed_valve_id)))
     LEFT JOIN warehouse_relief_valves w ON ((w.id = l.warehouse_valve_id)))
     LEFT JOIN regions r ON ((r.id = l.region_id)))
     LEFT JOIN stations s ON ((s.id = l.station_id)))
     LEFT JOIN units u ON ((u.id = l.unit_id)))
     LEFT JOIN srv_issues si ON ((si.id = l.issue_id)))
  WHERE (l.archived_at IS NULL);

CREATE OR REPLACE VIEW v_srv_emergency WITH (security_invoker = true) AS
 SELECT e.id,
    e.issued_at,
    e.notes,
    e.region_id,
    r.name AS region_name,
    e.station_id,
    s.station_name,
    e.unit_id,
    u.unit_name,
    e.warehouse_valve_id,
    w.serial_number AS issued_serial,
    w.warehouse_code AS issued_code,
    w.pressure_min,
    w.pressure_max,
    w.pressure_unit,
    w.set_pressure_raw,
    e.replaced_installed_valve_id,
    o.serial_number AS replaced_serial,
    o.warehouse_code AS replaced_code,
    l.id AS log_id,
        CASE
            WHEN (l.id IS NULL) THEN NULL::text
            WHEN (l.returned_at IS NOT NULL) THEN 'returned'::text
            ELSE 'at_station'::text
        END AS replaced_status,
    w.serial_number,
    w.manufacturer,
    w.size_type,
    w.inlet_size,
    w.outlet_size
   FROM ((((((srv_issues e
     JOIN regions r ON ((r.id = e.region_id)))
     JOIN stations s ON ((s.id = e.station_id)))
     JOIN units u ON ((u.id = e.unit_id)))
     JOIN warehouse_relief_valves w ON ((w.id = e.warehouse_valve_id)))
     LEFT JOIN installed_relief_valves o ON ((o.id = e.replaced_installed_valve_id)))
     LEFT JOIN srv_field_log l ON (((l.issue_id = e.id) AND (l.archived_at IS NULL))))
  WHERE (e.is_emergency AND (e.emergency_removed_at IS NULL) AND (e.cancelled_at IS NULL));

-- (3) The Issue movement.
CREATE OR REPLACE VIEW v_srv_issue_log WITH (security_invoker = true) AS
SELECT e.id,
       CASE
         WHEN e.replaced_installed_valve_id IS NULL THEN 'no_replacement'
         WHEN l.id IS NULL THEN 'replaced_entry_removed'
         WHEN l.returned_at IS NULL THEN 'awaiting_replaced'
         ELSE 'replaced_returned'
       END AS status,
       e.issued_at, e.is_emergency, e.notes,
       e.region_id, r.name AS region_name, e.station_id, s.station_name, e.unit_id, u.unit_name,
       e.warehouse_valve_id, e.new_installed_valve_id,
       w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.serial_number, w.manufacturer, w.part_number, w.size_type, w.inlet_size, w.outlet_size,
       w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       e.replaced_installed_valve_id, o.serial_number AS replaced_serial, o.warehouse_code AS replaced_code,
       l.id AS replaced_log_id, l.returned_at AS replaced_returned_at
  FROM srv_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  JOIN units u ON u.id = e.unit_id
  JOIN warehouse_relief_valves w ON w.id = e.warehouse_valve_id
  LEFT JOIN installed_relief_valves o ON o.id = e.replaced_installed_valve_id
  LEFT JOIN srv_field_log l ON l.issue_id = e.id AND l.reason = 'replaced_on_issue'
                           AND l.installed_valve_id = e.replaced_installed_valve_id AND l.archived_at IS NULL
 WHERE e.cancelled_at IS NULL
   AND (e.issued_at >= now() - interval '6 months' OR (l.id IS NOT NULL AND l.returned_at IS NULL));

COMMENT ON VIEW v_srv_issue_log IS
  'SRV Log "Issue" movement: issued valves and whether the valve each replaced is back. Cancelled issues are left out; finished issues older than six months are hidden, never deleted (srv_issues, srv_history and audit_logs keep them).';
GRANT SELECT ON v_srv_issue_log TO authenticated;
REVOKE ALL ON v_srv_issue_log FROM anon;

-- (1) Undo an issue.
CREATE OR REPLACE FUNCTION cng_srv_issue_undo(p_issue_id uuid, p_issued_action text, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  e srv_issues; w warehouse_relief_valves; o installed_relief_valves; l srv_field_log;
  v_prior warehouse_availability; v_log uuid; s_name text; u_name text;
BEGIN
  IF p_issued_action IS NULL OR p_issued_action NOT IN ('to_stock', 'await_return') THEN
    RAISE EXCEPTION 'choose what happens to the issued valve: back to warehouse stock, or awaiting return in the SRV Log'
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM srv_issues WHERE id = p_issue_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'issue not found' USING ERRCODE = '42704'; END IF;
  IF e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'this issue was already undone; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT station_name INTO s_name FROM stations WHERE id = e.station_id;
  SELECT unit_name INTO u_name FROM units WHERE id = e.unit_id;

  SELECT * INTO w FROM warehouse_relief_valves WHERE id = e.warehouse_valve_id FOR UPDATE;
  IF w.availability_status IS DISTINCT FROM 'sent_to_station_received' THEN
    RAISE EXCEPTION 'the issued valve % is no longer recorded as at the station (it is %); nothing was changed',
      coalesce(w.serial_number, '(no serial)'), w.availability_status USING ERRCODE = 'PT409';
  END IF;

  -- The replaced valve goes back to its position.
  IF e.replaced_installed_valve_id IS NOT NULL THEN
    SELECT * INTO o FROM installed_relief_valves WHERE id = e.replaced_installed_valve_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM srv_field_log WHERE issue_id = e.id AND reason = 'replaced_on_issue'
                  AND installed_valve_id = o.id AND archived_at IS NULL AND returned_at IS NOT NULL) THEN
      RAISE EXCEPTION 'the replaced valve % is already back in the warehouse; issue it again from the warehouse instead',
        coalesce(o.serial_number, '(no serial)') USING ERRCODE = 'PT409';
    END IF;
    UPDATE srv_field_log SET archived_at = now(), archived_by = v_actor
     WHERE issue_id = e.id AND reason = 'replaced_on_issue' AND installed_valve_id = o.id
       AND archived_at IS NULL AND returned_at IS NULL;
    UPDATE installed_relief_valves SET archived_at = NULL, archived_by = NULL WHERE id = o.id AND archived_at IS NOT NULL;
    INSERT INTO srv_history (installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (o.id, e.region_id, 'issue_undone', format('Back in its position at %s / %s: the issue that replaced it was undone', s_name, u_name),
            jsonb_build_object('issue_id', e.id), v_actor);
  END IF;

  -- The issued valve leaves the Station.
  UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor
   WHERE id = e.new_installed_valve_id AND archived_at IS NULL;
  IF p_issued_action = 'to_stock' THEN
    SELECT (a.before_data->>'availability_status')::warehouse_availability INTO v_prior
      FROM audit_logs a WHERE a.entity_table = 'srv_issues' AND a.entity_id = e.id AND a.actor_label = 'srv_issue'
     ORDER BY a.occurred_at LIMIT 1;
    IF v_prior IS NULL OR v_prior NOT IN ('available_new', 'available_calibrated') THEN
      v_prior := CASE WHEN w.last_calibration_date IS NOT NULL THEN 'available_calibrated' ELSE 'available_new' END;
    END IF;
    UPDATE warehouse_relief_valves
       SET availability_status = v_prior, target_region_id = NULL, target_station_id = NULL,
           warehouse_issue_date = NULL, warehouse_issue_precision = 'unknown', warehouse_issue_raw = NULL
     WHERE id = w.id;
    INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (w.id, e.new_installed_valve_id, e.region_id, 'issue_undone',
            format('Issue to %s / %s undone: back in warehouse stock as it was', s_name, u_name),
            jsonb_build_object('issue_id', e.id, 'availability_status', v_prior), v_actor);
  ELSE
    v_log := gen_random_uuid();
    INSERT INTO srv_field_log (id, reason, issue_id, warehouse_valve_id, region_id, station_id, unit_id, is_emergency, logged_by)
    VALUES (v_log, 'issue_undone', e.id, w.id, e.region_id, e.station_id, e.unit_id, false, v_actor);
    INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (w.id, e.new_installed_valve_id, e.region_id, 'issue_undone',
            format('Issue to %s / %s undone: still at the station, in the SRV Log awaiting return', s_name, u_name),
            jsonb_build_object('issue_id', e.id, 'log_id', v_log), v_actor);
  END IF;

  UPDATE srv_issues SET cancelled_at = now(), cancelled_by = v_actor, cancel_action = p_issued_action WHERE id = e.id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_issues', e.id, v_actor, 'srv_issue_undo',
          format('SRV issue of %s to %s / %s undone%s; issued valve %s. %s', coalesce(w.serial_number, w.id::text), s_name, u_name,
                 CASE WHEN o.id IS NOT NULL THEN ', ' || coalesce(o.serial_number, o.id::text) || ' back in its position' ELSE '' END,
                 CASE p_issued_action WHEN 'to_stock' THEN 'back in warehouse stock' ELSE 'awaiting return in the SRV Log' END,
                 coalesce(p_reason, '')),
          jsonb_build_object('availability_status', w.availability_status, 'new_installed_valve_id', e.new_installed_valve_id,
                             'replaced_installed_valve_id', e.replaced_installed_valve_id),
          jsonb_build_object('cancel_action', p_issued_action, 'availability_status',
                             (SELECT availability_status FROM warehouse_relief_valves WHERE id = w.id), 'log_id', v_log), now());
END; $$;

REVOKE ALL ON FUNCTION cng_srv_issue_undo(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_issue_undo(uuid, text, text) TO authenticated;

-- (2) Restore-to-station refuses an issue's entry.
CREATE OR REPLACE FUNCTION cng_srv_log_restore_to_station(p_log_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); l srv_field_log;
BEGIN
  SELECT * INTO l FROM srv_field_log WHERE id = p_log_id AND archived_at IS NULL AND returned_at IS NULL FOR UPDATE;
  IF l.id IS NULL THEN RAISE EXCEPTION 'this log entry is no longer open; reload the list' USING ERRCODE = 'PT409'; END IF;
  IF l.issue_id IS NOT NULL THEN
    -- Reinstating only the replaced valve would leave the issued one installed in the same position (2026-09-29).
    RAISE EXCEPTION 'this valve was replaced by an issue; undo the issue instead, so the issued valve is not left at the station too'
      USING ERRCODE = 'PT409';
  END IF;
  IF l.installed_valve_id IS NULL THEN
    RAISE EXCEPTION 'this entry has no installed record to put back; move it to a station instead' USING ERRCODE = '22023';
  END IF;
  UPDATE installed_relief_valves SET archived_at = NULL, archived_by = NULL WHERE id = l.installed_valve_id;
  UPDATE srv_field_log SET archived_at = now(), archived_by = v_actor WHERE id = p_log_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_restored', 'installed_relief_valves', l.installed_valve_id, v_actor, 'admin_srv_log',
          format('Valve returned to its station from the SRV Log (log entry archived). %s', coalesce(p_reason, '')),
          to_jsonb(l), jsonb_build_object('installed_valve_id', l.installed_valve_id, 'station_id', l.station_id, 'unit_id', l.unit_id), now());
END; $$;
