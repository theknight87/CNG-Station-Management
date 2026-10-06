-- 20261006090000_srv_issue_transfer.sql — move an issued SRV from one Station to another (owner request 2026-10-06).
--
-- The case: a valve is issued to Station A in place of a valve there; at the Station they find the old valve is still
-- valid, so it stays, and the issued valve goes straight on to Station B. It never comes back to the warehouse.
--
-- (1) srv_issues.transferred_from_issue_id — the issue at B names the issue at A it came from. cancel_action gains
--     'transferred' (the issue at A is cancelled, never deleted). srv_history gains the event 'transferred'.
-- (2) cng_srv_issue_transfer(issue, unit, replace?, emergency, notes) — admin only, SECURITY DEFINER, pinned
--     search_path, actor derived server-side, audited. One transaction:
--       at A: exactly the undo — the replaced valve goes back to its position (its open SRV Log entry closed), the
--             issued valve's installed record at A is archived, the issue is cancelled as 'transferred';
--       at B: a new issue of the SAME warehouse valve — a new installed record (same rules as cng_srv_issue: in place
--             of a same-pressure valve at B, which goes to the SRV Log, or added), the store record follows it to B,
--             and keeps its original warehouse issue date (it left the warehouse once).
--     Refused (PT409) like the undo when the issued valve is no longer "at the station", when the replaced valve at A
--     is already back in the warehouse, or when the target Unit is the same Unit.
-- (3) The warehouse issue sheet: the valve left the warehouse ONCE, for A. The issue at A stays on its sheet and its
--     return-date cell says where it went ("محول إلى <B>"); the issue at B is not a warehouse exit and is on no sheet.
--     v_srv_issue_sheet restated with two columns APPENDED (transferred_to, transferred_at); is_cancelled keeps its
--     meaning (undone, still at the station). cng_srv_issue_sheet_assign restated with the same filter.

-- (1)
ALTER TABLE srv_issues ADD COLUMN IF NOT EXISTS transferred_from_issue_id uuid NULL REFERENCES srv_issues(id);
CREATE UNIQUE INDEX IF NOT EXISTS si_transferred_from_uq ON srv_issues (transferred_from_issue_id)
  WHERE transferred_from_issue_id IS NOT NULL;
ALTER TABLE srv_issues DROP CONSTRAINT IF EXISTS si_cancel_action_ck;
ALTER TABLE srv_issues ADD CONSTRAINT si_cancel_action_ck CHECK (cancel_action IN ('to_stock', 'await_return', 'transferred'));

ALTER TABLE srv_history DROP CONSTRAINT srv_history_event_check;
ALTER TABLE srv_history ADD CONSTRAINT srv_history_event_check
  CHECK (event IN ('issued', 'replaced', 'logged', 'received', 'sent_to_calibration', 'returned_from_calibration',
                   'certified', 'code_corrected', 'issue_undone', 'transferred'));

-- (2)
CREATE OR REPLACE FUNCTION cng_srv_issue_transfer(p_issue_id uuid, p_unit_id uuid, p_replace_installed_valve_id uuid DEFAULT NULL,
                                                  p_emergency boolean DEFAULT false, p_notes text DEFAULT NULL)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  e srv_issues; w warehouse_relief_valves; a installed_relief_valves; o installed_relief_valves; p installed_relief_valves;
  u units; s stations; s_from text; u_from text;
  v_new uuid := gen_random_uuid();
  v_issue uuid := gen_random_uuid();
  v_status srv_mapping_status := 'needs_equipment_mapping';
  v_notes text := nullif(btrim(p_notes), '');
  v_station_level boolean := false;
