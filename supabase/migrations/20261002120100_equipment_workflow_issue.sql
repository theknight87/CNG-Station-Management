-- Hoses / Gas Detectors workflow, part 2 of 3 (owner request 2026-10-02): adding to the store and issuing to a Station.
-- Split from 20261002120000 only so each deploy stays small; see that file for the design. Executes no DML.

-- ============================================================================ add to the store
-- One row per serial; or a quantity of items with no serial yet. Nothing is invented: the next date is recorded only
-- when the admin gives one, a last date only as entered. A serial already in the store for this kind is refused.
CREATE OR REPLACE FUNCTION cng_equipment_stock_add(
  p_kind text, p_availability warehouse_availability, p_serials text[], p_quantity integer,
  p_manufacturer text, p_model text, p_description text,
  p_working_pressure numeric, p_working_unit pressure_unit, p_test_pressure numeric, p_test_unit pressure_unit,
  p_last_date date, p_next_date date, p_warehouse_code text, p_notes text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_serials text[] := ARRAY(SELECT DISTINCT btrim(x) FROM unnest(coalesce(p_serials, '{}')) x WHERE nullif(btrim(x), '') IS NOT NULL);
  v_count integer;
  v_ids uuid[];
BEGIN
  IF p_kind NOT IN ('hose', 'gas_detector') THEN RAISE EXCEPTION 'unknown equipment kind' USING ERRCODE = '22023'; END IF;
  IF p_availability NOT IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN
    RAISE EXCEPTION 'an item added to the store is new, calibrated or under calibration' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) = 0 AND coalesce(p_quantity, 0) < 1 THEN
    RAISE EXCEPTION 'give the serial numbers, or a quantity for items with no serial yet' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_quantity, 0) > 500 THEN RAISE EXCEPTION 'at most 500 items at once' USING ERRCODE = '22023'; END IF;
  IF p_last_date IS NOT NULL AND p_last_date > cng_business_date() THEN
    RAISE EXCEPTION 'the last date cannot be in the future' USING ERRCODE = '22023';
  END IF;
  IF p_next_date IS NOT NULL AND p_last_date IS NOT NULL AND p_next_date <= p_last_date THEN
    RAISE EXCEPTION 'the next date must be after the last date' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM equipment_stock e WHERE e.kind = p_kind AND e.archived_at IS NULL
                AND e.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc')
                AND lower(e.serial_number) = ANY (SELECT lower(x) FROM unnest(v_serials) x)) THEN
    RAISE EXCEPTION 'one of these serial numbers is already in the store' USING ERRCODE = 'PT409';
  END IF;

  WITH src AS (
    SELECT s AS serial FROM unnest(v_serials) s
    UNION ALL
    SELECT NULL FROM generate_series(1, CASE WHEN cardinality(v_serials) = 0 THEN p_quantity ELSE 0 END)
  ), ins AS (
    INSERT INTO equipment_stock (kind, availability_status, serial_number, serial_status, manufacturer, model, description,
                                 working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                                 last_date, last_precision, next_date, next_precision, warehouse_code, notes, created_by)
    SELECT p_kind, p_availability, src.serial, CASE WHEN src.serial IS NULL THEN 'not_yet_assigned' ELSE 'assigned' END::serial_status,
           nullif(btrim(p_manufacturer), ''),
           CASE WHEN p_kind = 'gas_detector' THEN nullif(btrim(p_model), '') END,
           CASE WHEN p_kind = 'hose' THEN nullif(btrim(p_description), '') END,
           CASE WHEN p_kind = 'hose' THEN p_working_pressure END, CASE WHEN p_kind = 'hose' THEN p_working_unit END,
           CASE WHEN p_kind = 'hose' THEN p_test_pressure END, CASE WHEN p_kind = 'hose' THEN p_test_unit END,
           p_last_date, CASE WHEN p_last_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
           p_next_date, CASE WHEN p_next_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
           nullif(btrim(p_warehouse_code), ''), nullif(btrim(p_notes), ''), v_actor
      FROM src
    RETURNING id
  )
  SELECT array_agg(id) INTO v_ids FROM ins;
  v_count := cardinality(v_ids);

  INSERT INTO equipment_history (kind, stock_id, event, summary, actor_id)
  SELECT p_kind, x, 'added', 'Added to the warehouse', v_actor FROM unnest(v_ids) x;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_stock', NULL, v_actor, 'equipment_stock_add',
          format('%s %s(s) added to the warehouse', v_count, replace(p_kind, '_', ' ')), NULL,
          jsonb_build_object('kind', p_kind, 'availability', p_availability, 'stock_ids', to_jsonb(v_ids)), now());
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_stock_add(text, warehouse_availability, text[], integer, text, text, text, numeric,
  pressure_unit, numeric, pressure_unit, date, date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_stock_add(text, warehouse_availability, text[], integer, text, text, text, numeric,
  pressure_unit, numeric, pressure_unit, date, date, text, text) TO authenticated;

-- ============================================================================ issue
-- The items of this kind installed at the Station (any Unit, or the chosen Unit): what the issued one may replace.
CREATE OR REPLACE FUNCTION cng_equipment_replacement_candidates(p_kind text, p_station_id uuid, p_unit_id uuid DEFAULT NULL)
RETURNS TABLE (id uuid, serial_number text, manufacturer text, model text, description text, unit_name text, last_date date)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT h.id, h.serial_number, NULL::text, NULL::text, h.description, u.unit_name, h.last_test_date
    FROM hoses h LEFT JOIN units u ON u.id = h.unit_id
   WHERE p_kind = 'hose' AND h.archived_at IS NULL AND h.station_id = p_station_id
     AND (p_unit_id IS NULL OR h.unit_id IS NULL OR h.unit_id = p_unit_id)
  UNION ALL
  SELECT g.id, g.serial_number, g.manufacturer, g.model, NULL::text, u.unit_name, g.last_calibration_date
    FROM gas_detectors g LEFT JOIN units u ON u.id = g.unit_id
   WHERE p_kind = 'gas_detector' AND g.archived_at IS NULL AND g.station_id = p_station_id
     AND (p_unit_id IS NULL OR g.unit_id IS NULL OR g.unit_id = p_unit_id)
   ORDER BY 6 NULLS LAST, 2 NULLS LAST, 1;
$$;
REVOKE ALL ON FUNCTION cng_equipment_replacement_candidates(text, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_replacement_candidates(text, uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION cng_equipment_issue(
  p_stock_id uuid,
  p_expected_updated_at timestamptz,
  p_station_id uuid,
  p_unit_id uuid DEFAULT NULL,
  p_replace_id uuid DEFAULT NULL,
  p_emergency boolean DEFAULT false,
  p_notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  w equipment_stock;
  s stations;
  v_unit uuid := p_unit_id;
  v_unit_name text;
  oh hoses;
  og gas_detectors;
  v_replaced uuid;
  v_replaced_serial text;
  v_dispenser uuid;
  v_new uuid := gen_random_uuid();
  v_issue uuid := gen_random_uuid();
  v_notes text := nullif(btrim(p_notes), '');
  v_status asset_mapping_status;
BEGIN
  SELECT * INTO w FROM equipment_stock WHERE id = p_stock_id AND archived_at IS NULL FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'warehouse item not found' USING ERRCODE = '42704'; END IF;
  PERFORM cng_check_precondition(w.updated_at, p_expected_updated_at);
  IF w.availability_status NOT IN ('available_new', 'available_calibrated') THEN
    RAISE EXCEPTION 'only a new or calibrated item in the store can be issued (this one is %)', w.availability_status
      USING ERRCODE = 'PT409';
  END IF;
  IF EXISTS (SELECT 1 FROM equipment_calibration_jobs j WHERE j.stock_id = w.id AND j.status <> 'certified') THEN
    RAISE EXCEPTION 'this item is at the 3rd party' USING ERRCODE = 'PT409';
  END IF;

  SELECT * INTO s FROM stations WHERE id = p_station_id AND archived_at IS NULL;
  IF s.id IS NULL THEN RAISE EXCEPTION 'station not found' USING ERRCODE = '42704'; END IF;

  IF p_replace_id IS NOT NULL THEN
    IF w.kind = 'hose' THEN
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
  -- The Unit is a fact only when it is known: chosen, or the replaced item's own. Otherwise it stays unknown.
  v_status := CASE WHEN v_unit IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END;

  IF w.kind = 'hose' THEN
    INSERT INTO hoses (id, region_id, station_id, unit_id, dispenser_id, mapping_status, mapping_note, resolved_by, resolved_at,
                       description, serial_number, serial_number_raw, serial_status,
                       working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                       last_test_date, last_test_precision, next_test_date, next_test_precision, notes)
    VALUES (v_new, s.region_id, s.id, v_unit, v_dispenser, v_status,
            'Issued from the warehouse' || CASE WHEN v_replaced IS NOT NULL THEN ' in place of another hose' ELSE '' END,
            CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
            w.description, w.serial_number, w.serial_number, w.serial_status,
            w.working_pressure_value, w.working_pressure_unit, w.test_pressure_value, w.test_pressure_unit,
            w.last_date, w.last_precision, w.next_date, w.next_precision, v_notes);
  ELSE
    INSERT INTO gas_detectors (id, region_id, station_id, unit_id, mapping_status, mapping_note, resolved_by, resolved_at,
                               manufacturer, model, serial_number, serial_number_raw, serial_status,
                               last_calibration_date, last_calibration_precision, next_calibration_date, next_calibration_precision, notes)
    VALUES (v_new, s.region_id, s.id, v_unit, v_status,
            'Issued from the warehouse' || CASE WHEN v_replaced IS NOT NULL THEN ' in place of another detector' ELSE '' END,
            CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
            w.manufacturer, w.model, w.serial_number, w.serial_number, w.serial_status,
            w.last_date, w.last_precision, w.next_date, w.next_precision, v_notes);
  END IF;

  UPDATE equipment_stock
     SET availability_status = 'sent_to_station_received', target_region_id = s.region_id, target_station_id = s.id
   WHERE id = w.id;

  INSERT INTO equipment_issues (id, kind, stock_id, new_hose_id, new_gas_detector_id, replaced_hose_id, replaced_gas_detector_id,
                                region_id, station_id, unit_id, is_emergency, notes, issued_by)
  VALUES (v_issue, w.kind, w.id,
          CASE WHEN w.kind = 'hose' THEN v_new END, CASE WHEN w.kind = 'gas_detector' THEN v_new END,
          CASE WHEN w.kind = 'hose' THEN v_replaced END, CASE WHEN w.kind = 'gas_detector' THEN v_replaced END,
          s.region_id, s.id, v_unit, coalesce(p_emergency, false), v_notes, v_actor);

  INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
  VALUES (w.kind, w.id, CASE WHEN w.kind = 'hose' THEN v_new END, CASE WHEN w.kind = 'gas_detector' THEN v_new END,
          s.region_id, 'issued',
          format('Issued from warehouse to %s%s%s', s.station_name, coalesce(' / ' || v_unit_name, ''),
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('issue_id', v_issue, 'replaced_id', v_replaced), v_actor);

  IF v_replaced IS NOT NULL THEN
    IF w.kind = 'hose' THEN
      UPDATE hoses SET archived_at = now(), archived_by = v_actor WHERE id = v_replaced;
    ELSE
      UPDATE gas_detectors SET archived_at = now(), archived_by = v_actor WHERE id = v_replaced;
    END IF;
    INSERT INTO equipment_field_log (kind, issue_id, installed_hose_id, installed_gas_detector_id, region_id, station_id, unit_id,
                                     is_emergency, logged_by)
    VALUES (w.kind, v_issue, CASE WHEN w.kind = 'hose' THEN v_replaced END, CASE WHEN w.kind = 'gas_detector' THEN v_replaced END,
            s.region_id, s.id, v_unit, coalesce(p_emergency, false), v_actor);
    INSERT INTO equipment_history (kind, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (w.kind, CASE WHEN w.kind = 'hose' THEN v_replaced END, CASE WHEN w.kind = 'gas_detector' THEN v_replaced END,
            s.region_id, 'replaced',
            format('Removed from %s, replaced by serial %s; in the Log, still at the station', s.station_name,
                   coalesce(w.serial_number, '(none)')),
            jsonb_build_object('issue_id', v_issue, 'new_id', v_new), v_actor);
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_issues', v_issue, v_actor, 'equipment_issue',
          format('%s %s issued to %s%s%s', replace(w.kind, '_', ' '), coalesce(w.serial_number, w.id::text), s.station_name,
                 CASE WHEN v_replaced IS NOT NULL THEN ', replacing ' || coalesce(v_replaced_serial, v_replaced::text) ELSE '' END,
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('availability_status', w.availability_status, 'replaced_id', v_replaced),
          jsonb_build_object('new_id', v_new, 'station_id', s.id, 'unit_id', v_unit, 'mapping_status', v_status), now());
  RETURN v_issue;
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_issue(uuid, timestamptz, uuid, uuid, uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_issue(uuid, timestamptz, uuid, uuid, uuid, boolean, text) TO authenticated;
