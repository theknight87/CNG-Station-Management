-- Owner ruling 6y (2026-10-01), part 4: issuing a warehouse valve in place of a Station-level storage valve keeps
-- the new valve at Station level (no Unit; same vessel, or the storage bank), resolved — exactly where the old one
-- was. Without this the new valve would be pinned to the Unit it was issued from and lose its storage parent.
-- The body is the deployed 20260929090000 definition with only those lines changed.

CREATE OR REPLACE FUNCTION public.cng_srv_issue(p_warehouse_valve_id uuid, p_expected_updated_at timestamp with time zone, p_unit_id uuid, p_replace_installed_valve_id uuid DEFAULT NULL::uuid, p_emergency boolean DEFAULT false, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_actor uuid := cng_require_admin();
  w warehouse_relief_valves;
  u units;
  s stations;
  o installed_relief_valves;
  v_new uuid := gen_random_uuid();
  v_issue uuid := gen_random_uuid();
  v_status srv_mapping_status := 'needs_equipment_mapping';
  v_notes text := nullif(btrim(p_notes), '');
  v_station_level boolean := false;
BEGIN
  SELECT * INTO w FROM warehouse_relief_valves WHERE id = p_warehouse_valve_id AND archived_at IS NULL FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'warehouse valve not found' USING ERRCODE = '42704'; END IF;
  PERFORM cng_check_precondition(w.updated_at, p_expected_updated_at);
  IF w.availability_status NOT IN ('available_new', 'available_calibrated') THEN
    RAISE EXCEPTION 'only a new or calibrated valve in the store can be issued (this one is %)', w.availability_status
      USING ERRCODE = 'PT409';
  END IF;
  IF EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified' AND j.archived_at IS NULL) THEN
    RAISE EXCEPTION 'this valve is at the calibration company' USING ERRCODE = 'PT409';
  END IF;

  SELECT * INTO u FROM units WHERE id = p_unit_id AND archived_at IS NULL;
  IF u.id IS NULL THEN RAISE EXCEPTION 'unit not found' USING ERRCODE = '42704'; END IF;
  SELECT * INTO s FROM stations WHERE id = u.station_id;

  IF p_replace_installed_valve_id IS NOT NULL THEN
    SELECT * INTO o FROM installed_relief_valves WHERE id = p_replace_installed_valve_id AND archived_at IS NULL FOR UPDATE;
    IF o.id IS NULL THEN RAISE EXCEPTION 'the valve to replace was not found or was already removed' USING ERRCODE = 'PT409'; END IF;
    IF NOT EXISTS (SELECT 1 FROM cng_srv_replacement_candidates(p_unit_id, p_warehouse_valve_id) c WHERE c.id = o.id) THEN
      RAISE EXCEPTION 'the valve to replace is not at this Unit''s Station with the same set pressure' USING ERRCODE = '22023';
    END IF;
    IF o.unit_id IS NULL AND o.mapping_status = 'resolved' THEN
      -- Ruling 6y: the valve replaced Station-level storage, so the new one takes the same Station-level place.
      v_station_level := true;
      v_status := 'resolved';
    ELSIF num_nonnulls(o.compressor_id, o.storage_vessel_id, o.dispenser_id) = 1 AND o.unit_id = u.id THEN
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
    CASE WHEN v_status = 'resolved' THEN o.compressor_id END,
    CASE WHEN v_status = 'resolved' THEN o.storage_vessel_id END,
    CASE WHEN v_status = 'resolved' THEN o.dispenser_id END,
    v_status, 'Issued from the warehouse' || CASE WHEN o.id IS NOT NULL THEN ' in place of another valve' ELSE '' END,
    CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
    o.location_raw, o.expected_parent_kind,
    w.manufacturer, w.manufacturer_raw, w.serial_number, w.serial_number_raw, w.serial_status, w.part_number,
    w.size_type, w.inlet_size, w.outlet_size, w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
    w.last_calibration_raw, w.last_calibration_date, w.last_calibration_precision,
    w.next_calibration_raw, w.next_calibration_date, w.next_calibration_precision,
    v_notes, w.warehouse_code);

  UPDATE warehouse_relief_valves
     SET availability_status = 'sent_to_station_received',
         target_region_id = u.region_id, target_station_id = u.station_id,
         warehouse_issue_date = cng_business_date(), warehouse_issue_precision = 'exact_date', warehouse_issue_raw = NULL
   WHERE id = w.id;

  INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id,
                          region_id, station_id, unit_id, is_emergency, notes, issued_by)
  VALUES (v_issue, w.id, v_new, o.id, u.region_id, u.station_id, u.id, coalesce(p_emergency, false), v_notes, v_actor);

  INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
  VALUES (w.id, v_new, u.region_id, 'issued',
          format('Issued from warehouse to %s / %s%s', s.station_name, u.unit_name,
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('issue_id', v_issue, 'replaced_installed_valve_id', o.id), v_actor);

  IF o.id IS NOT NULL THEN
    UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = o.id;
    INSERT INTO srv_field_log (reason, issue_id, installed_valve_id, region_id, station_id, unit_id, station_name_raw,
                               is_emergency, logged_by)
    VALUES ('replaced_on_issue', v_issue, o.id, u.region_id, u.station_id, u.id, o.source_station_name_raw,
            coalesce(p_emergency, false), v_actor);
    INSERT INTO srv_history (installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (o.id, u.region_id, 'replaced',
            format('Removed from %s / %s, replaced by serial %s; in the SRV Log, still at the station', s.station_name,
                   u.unit_name, coalesce(w.serial_number, '(none)')),
            jsonb_build_object('issue_id', v_issue, 'new_installed_valve_id', v_new), v_actor);
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_issues', v_issue, v_actor, 'srv_issue',
          format('SRV %s issued to %s / %s%s%s', coalesce(w.serial_number, w.id::text), s.station_name, u.unit_name,
                 CASE WHEN o.id IS NOT NULL THEN ', replacing ' || coalesce(o.serial_number, o.id::text) ELSE '' END,
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('availability_status', w.availability_status, 'replaced_installed_valve_id', o.id),
          jsonb_build_object('new_installed_valve_id', v_new, 'unit_id', u.id, 'mapping_status', v_status), now());
  RETURN v_issue;
END;
$function$;