BEGIN
  SELECT * INTO e FROM srv_issues WHERE id = p_issue_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'issue not found' USING ERRCODE = '42704'; END IF;
  IF e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'this issue was already undone or moved; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT * INTO w FROM warehouse_relief_valves WHERE id = e.warehouse_valve_id FOR UPDATE;
  IF w.availability_status IS DISTINCT FROM 'sent_to_station_received' THEN
    RAISE EXCEPTION 'the issued valve % is no longer recorded as at the station (it is %); nothing was changed',
      coalesce(w.serial_number, '(no serial)'), w.availability_status USING ERRCODE = 'PT409';
  END IF;
  SELECT * INTO a FROM installed_relief_valves WHERE id = e.new_installed_valve_id FOR UPDATE;
  SELECT station_name INTO s_from FROM stations WHERE id = e.station_id;
  SELECT unit_name INTO u_from FROM units WHERE id = e.unit_id;

  SELECT * INTO u FROM units WHERE id = p_unit_id AND archived_at IS NULL;
  IF u.id IS NULL THEN RAISE EXCEPTION 'unit not found' USING ERRCODE = '42704'; END IF;
  IF u.id = e.unit_id THEN RAISE EXCEPTION 'the valve is already at this Unit; choose another Station or Unit' USING ERRCODE = '22023'; END IF;
  SELECT * INTO s FROM stations WHERE id = u.station_id;

  IF e.replaced_installed_valve_id IS NOT NULL THEN
    SELECT * INTO o FROM installed_relief_valves WHERE id = e.replaced_installed_valve_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM srv_field_log WHERE issue_id = e.id AND reason = 'replaced_on_issue'
                  AND installed_valve_id = o.id AND archived_at IS NULL AND returned_at IS NOT NULL) THEN
      RAISE EXCEPTION 'the replaced valve % is already back in the warehouse, so it cannot stay at %; undo the issue or issue another valve instead',
        coalesce(o.serial_number, '(no serial)'), s_from USING ERRCODE = 'PT409';
    END IF;
    UPDATE srv_field_log SET archived_at = now(), archived_by = v_actor
     WHERE issue_id = e.id AND reason = 'replaced_on_issue' AND installed_valve_id = o.id
       AND archived_at IS NULL AND returned_at IS NULL;
    UPDATE installed_relief_valves SET archived_at = NULL, archived_by = NULL WHERE id = o.id AND archived_at IS NOT NULL;
    INSERT INTO srv_history (installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (o.id, e.region_id, 'issue_undone',
            format('Stays in its position at %s / %s: the valve issued for it was moved to %s', s_from, u_from, s.station_name),
            jsonb_build_object('issue_id', e.id, 'transfer_issue_id', v_issue), v_actor);
  END IF;
  UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = a.id AND archived_at IS NULL;
  UPDATE srv_issues SET cancelled_at = now(), cancelled_by = v_actor, cancel_action = 'transferred' WHERE id = e.id;

  IF p_replace_installed_valve_id IS NOT NULL THEN
    SELECT * INTO p FROM installed_relief_valves WHERE id = p_replace_installed_valve_id AND archived_at IS NULL FOR UPDATE;
    IF p.id IS NULL THEN RAISE EXCEPTION 'the valve to replace was not found or was already removed' USING ERRCODE = 'PT409'; END IF;
    IF NOT EXISTS (SELECT 1 FROM cng_srv_replacement_candidates(u.id, w.id) c WHERE c.id = p.id) THEN
      RAISE EXCEPTION 'the valve to replace is not at this Unit''s Station with the same set pressure' USING ERRCODE = '22023';
    END IF;
    IF p.unit_id IS NULL AND p.mapping_status = 'resolved' THEN
      v_station_level := true;
      v_status := 'resolved';
    ELSIF num_nonnulls(p.compressor_id, p.storage_vessel_id, p.dispenser_id) = 1 AND p.unit_id = u.id THEN
      v_status := 'resolved';
    END IF;
  END IF;

  INSERT INTO installed_relief_valves (
    id, region_id, station_id, unit_id, compressor_id, storage_vessel_id, dispenser_id,
    mapping_status, mapping_note, resolved_by, resolved_at, location_raw, expected_parent_kind,
    manufacturer, manufacturer_raw, serial_number, serial_number_raw, serial_status, part_number,
    size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
    last_calibration_raw, last_calibration_date, last_calibration_precision,
    next_calibration_raw, next_calibration_date, next_calibration_precision,
    notes, warehouse_code)
  VALUES (
    v_new, u.region_id, u.station_id, CASE WHEN v_station_level THEN NULL ELSE u.id END,
    CASE WHEN v_status = 'resolved' THEN p.compressor_id END,
    CASE WHEN v_status = 'resolved' THEN p.storage_vessel_id END,
    CASE WHEN v_status = 'resolved' THEN p.dispenser_id END,
    v_status, format('Moved from %s (issued there, not fitted)', s_from) || CASE WHEN p.id IS NOT NULL THEN ' in place of another valve' ELSE '' END,
    CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
    p.location_raw, p.expected_parent_kind,
    w.manufacturer, w.manufacturer_raw, w.serial_number, w.serial_number_raw, w.serial_status, w.part_number,
    w.size_type, w.inlet_size, w.outlet_size, w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
    w.last_calibration_raw, w.last_calibration_date, w.last_calibration_precision,
    w.next_calibration_raw, w.next_calibration_date, w.next_calibration_precision,
    coalesce(v_notes, a.notes), w.warehouse_code);

  UPDATE warehouse_relief_valves SET target_region_id = u.region_id, target_station_id = u.station_id, target_unit_id = NULL
   WHERE id = w.id;

  INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id,
                          region_id, station_id, unit_id, is_emergency, notes, issued_by, transferred_from_issue_id)
  VALUES (v_issue, w.id, v_new, p.id, u.region_id, u.station_id, u.id, coalesce(p_emergency, false), v_notes, v_actor, e.id);

  INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
  VALUES (w.id, v_new, u.region_id, 'transferred',
          format('Moved from %s / %s to %s / %s without returning to the warehouse%s', s_from, u_from, s.station_name, u.unit_name,
                 CASE WHEN o.id IS NOT NULL THEN ' (' || coalesce(o.serial_number, 'the old valve') || ' stays at ' || s_from || ')' ELSE '' END),
          jsonb_build_object('issue_id', v_issue, 'from_issue_id', e.id, 'replaced_installed_valve_id', p.id), v_actor);

  IF p.id IS NOT NULL THEN
    UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = p.id;
    INSERT INTO srv_field_log (reason, issue_id, installed_valve_id, region_id, station_id, unit_id, station_name_raw,
                               is_emergency, logged_by)
    VALUES ('replaced_on_issue', v_issue, p.id, u.region_id, u.station_id, u.id, p.source_station_name_raw,
            coalesce(p_emergency, false), v_actor);
    INSERT INTO srv_history (installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (p.id, u.region_id, 'replaced',
            format('Removed from %s / %s, replaced by serial %s (moved from %s); in the SRV Log, still at the station',
                   s.station_name, u.unit_name, coalesce(w.serial_number, '(none)'), s_from),
            jsonb_build_object('issue_id', v_issue, 'new_installed_valve_id', v_new), v_actor);
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_issues', v_issue, v_actor, 'srv_issue_transfer',
          format('SRV %s moved from %s / %s to %s / %s%s%s', coalesce(w.serial_number, w.id::text), s_from, u_from,
                 s.station_name, u.unit_name,
                 CASE WHEN o.id IS NOT NULL THEN '; ' || coalesce(o.serial_number, o.id::text) || ' back in its position at ' || s_from ELSE '' END,
                 CASE WHEN p.id IS NOT NULL THEN '; replacing ' || coalesce(p.serial_number, p.id::text) ELSE '' END),
          jsonb_build_object('from_issue_id', e.id, 'station_id', e.station_id, 'unit_id', e.unit_id,
                             'installed_valve_id', a.id, 'replaced_installed_valve_id', e.replaced_installed_valve_id),
          jsonb_build_object('issue_id', v_issue, 'station_id', u.station_id, 'unit_id', u.id,
                             'new_installed_valve_id', v_new, 'replaced_installed_valve_id', p.id, 'mapping_status', v_status), now());
  RETURN v_issue;
