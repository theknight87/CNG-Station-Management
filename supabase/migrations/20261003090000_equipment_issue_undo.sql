-- Undo an issue of a hose or a gas detector (owner request 2026-10-03), the same step the relief valves have
-- (20260929150000): one decision undoes both halves, so a Station never shows two items in one position.
--
-- (1) cng_equipment_issue_undo(issue, action) — admin only, SECURITY DEFINER, actor derived server-side, audited:
--       the replaced item (if any) goes back to its position and its open Log entry is closed (archived); the issued
--       item leaves the Station, and the admin says where it is:
--         'to_stock'      it never left / is already back: the store again with the condition it had before the issue;
--         'await_return'  it is still at the Station: it goes to the Log (reason 'issue_undone') until it is received,
--                         and then returns to its OWN store record (same warehouse code), under calibration / testing.
--       The issue is marked cancelled (cancelled_at / cancelled_by / cancel_action), never deleted. Refused when the
--       replaced item is already back in the warehouse, or when the issued item was itself replaced or removed since.
-- (2) cng_equipment_log_receive handles an 'issue_undone' entry by returning the original store record.
-- (3) v_equipment_issue_log: the Issued movement — every issue not undone, with where its replaced item is.
--     v_equipment_field_log leaves out closed entries and adds reason / issue_cancelled; v_equipment_emergency leaves
--     out undone issues. security_invoker restated (CREATE OR REPLACE VIEW does not keep it).
-- Nothing is deleted; existing rows are untouched (all of them are 'replaced_on_issue' and not archived).
--
-- Part 1 of 2. 20261003090100 widens the two CHECK constraints (Log reason, history event) and retires the two
-- old open-entry indexes; it is separate because only it replaces existing objects.

ALTER TABLE equipment_issues ADD COLUMN IF NOT EXISTS cancelled_at timestamptz NULL;
ALTER TABLE equipment_issues ADD COLUMN IF NOT EXISTS cancelled_by uuid NULL REFERENCES app_users(id);
ALTER TABLE equipment_issues ADD COLUMN IF NOT EXISTS cancel_action text NULL;
ALTER TABLE equipment_issues ADD CONSTRAINT ei_cancel_shape_ck CHECK (
  (cancelled_at IS NULL AND cancelled_by IS NULL AND cancel_action IS NULL)
  OR (cancelled_at IS NOT NULL AND cancelled_by IS NOT NULL AND cancel_action IN ('to_stock', 'await_return')));

ALTER TABLE equipment_field_log ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL;
ALTER TABLE equipment_field_log ADD COLUMN IF NOT EXISTS archived_by uuid NULL REFERENCES app_users(id);
-- An item is open in the Log at most once; a closed (archived) entry no longer counts.
CREATE UNIQUE INDEX IF NOT EXISTS efl_open_hose_live_uq ON equipment_field_log (installed_hose_id)
  WHERE returned_at IS NULL AND archived_at IS NULL AND installed_hose_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS efl_open_detector_live_uq ON equipment_field_log (installed_gas_detector_id)
  WHERE returned_at IS NULL AND archived_at IS NULL AND installed_gas_detector_id IS NOT NULL;

-- ============================================================================ views
CREATE OR REPLACE VIEW v_equipment_field_log WITH (security_invoker = true) AS
SELECT l.id, l.kind,
       CASE WHEN l.returned_at IS NOT NULL THEN 'returned' ELSE 'at_station' END AS status,
       l.is_emergency, l.issue_id, l.installed_hose_id, l.installed_gas_detector_id,
       l.region_id, r.name AS region_name, l.station_id, s.station_name, l.unit_id, u.unit_name,
       coalesce(h.serial_number, g.serial_number) AS serial_number,
       g.manufacturer, g.model, h.description,
       h.working_pressure_value, h.working_pressure_unit,
       coalesce(h.last_test_date, g.last_calibration_date) AS last_date,
       l.logged_at, l.returned_at, l.returned_stock_id,
       l.reason, (e.cancelled_at IS NOT NULL) AS issue_cancelled
  FROM equipment_field_log l
  JOIN regions r ON r.id = l.region_id
  JOIN stations s ON s.id = l.station_id
  JOIN equipment_issues e ON e.id = l.issue_id
  LEFT JOIN units u ON u.id = l.unit_id
  LEFT JOIN hoses h ON h.id = l.installed_hose_id
  LEFT JOIN gas_detectors g ON g.id = l.installed_gas_detector_id
 WHERE l.archived_at IS NULL;

