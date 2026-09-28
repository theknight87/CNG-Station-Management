-- Owner request 2026-09-28 (suggestion 3): add equipment to a Unit from the Unit popup — a compressor, dispenser,
-- storage vessel, recovery tank, gas detector, hose or installed relief valve.
--
-- Admin only; SECURITY DEFINER with a pinned search_path; the actor derived server-side (cng_require_admin); audited.
-- The Unit is the only placement input: Region and Station are read from it, never supplied, so a record cannot be
-- attached to a Station its Unit does not belong to (the composite foreign keys enforce the same thing again).
-- Mapping status is DERIVED: the Unit is proven by the administrator's explicit choice, so equipment is `resolved`
-- (with resolved_by/at); a relief valve is `needs_equipment_mapping`, because which compressor, vessel or dispenser it
-- sits on is not stated here and is never guessed (CLAUDE.md §4).
-- Nothing is invented: every field is what was typed, empty stays NULL, a date is exact or absent. The one derived value
-- is the relief-valve owner rule already used by the warehouse: a next calibration one year after the last, when the
-- last is given and the next is not. No interval is assumed for vessels, detectors or hoses (none is authoritative).
-- No dynamic SQL: each kind is its own literal INSERT.

CREATE OR REPLACE FUNCTION cng_admin_add_unit_asset(p_kind text, p_unit_id uuid, p jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_unit record;
  v_id uuid;
  v_table text;
  t_serial text := nullif(btrim(p->>'serial_number'), '');
  t_last date := (nullif(p->>'last_date', ''))::date;
  t_next date := (nullif(p->>'next_date', ''))::date;
  v_min numeric := (nullif(p->>'pressure_min', ''))::numeric;
  v_max numeric := coalesce((nullif(p->>'pressure_max', ''))::numeric, (nullif(p->>'pressure_min', ''))::numeric);
BEGIN
  SELECT u.id, u.station_id, u.region_id INTO v_unit FROM units u WHERE u.id = p_unit_id AND u.archived_at IS NULL;
  IF v_unit.id IS NULL THEN RAISE EXCEPTION 'this Unit no longer exists; reload' USING ERRCODE = 'PT409'; END IF;

  IF p_kind = 'compressor' THEN
    v_table := 'compressors';
    INSERT INTO compressors (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, model,
                             serial_number, serial_number_raw, serial_status, job_number, part_number, total_running_hours, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(),
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'model'), ''), t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            nullif(btrim(p->>'job_number'), ''), nullif(btrim(p->>'part_number'), ''),
            (nullif(p->>'total_running_hours', ''))::numeric, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'dispenser' THEN
    v_table := 'dispensers';
    INSERT INTO dispensers (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, dispenser_name,
                            manufacturer, model, serial_number, serial_number_raw, serial_status, number_of_hoses, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(), nullif(btrim(p->>'dispenser_name'), ''),
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'model'), ''), t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            (nullif(p->>'number_of_hoses', ''))::int, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'storage_vessel' THEN
    v_table := 'storage_vessels';
    INSERT INTO storage_vessels (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, model,
                                 serial_number, serial_number_raw, serial_status, last_inspection_date, last_inspection_precision,
                                 next_inspection_date, next_inspection_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(),
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'model'), ''), t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            t_last, CASE WHEN t_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
            t_next, CASE WHEN t_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'recovery_tank' THEN
    v_table := 'recovery_tanks';
    INSERT INTO recovery_tanks (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, model,
                                serial_number, serial_number_raw, serial_status, last_inspection_date, last_inspection_precision,
                                next_inspection_date, next_inspection_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(),
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'model'), ''), t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            t_last, CASE WHEN t_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
            t_next, CASE WHEN t_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'gas_detector' THEN
    v_table := 'gas_detectors';
    INSERT INTO gas_detectors (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, model,
                               serial_number, serial_number_raw, serial_status, last_calibration_date, last_calibration_precision,
                               next_calibration_date, next_calibration_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(),
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'model'), ''), t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            t_last, CASE WHEN t_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
            t_next, CASE WHEN t_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'hose' THEN
    v_table := 'hoses';
    IF (p->>'working_pressure_unit') IS NOT NULL AND (p->>'working_pressure_unit') NOT IN ('BAR', 'PSI')
       OR (p->>'test_pressure_unit') IS NOT NULL AND (p->>'test_pressure_unit') NOT IN ('BAR', 'PSI') THEN
      RAISE EXCEPTION 'pressure unit must be BAR or PSI' USING ERRCODE = '22023';
    END IF;
    INSERT INTO hoses (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, description, serial_number,
                       serial_number_raw, serial_status, working_pressure_raw, working_pressure_value, working_pressure_unit,
                       test_pressure_raw, test_pressure_value, test_pressure_unit, last_test_date, last_test_precision,
                       next_test_date, next_test_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'resolved', v_actor, now(), nullif(btrim(p->>'description'), ''),
            t_serial, t_serial, CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            nullif(p->>'working_pressure_value', ''), (nullif(p->>'working_pressure_value', ''))::numeric,
            (nullif(p->>'working_pressure_unit', ''))::pressure_unit,
            nullif(p->>'test_pressure_value', ''), (nullif(p->>'test_pressure_value', ''))::numeric,
            (nullif(p->>'test_pressure_unit', ''))::pressure_unit,
            t_last, CASE WHEN t_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
            t_next, CASE WHEN t_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSIF p_kind = 'srv' THEN
    v_table := 'installed_relief_valves';
    IF v_min IS NOT NULL AND v_max < v_min THEN RAISE EXCEPTION 'pressure range is reversed' USING ERRCODE = '22023'; END IF;
    IF (p->>'pressure_unit') IS NOT NULL AND (p->>'pressure_unit') NOT IN ('BAR', 'PSI') THEN
      RAISE EXCEPTION 'pressure unit must be BAR or PSI' USING ERRCODE = '22023';
    END IF;
    IF t_last IS NOT NULL AND t_next IS NULL THEN t_next := (t_last + interval '1 year')::date; END IF;
    INSERT INTO installed_relief_valves (region_id, station_id, unit_id, mapping_status, serial_number, serial_number_raw,
                                         serial_status, manufacturer, part_number, size_type, inlet_size, outlet_size,
                                         set_pressure_raw, pressure_min, pressure_max, pressure_unit, warehouse_code,
                                         last_calibration_date, last_calibration_precision, next_calibration_date,
                                         next_calibration_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, v_unit.id, 'needs_equipment_mapping', t_serial, t_serial,
            CASE WHEN t_serial IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
            nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'part_number'), ''), nullif(btrim(p->>'size_type'), ''),
            nullif(btrim(p->>'inlet_size'), ''), nullif(btrim(p->>'outlet_size'), ''),
            CASE WHEN v_min IS NULL THEN NULL WHEN v_min = v_max THEN v_min::text ELSE v_min::text || '-' || v_max::text END,
            v_min, v_max, (nullif(p->>'pressure_unit', ''))::pressure_unit, nullif(btrim(p->>'warehouse_code'), ''),
            t_last, CASE WHEN t_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
            t_next, CASE WHEN t_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision, nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
  ELSE
    RAISE EXCEPTION 'unknown equipment kind %', p_kind USING ERRCODE = '22023';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', v_table, v_id, v_actor, 'admin_add_unit_asset',
          format('%s added to a Unit.', p_kind), NULL, p || jsonb_build_object('unit_id', v_unit.id), now());
  RETURN v_id;
END; $$;

COMMENT ON FUNCTION cng_admin_add_unit_asset(text, uuid, jsonb) IS
  'Admin only: add a compressor, dispenser, vessel, tank, detector, hose or installed relief valve to a Unit (owner request 2026-09-28). Placement from the Unit; status derived; audited.';
REVOKE ALL ON FUNCTION cng_admin_add_unit_asset(text, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_unit_asset(text, uuid, jsonb) TO authenticated;