END $$;
COMMENT ON FUNCTION cng_srv_issue_transfer(uuid, uuid, uuid, boolean, text) IS
  'Admin: an issued valve was not fitted (the valve it was to replace is still valid) and goes straight to another Station/Unit. The old valve goes back to its position, the issue is cancelled as transferred, and a new issue of the same store valve is recorded at the new place.';
REVOKE ALL ON FUNCTION cng_srv_issue_transfer(uuid, uuid, uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_issue_transfer(uuid, uuid, uuid, boolean, text) TO authenticated;

-- (3) The issue sheet.
CREATE OR REPLACE VIEW v_srv_issue_sheet WITH (security_invoker = true) AS
SELECT e.id,
       e.issued_at,
       (e.issued_at AT TIME ZONE 'Africa/Cairo')::date AS issue_day,
       e.region_id, r.name AS region_name,
       e.sheet_id, sh.seq AS sheet_seq, sh.exported_at AS sheet_exported_at,
       e.is_emergency,
       s.station_name, u.unit_name,
       CASE WHEN nv.id IS NOT NULL AND nv.unit_id IS NULL THEN s.station_name ELSE u.unit_name END AS place_name,
       COALESCE(nullif(btrim(nv.location_raw), ''),
                CASE WHEN nv.storage_vessel_id IS NOT NULL OR nv.expected_parent_kind = 'storage_vessel' THEN 'Storage'
                     WHEN nv.compressor_id IS NOT NULL OR nv.expected_parent_kind = 'compressor' THEN 'Stage' END) AS location,
       e.warehouse_valve_id,
       w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.manufacturer, w.size_type, w.inlet_size, w.outlet_size,
       w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       e.replaced_installed_valve_id, o.serial_number AS replaced_serial,
       l.returned_at AS replaced_returned_at,
       (e.cancel_action = 'await_return') IS TRUE AS is_cancelled,
       e.cancelled_at,
       ul.returned_at AS cancelled_returned_at,
       CASE WHEN e.cancel_action = 'transferred'
            THEN CASE WHEN tnv.id IS NOT NULL AND tnv.unit_id IS NULL THEN ts.station_name ELSE tu.unit_name END END AS transferred_to,
       CASE WHEN e.cancel_action = 'transferred' THEN e.cancelled_at END AS transferred_at
  FROM srv_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  JOIN units u ON u.id = e.unit_id
  JOIN warehouse_relief_valves w ON w.id = e.warehouse_valve_id
  LEFT JOIN installed_relief_valves nv ON nv.id = e.new_installed_valve_id
  LEFT JOIN installed_relief_valves o ON o.id = e.replaced_installed_valve_id
  LEFT JOIN srv_issue_sheets sh ON sh.id = e.sheet_id
  LEFT JOIN srv_field_log l ON l.issue_id = e.id AND l.reason = 'replaced_on_issue'
                           AND l.installed_valve_id = e.replaced_installed_valve_id AND l.archived_at IS NULL
  LEFT JOIN srv_field_log ul ON ul.issue_id = e.id AND ul.reason = 'issue_undone' AND ul.archived_at IS NULL
  LEFT JOIN srv_issues t ON t.transferred_from_issue_id = e.id
  LEFT JOIN stations ts ON ts.id = t.station_id
  LEFT JOIN units tu ON tu.id = t.unit_id
  LEFT JOIN installed_relief_valves tnv ON tnv.id = t.new_installed_valve_id
 WHERE (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
   AND e.transferred_from_issue_id IS NULL;
COMMENT ON VIEW v_srv_issue_sheet IS
  'Rows of the warehouse issue workbook: every SRV issue that left the warehouse (live, undone as await_return and marked cancelled, or moved on to another Station — transferred_to), with its sheet (NULL until exported), Cairo issue day, place, Stage/Storage, issued and replaced valve. A move between Stations is not a warehouse exit and has no row of its own.';
GRANT SELECT ON v_srv_issue_sheet TO authenticated;
REVOKE ALL ON v_srv_issue_sheet FROM anon;

CREATE OR REPLACE FUNCTION cng_srv_issue_sheet_assign(p_region_id uuid, p_month date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_from date; v_to date; v_day date; v_seq integer; v_sheet uuid; v_n integer; v_total integer := 0;
  v_region text;
BEGIN
  IF p_region_id IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'choose a Region and a month' USING ERRCODE = '22023';
  END IF;
  SELECT name INTO v_region FROM regions WHERE id = p_region_id;
  IF v_region IS NULL THEN RAISE EXCEPTION 'Region not found' USING ERRCODE = '42704'; END IF;
  v_from := date_trunc('month', p_month)::date;
  v_to := (v_from + interval '1 month')::date;
  PERFORM pg_advisory_xact_lock(hashtext('cng_srv_issue_sheet:' || p_region_id::text || ':' || v_from::text));

  FOR v_day IN
    SELECT DISTINCT (e.issued_at AT TIME ZONE 'Africa/Cairo')::date
      FROM srv_issues e
     WHERE e.region_id = p_region_id AND e.sheet_id IS NULL
       AND (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
       AND e.transferred_from_issue_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date >= v_from
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date < v_to
     ORDER BY 1
  LOOP
    SELECT coalesce(max(seq), 0) + 1 INTO v_seq FROM srv_issue_sheets WHERE region_id = p_region_id AND issue_day = v_day;
    INSERT INTO srv_issue_sheets (region_id, issue_day, seq, exported_by) VALUES (p_region_id, v_day, v_seq, v_actor)
      RETURNING id INTO v_sheet;
    UPDATE srv_issues e SET sheet_id = v_sheet
     WHERE e.region_id = p_region_id AND e.sheet_id IS NULL
       AND (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
       AND e.transferred_from_issue_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date = v_day;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, after_data, occurred_at)
    VALUES ('admin_action', 'srv_issue_sheets', v_sheet, v_actor, 'srv_issue_sheet',
            format('Issue sheet %s %s%s exported with %s valve(s)', v_region, to_char(v_day, 'FMDD-FMMM-YYYY'),
                   CASE WHEN v_seq > 1 THEN ' (' || v_seq || ')' ELSE '' END, v_n),
            jsonb_build_object('region_id', p_region_id, 'issue_day', v_day, 'seq', v_seq, 'issues', v_n), now());
  END LOOP;
  RETURN v_total;
END $$;
COMMENT ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) IS
  'Admin: put every SRV issue of the Region and month that left the warehouse (live, undone awaiting return, or moved on to another Station) and is in no sheet yet into a new sheet for its day. A move between Stations is never placed. Returns how many issues were placed.';
REVOKE ALL ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) TO authenticated;