CREATE OR REPLACE VIEW v_equipment_emergency WITH (security_invoker = true) AS
SELECT e.id, e.kind, e.issued_at, e.notes,
       e.region_id, r.name AS region_name, e.station_id, s.station_name, e.unit_id, u.unit_name,
       e.stock_id, w.serial_number AS issued_serial, w.warehouse_code AS issued_code, w.manufacturer, w.model, w.description,
       coalesce(rh.serial_number, rg.serial_number) AS replaced_serial,
       CASE WHEN l.id IS NULL THEN NULL WHEN l.returned_at IS NOT NULL THEN 'returned' ELSE 'at_station' END AS replaced_status
  FROM equipment_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  LEFT JOIN units u ON u.id = e.unit_id
  JOIN equipment_stock w ON w.id = e.stock_id
  LEFT JOIN hoses rh ON rh.id = e.replaced_hose_id
  LEFT JOIN gas_detectors rg ON rg.id = e.replaced_gas_detector_id
  LEFT JOIN equipment_field_log l ON l.issue_id = e.id AND l.reason = 'replaced_on_issue' AND l.archived_at IS NULL
 WHERE e.is_emergency AND e.cancelled_at IS NULL;

-- The Issued movement: every issue that was not undone, and where the item it replaced is.
CREATE OR REPLACE VIEW v_equipment_issue_log WITH (security_invoker = true) AS
SELECT e.id, e.kind, e.issued_at, e.is_emergency, e.notes,
       e.region_id, r.name AS region_name, e.station_id, s.station_name, e.unit_id, u.unit_name,
       e.stock_id, w.serial_number AS issued_serial, w.warehouse_code AS issued_code, w.manufacturer, w.model, w.description,
       w.working_pressure_value, w.working_pressure_unit,
       coalesce(rh.serial_number, rg.serial_number) AS replaced_serial,
       CASE WHEN coalesce(e.replaced_hose_id, e.replaced_gas_detector_id) IS NULL THEN 'no_replacement'
            WHEN l.returned_at IS NOT NULL THEN 'replaced_returned'
            ELSE 'replaced_at_station' END AS status,
       l.returned_at AS replaced_returned_at
  FROM equipment_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  LEFT JOIN units u ON u.id = e.unit_id
  JOIN equipment_stock w ON w.id = e.stock_id
  LEFT JOIN hoses rh ON rh.id = e.replaced_hose_id
  LEFT JOIN gas_detectors rg ON rg.id = e.replaced_gas_detector_id
  LEFT JOIN equipment_field_log l ON l.issue_id = e.id AND l.reason = 'replaced_on_issue' AND l.archived_at IS NULL
 WHERE e.cancelled_at IS NULL;

REVOKE ALL ON v_equipment_field_log, v_equipment_emergency, v_equipment_issue_log FROM PUBLIC, anon;
GRANT SELECT ON v_equipment_field_log, v_equipment_emergency, v_equipment_issue_log TO authenticated;

