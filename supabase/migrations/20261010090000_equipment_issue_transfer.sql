-- 20261010090000_equipment_issue_transfer.sql — move an issued hose / gas detector to another Station (owner request
-- 2026-10-10: "anything done for the relief valves applies to every section"; the SRV step is 20261006090000).
--
-- The case: an item is issued to Station A in place of one there; at the Station the old one is still good, so it stays,
-- and the issued item goes straight on to Station B. It never comes back to the warehouse.
--
-- (1) equipment_issues.transferred_from_issue_id — the issue at B names the issue at A it came from (one move per issue).
--     cancel_action gains 'transferred' (the issue at A is cancelled, never deleted); equipment_history gains 'transferred'.
-- (2) cng_equipment_issue_transfer(issue, station, unit?, replace?, emergency, notes) — admin only, SECURITY DEFINER, pinned
--     search_path, actor derived server-side, audited. One transaction:
--       at A: exactly the undo — the replaced item back in its position (its open Log entry closed), the issued item's
--             installed record at A archived, the issue cancelled as 'transferred';
--       at B: a new issue of the SAME store item — a new installed record (same rules as cng_equipment_issue: the Unit is
--             the chosen one or the replaced item's, else unknown; a replaced item goes to the Log), the store record
--             following it to B.
--     Refused (PT409) like the undo when the issued item is no longer "at the station", was itself replaced or removed, or
--     its replaced item is already back in the warehouse; refused (22023) to the same Station and Unit.

-- (1)
ALTER TABLE equipment_issues ADD COLUMN IF NOT EXISTS transferred_from_issue_id uuid NULL REFERENCES equipment_issues(id);
CREATE UNIQUE INDEX IF NOT EXISTS ei_transferred_from_uq ON equipment_issues (transferred_from_issue_id)
  WHERE transferred_from_issue_id IS NOT NULL;
ALTER TABLE equipment_issues DROP CONSTRAINT IF EXISTS ei_cancel_shape_ck;
ALTER TABLE equipment_issues ADD CONSTRAINT ei_cancel_shape_ck CHECK (
  (cancelled_at IS NULL AND cancelled_by IS NULL AND cancel_action IS NULL)
  OR (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancel_action IN ('to_stock', 'await_return', 'transferred')));
ALTER TABLE equipment_history DROP CONSTRAINT equipment_history_event_check;
ALTER TABLE equipment_history ADD CONSTRAINT equipment_history_event_check
  CHECK (event IN ('added', 'issued', 'replaced', 'received', 'sent_to_calibration', 'returned_from_calibration',
                   'certified', 'issue_undone', 'transferred'));

-- (2)
CREATE OR REPLACE FUNCTION cng_equipment_issue_transfer(p_issue_id uuid, p_station_id uuid, p_unit_id uuid DEFAULT NULL,
                                                        p_replace_id uuid DEFAULT NULL, p_emergency boolean DEFAULT false,
                                                        p_notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  e equipment_issues; w equipment_stock; s stations;
  v_old uuid; v_old_archived timestamptz; v_back uuid; v_back_serial text; v_from text;
  oh hoses; og gas_detectors;
  v_unit uuid := p_unit_id; v_unit_name text; v_replaced uuid; v_replaced_serial text; v_dispenser uuid;
  v_new uuid := gen_random_uuid();
  v_issue uuid := gen_random_uuid();
  v_notes text := nullif(btrim(p_notes), '');
  v_status asset_mapping_status;
BEGIN
  SELECT * INTO e FROM equipment_issues WHERE id = p_issue_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'issue not found' USING ERRCODE = '42704'; END IF;
  IF e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'this issue was already undone or moved; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT * INTO w FROM equipment_stock WHERE id = e.stock_id FOR UPDATE;
  IF w.availability_status IS DISTINCT FROM 'sent_to_station_received' THEN
    RAISE EXCEPTION 'the issued item % is no longer recorded as at the station; nothing was changed',
      coalesce(w.serial_number, '(no serial)') USING ERRCODE = 'PT409';
  END IF;
  SELECT * INTO s FROM stations WHERE id = p_station_id AND archived_at IS NULL;
  IF s.id IS NULL THEN RAISE EXCEPTION 'station not found' USING ERRCODE = '42704'; END IF;
  IF s.id = e.station_id AND p_unit_id IS NOT DISTINCT FROM e.unit_id THEN
    RAISE EXCEPTION 'the item is already there; choose another Station or Unit' USING ERRCODE = '22023';
  END IF;
  SELECT st.station_name || coalesce(' / ' || u.unit_name, '') INTO v_from
    FROM stations st LEFT JOIN units u ON u.id = e.unit_id WHERE st.id = e.station_id;

  v_old := coalesce(e.new_hose_id, e.new_gas_detector_id);
  IF e.kind = 'hose' THEN
    SELECT archived_at INTO v_old_archived FROM hoses WHERE id = v_old FOR UPDATE;
  ELSE
    SELECT archived_at INTO v_old_archived FROM gas_detectors WHERE id = v_old FOR UPDATE;
  END IF;
  IF v_old_archived IS NOT NULL THEN
    RAISE EXCEPTION 'the issued item % was itself replaced or removed since; nothing was changed',
      coalesce(w.serial_number, '(no serial)') USING ERRCODE = 'PT409';
  END IF;

  v_back := coalesce(e.replaced_hose_id, e.replaced_gas_detector_id);
  IF v_back IS NOT NULL THEN
    IF e.kind = 'hose' THEN
      SELECT serial_number INTO v_back_serial FROM hoses WHERE id = v_back FOR UPDATE;
    ELSE
      SELECT serial_number INTO v_back_serial FROM gas_detectors WHERE id = v_back FOR UPDATE;
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_field_log WHERE issue_id = e.id AND reason = 'replaced_on_issue'
                  AND archived_at IS NULL AND returned_at IS NOT NULL) THEN
      RAISE EXCEPTION 'the replaced item % is already back in the warehouse, so it cannot stay at %; undo the issue or issue another item instead',
        coalesce(v_back_serial, '(no serial)'), v_from USING ERRCODE = 'PT409';
    END IF;
    UPDATE equipment_field_log SET archived_at = now(), archived_by = v_actor
     WHERE issue_id = e.id AND reason = 'replaced_on_issue' AND archived_at IS NULL AND returned_at IS NULL;
    IF e.kind = 'hose' THEN
      UPDATE hoses SET archived_at = NULL, archived_by = NULL WHERE id = v_back AND archived_at IS NOT NULL;
    ELSE
      UPDATE gas_detectors SET archived_at = NULL, archived_by = NULL WHERE id = v_back AND archived_at IS NOT NULL;
    END IF;
    INSERT INTO equipment_history (kind, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (e.kind, e.replaced_hose_id, e.replaced_gas_detector_id, e.region_id, 'issue_undone',
            format('Stays in its position at %s: the item issued for it was moved to %s', v_from, s.station_name),
            jsonb_build_object('issue_id', e.id, 'transfer_issue_id', v_issue), v_actor);
  END IF;
  IF e.kind = 'hose' THEN
    UPDATE hoses SET archived_at = now(), archived_by = v_actor WHERE id = v_old;
  ELSE
    UPDATE gas_detectors SET archived_at = now(), archived_by = v_actor WHERE id = v_old;
  END IF;
  UPDATE equipment_issues SET cancelled_at = now(), cancelled_by = v_actor, cancel_action = 'transferred' WHERE id = e.id;

  IF p_replace_id IS NOT NULL THEN
    IF e.kind = 'hose' THEN
      SELECT * INTO oh FROM hoses WHERE id = p_replace_id AND archived_at IS NULL FOR UPDATE;
      IF oh.id IS NULL OR oh.station_id <> s.id THEN
        RAISE EXCEPTION 'the hose to replace is not installed at this Station' USING ERRCODE = 'PT409';
      END IF;
      v_replaced := oh.id; v_replaced_serial := oh.serial_number;
      v_unit := coalesce(v_unit, oh.unit_id);
      IF oh.unit_id IS NOT DISTINCT FROM v_unit THEN v_dispenser := oh.dispenser_id; END IF;
    ELSE
      SELECT * INTO og FROM gas_detectors WHERE id = p_replace_id AND archived_at IS NULL FOR UPDATE;
      IF og.id IS NULL OR og.station_id <> s.id THEN
        RAISE EXCEPTION 'the detector to replace is not installed at this Station' USING ERRCODE = 'PT409';
      END IF;
      v_replaced := og.id; v_replaced_serial := og.serial_number;
      v_unit := coalesce(v_unit, og.unit_id);
    END IF;
  END IF;
  IF v_unit IS NOT NULL THEN
    SELECT unit_name INTO v_unit_name FROM units WHERE id = v_unit AND station_id = s.id AND archived_at IS NULL;
    IF v_unit_name IS NULL THEN RAISE EXCEPTION 'the Unit is not at this Station' USING ERRCODE = '22023'; END IF;
  END IF;
  v_status := CASE WHEN v_unit IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END;

  IF e.kind = 'hose' THEN
    INSERT INTO hoses (id, region_id, station_id, unit_id, dispenser_id, mapping_status, mapping_note, resolved_by, resolved_at,
                       description, serial_number, serial_number_raw, serial_status,
                       working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                       last_test_date, last_test_precision, next_test_date, next_test_precision, notes)
    VALUES (v_new, s.region_id, s.id, v_unit, v_dispenser, v_status,
            format('Moved from %s (issued there, not fitted)', v_from) || CASE WHEN v_replaced IS NOT NULL THEN ' in place of another hose' ELSE '' END,
            CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
            w.description, w.serial_number, w.serial_number, w.serial_status,
            w.working_pressure_value, w.working_pressure_unit, w.test_pressure_value, w.test_pressure_unit,
            w.last_date, w.last_precision, w.next_date, w.next_precision, coalesce(v_notes, e.notes));
  ELSE
    INSERT INTO gas_detectors (id, region_id, station_id, unit_id, mapping_status, mapping_note, resolved_by, resolved_at,
                               manufacturer, model, serial_number, serial_number_raw, serial_status,
                               last_calibration_date, last_calibration_precision, next_calibration_date, next_calibration_precision, notes)
    VALUES (v_new, s.region_id, s.id, v_unit, v_status,
            format('Moved from %s (issued there, not fitted)', v_from) || CASE WHEN v_replaced IS NOT NULL THEN ' in place of another detector' ELSE '' END,
            CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
            w.manufacturer, w.model, w.serial_number, w.serial_number, w.serial_status,
            w.last_date, w.last_precision, w.next_date, w.next_precision, coalesce(v_notes, e.notes));
  END IF;

  UPDATE equipment_stock SET target_region_id = s.region_id, target_station_id = s.id WHERE id = w.id;

  INSERT INTO equipment_issues (id, kind, stock_id, new_hose_id, new_gas_detector_id, replaced_hose_id, replaced_gas_detector_id,
                                region_id, station_id, unit_id, is_emergency, notes, issued_by, transferred_from_issue_id)
  VALUES (v_issue, e.kind, w.id,
          CASE WHEN e.kind = 'hose' THEN v_new END, CASE WHEN e.kind = 'gas_detector' THEN v_new END,
          CASE WHEN e.kind = 'hose' THEN v_replaced END, CASE WHEN e.kind = 'gas_detector' THEN v_replaced END,
          s.region_id, s.id, v_unit, coalesce(p_emergency, false), v_notes, v_actor, e.id);

  INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
  VALUES (e.kind, w.id, CASE WHEN e.kind = 'hose' THEN v_new END, CASE WHEN e.kind = 'gas_detector' THEN v_new END,
          s.region_id, 'transferred',
          format('Moved from %s to %s%s without returning to the warehouse%s', v_from, s.station_name, coalesce(' / ' || v_unit_name, ''),
                 CASE WHEN v_back IS NOT NULL THEN ' (' || coalesce(v_back_serial, 'the old item') || ' stays at ' || v_from || ')' ELSE '' END),
          jsonb_build_object('issue_id', v_issue, 'from_issue_id', e.id, 'replaced_id', v_replaced), v_actor);

  IF v_replaced IS NOT NULL THEN
    IF e.kind = 'hose' THEN
      UPDATE hoses SET archived_at = now(), archived_by = v_actor WHERE id = v_replaced;
    ELSE
      UPDATE gas_detectors SET archived_at = now(), archived_by = v_actor WHERE id = v_replaced;
    END IF;
    INSERT INTO equipment_field_log (kind, issue_id, installed_hose_id, installed_gas_detector_id, region_id, station_id, unit_id,
                                     is_emergency, logged_by)
    VALUES (e.kind, v_issue, CASE WHEN e.kind = 'hose' THEN v_replaced END, CASE WHEN e.kind = 'gas_detector' THEN v_replaced END,
            s.region_id, s.id, v_unit, coalesce(p_emergency, false), v_actor);
    INSERT INTO equipment_history (kind, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (e.kind, CASE WHEN e.kind = 'hose' THEN v_replaced END, CASE WHEN e.kind = 'gas_detector' THEN v_replaced END,
            s.region_id, 'replaced',
            format('Removed from %s, replaced by serial %s (moved from %s); in the Log, still at the station', s.station_name,
                   coalesce(w.serial_number, '(none)'), v_from),
            jsonb_build_object('issue_id', v_issue, 'new_id', v_new), v_actor);
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_issues', v_issue, v_actor, 'equipment_issue_transfer',
          format('%s %s moved from %s to %s%s%s%s', replace(e.kind, '_', ' '), coalesce(w.serial_number, w.id::text), v_from,
                 s.station_name, coalesce(' / ' || v_unit_name, ''),
                 CASE WHEN v_back IS NOT NULL THEN '; ' || coalesce(v_back_serial, v_back::text) || ' back in its position' ELSE '' END,
                 CASE WHEN v_replaced IS NOT NULL THEN '; replacing ' || coalesce(v_replaced_serial, v_replaced::text) ELSE '' END),
          jsonb_build_object('from_issue_id', e.id, 'station_id', e.station_id, 'unit_id', e.unit_id, 'installed_id', v_old,
                             'replaced_id', v_back),
          jsonb_build_object('issue_id', v_issue, 'station_id', s.id, 'unit_id', v_unit, 'new_id', v_new,
                             'replaced_id', v_replaced, 'mapping_status', v_status), now());
  RETURN v_issue;
END;
$$;
COMMENT ON FUNCTION cng_equipment_issue_transfer(uuid, uuid, uuid, uuid, boolean, text) IS
  'Admin: an issued hose / gas detector was not fitted (the item it was to replace is still good) and goes straight to another Station/Unit. The old item goes back to its position, the issue is cancelled as transferred, and a new issue of the same store item is recorded at the new place.';
REVOKE ALL ON FUNCTION cng_equipment_issue_transfer(uuid, uuid, uuid, uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_issue_transfer(uuid, uuid, uuid, uuid, boolean, text) TO authenticated;