-- ============================================================================ (1) undo
CREATE OR REPLACE FUNCTION cng_equipment_issue_undo(p_issue_id uuid, p_issued_action text, p_reason text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  e equipment_issues; w equipment_stock;
  v_new uuid; v_new_archived timestamptz; v_replaced uuid; v_replaced_serial text;
  v_prior warehouse_availability; v_log uuid; s_name text; u_name text; v_where text;
BEGIN
  IF p_issued_action IS NULL OR p_issued_action NOT IN ('to_stock', 'await_return') THEN
    RAISE EXCEPTION 'choose where the issued item is: back in the warehouse, or still at the station awaiting return'
      USING ERRCODE = '22023';
  END IF;
  SELECT * INTO e FROM equipment_issues WHERE id = p_issue_id FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'issue not found' USING ERRCODE = '42704'; END IF;
  IF e.cancelled_at IS NOT NULL THEN RAISE EXCEPTION 'this issue was already undone; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT station_name INTO s_name FROM stations WHERE id = e.station_id;
  SELECT unit_name INTO u_name FROM units WHERE id = e.unit_id;
  v_where := s_name || coalesce(' / ' || u_name, '');

  SELECT * INTO w FROM equipment_stock WHERE id = e.stock_id FOR UPDATE;
  IF w.availability_status IS DISTINCT FROM 'sent_to_station_received' THEN
    RAISE EXCEPTION 'the issued item % is no longer recorded as at the station; nothing was changed',
      coalesce(w.serial_number, '(no serial)') USING ERRCODE = 'PT409';
  END IF;

  v_new := coalesce(e.new_hose_id, e.new_gas_detector_id);
  IF e.kind = 'hose' THEN
    SELECT archived_at INTO v_new_archived FROM hoses WHERE id = v_new FOR UPDATE;
  ELSE
    SELECT archived_at INTO v_new_archived FROM gas_detectors WHERE id = v_new FOR UPDATE;
  END IF;
  IF v_new_archived IS NOT NULL THEN
    RAISE EXCEPTION 'the issued item % was itself replaced or removed since; nothing was changed',
      coalesce(w.serial_number, '(no serial)') USING ERRCODE = 'PT409';
  END IF;

  -- The replaced item goes back to its position.
  v_replaced := coalesce(e.replaced_hose_id, e.replaced_gas_detector_id);
  IF v_replaced IS NOT NULL THEN
    IF e.kind = 'hose' THEN
      SELECT serial_number INTO v_replaced_serial FROM hoses WHERE id = v_replaced FOR UPDATE;
    ELSE
      SELECT serial_number INTO v_replaced_serial FROM gas_detectors WHERE id = v_replaced FOR UPDATE;
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_field_log WHERE issue_id = e.id AND reason = 'replaced_on_issue'
                  AND archived_at IS NULL AND returned_at IS NOT NULL) THEN
      RAISE EXCEPTION 'the replaced item % is already back in the warehouse; issue it again from the warehouse instead',
        coalesce(v_replaced_serial, '(no serial)') USING ERRCODE = 'PT409';
    END IF;
    UPDATE equipment_field_log SET archived_at = now(), archived_by = v_actor
     WHERE issue_id = e.id AND reason = 'replaced_on_issue' AND archived_at IS NULL AND returned_at IS NULL;
    IF e.kind = 'hose' THEN
      UPDATE hoses SET archived_at = NULL, archived_by = NULL WHERE id = v_replaced AND archived_at IS NOT NULL;
    ELSE
      UPDATE gas_detectors SET archived_at = NULL, archived_by = NULL WHERE id = v_replaced AND archived_at IS NOT NULL;
    END IF;
    INSERT INTO equipment_history (kind, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (e.kind, e.replaced_hose_id, e.replaced_gas_detector_id, e.region_id, 'issue_undone',
            format('Back in its position at %s: the issue that replaced it was undone', v_where),
            jsonb_build_object('issue_id', e.id), v_actor);
  END IF;

  -- The issued item leaves the Station.
  IF e.kind = 'hose' THEN
    UPDATE hoses SET archived_at = now(), archived_by = v_actor WHERE id = v_new;
  ELSE
    UPDATE gas_detectors SET archived_at = now(), archived_by = v_actor WHERE id = v_new;
  END IF;

  IF p_issued_action = 'to_stock' THEN
    SELECT (a.before_data->>'availability_status')::warehouse_availability INTO v_prior
      FROM audit_logs a WHERE a.entity_table = 'equipment_issues' AND a.entity_id = e.id AND a.actor_label = 'equipment_issue'
     ORDER BY a.occurred_at LIMIT 1;
    IF v_prior IS NULL OR v_prior NOT IN ('available_new', 'available_calibrated') THEN
      v_prior := CASE WHEN w.last_date IS NOT NULL THEN 'available_calibrated' ELSE 'available_new' END;
    END IF;
    UPDATE equipment_stock SET availability_status = v_prior, target_region_id = NULL, target_station_id = NULL WHERE id = w.id;
    INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (e.kind, w.id, e.new_hose_id, e.new_gas_detector_id, e.region_id, 'issue_undone',
            format('Issue to %s undone: back in the warehouse as it was', v_where),
            jsonb_build_object('issue_id', e.id, 'availability_status', v_prior), v_actor);
  ELSE
    v_log := gen_random_uuid();
    INSERT INTO equipment_field_log (id, kind, reason, issue_id, installed_hose_id, installed_gas_detector_id,
                                     region_id, station_id, unit_id, is_emergency, logged_by)
    VALUES (v_log, e.kind, 'issue_undone', e.id, e.new_hose_id, e.new_gas_detector_id,
            e.region_id, e.station_id, e.unit_id, false, v_actor);
    INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (e.kind, w.id, e.new_hose_id, e.new_gas_detector_id, e.region_id, 'issue_undone',
            format('Issue to %s undone: still at the station, in the Log awaiting return', v_where),
            jsonb_build_object('issue_id', e.id, 'log_id', v_log), v_actor);
  END IF;

  UPDATE equipment_issues SET cancelled_at = now(), cancelled_by = v_actor, cancel_action = p_issued_action WHERE id = e.id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_issues', e.id, v_actor, 'equipment_issue_undo',
          format('%s issue of %s to %s undone%s; issued item %s. %s', replace(e.kind, '_', ' '),
                 coalesce(w.serial_number, w.id::text), v_where,
                 CASE WHEN v_replaced IS NOT NULL THEN ', ' || coalesce(v_replaced_serial, v_replaced::text) || ' back in its position' ELSE '' END,
                 CASE p_issued_action WHEN 'to_stock' THEN 'back in the warehouse' ELSE 'awaiting return in the Log' END,
                 coalesce(nullif(btrim(p_reason), ''), '')),
          jsonb_build_object('availability_status', w.availability_status, 'new_id', v_new, 'replaced_id', v_replaced),
          jsonb_build_object('cancel_action', p_issued_action, 'availability_status',
                             (SELECT availability_status FROM equipment_stock WHERE id = w.id), 'log_id', v_log), now());
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_issue_undo(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_issue_undo(uuid, text, text) TO authenticated;

-- ============================================================================ (2) receive
CREATE OR REPLACE FUNCTION cng_equipment_log_receive(p_log_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); l equipment_field_log; h hoses; g gas_detectors; v_stock uuid; n int := 0;
BEGIN
  IF p_log_ids IS NULL OR cardinality(p_log_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM equipment_field_log WHERE id = ANY (p_log_ids) AND returned_at IS NULL AND archived_at IS NULL)
     <> (SELECT count(DISTINCT x) FROM unnest(p_log_ids) x) THEN
    RAISE EXCEPTION 'some selected items were already received or are not in the Log; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  FOR l IN SELECT * FROM equipment_field_log WHERE id = ANY (p_log_ids) ORDER BY logged_at, id FOR UPDATE LOOP
    IF l.reason = 'issue_undone' THEN
      -- An undone issue's item returns to its own store record (same warehouse code), to be checked again.
      SELECT stock_id INTO v_stock FROM equipment_issues WHERE id = l.issue_id;
      UPDATE equipment_stock SET availability_status = 'available_in_store_uc', target_region_id = NULL, target_station_id = NULL
       WHERE id = v_stock;
    ELSIF l.kind = 'hose' THEN
      v_stock := gen_random_uuid();
      SELECT * INTO h FROM hoses WHERE id = l.installed_hose_id;
      INSERT INTO equipment_stock (id, kind, availability_status, serial_number, serial_status, description,
                                   working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                                   last_date, last_precision, next_date, next_precision, notes, created_by)
      VALUES (v_stock, 'hose', 'available_in_store_uc', h.serial_number,
              CASE WHEN h.serial_number IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status, h.description,
              h.working_pressure_value, h.working_pressure_unit, h.test_pressure_value, h.test_pressure_unit,
              h.last_test_date, CASE WHEN h.last_test_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              h.next_test_date, CASE WHEN h.next_test_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              'Returned from the station (Log)', v_actor);
    ELSE
      v_stock := gen_random_uuid();
      SELECT * INTO g FROM gas_detectors WHERE id = l.installed_gas_detector_id;
      INSERT INTO equipment_stock (id, kind, availability_status, serial_number, serial_status, manufacturer, model,
                                   last_date, last_precision, next_date, next_precision, notes, created_by)
      VALUES (v_stock, 'gas_detector', 'available_in_store_uc', g.serial_number,
              CASE WHEN g.serial_number IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status, g.manufacturer, g.model,
              g.last_calibration_date, CASE WHEN g.last_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              g.next_calibration_date, CASE WHEN g.next_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              'Returned from the station (Log)', v_actor);
    END IF;
    UPDATE equipment_field_log SET returned_at = now(), returned_by = v_actor, returned_stock_id = v_stock WHERE id = l.id;
    INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (l.kind, v_stock, l.installed_hose_id, l.installed_gas_detector_id, NULL, 'received',
            'Received back at the warehouse; now in the store, under calibration',
            jsonb_build_object('log_id', l.id, 'from_station_id', l.station_id), v_actor);
    n := n + 1;
  END LOOP;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_field_log', NULL, v_actor, 'equipment_log_receive',
          format('%s item(s) received back at the warehouse from the Log', n), NULL,
          jsonb_build_object('log_ids', to_jsonb(p_log_ids)), now());
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_log_receive(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_log_receive(uuid[]) TO authenticated;
