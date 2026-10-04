-- Where is this serial? (owner request 2026-10-04). Adding relief valves to the warehouse said "already in the warehouse"
-- for two serials the Warehouse tab did not show: the store sheet held them as AT STATION (sent to a station), and their
-- installed copies had been removed. The owner asked instead that a serial already somewhere in the system be refused
-- with WHERE it is — installed at a station, in the store, at the calibration company, awaiting return — on both add
-- paths (Warehouse "Add relief valves" and the Unit window's "Add relief valve").
--
-- cng_srv_serial_whereabouts(serials): every live record holding each serial (trimmed, case-insensitive), with its kind,
--   whether it blocks a new record, and a readable place. SECURITY INVOKER: from the browser it reads under the caller's RLS.
--   kind installed | warehouse | calibration | log block; sheet_sent (a store-sheet row AT STATION / IN TRANSIT with no
--   live installed valve of that serial) does not block — the add path closes that stale row.
-- cng_srv_serials_refuse_known(serials): raises 23505 listing each blocked serial and its place. Not callable from the browser.
-- No DROP; no table, column or policy change.

CREATE OR REPLACE FUNCTION cng_srv_serial_whereabouts(p_serials text[])
RETURNS TABLE (serial text, kind text, blocking boolean, place text, record_id uuid)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public AS $$
  WITH q AS (
    SELECT DISTINCT btrim(x) AS serial, lower(btrim(x)) AS k FROM unnest(p_serials) x WHERE nullif(btrim(x), '') IS NOT NULL
  ),
  installed AS (
    SELECT q.serial, 'installed'::text AS kind, true AS blocking,
           concat_ws(' · ', 'installed at ' || coalesce(u.unit_name, s.station_name, i.source_station_name_raw), r.name) AS place,
           i.id AS record_id
      FROM q JOIN installed_relief_valves i ON lower(btrim(i.serial_number)) = q.k AND i.archived_at IS NULL
      LEFT JOIN units u ON u.id = i.unit_id
      LEFT JOIN stations s ON s.id = i.station_id
      LEFT JOIN regions r ON r.id = i.region_id
  ),
  store AS (
    SELECT q.serial,
           CASE WHEN j.id IS NOT NULL THEN 'calibration'
                WHEN w.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN 'warehouse'
                ELSE 'sheet_sent' END AS kind,
           w.id AS record_id, w.availability_status,
           coalesce(tu.unit_name, ts.station_name, CASE WHEN w.destination_set_at IS NULL THEN w.source_raw->>'Station' END) AS dest
      FROM q JOIN warehouse_relief_valves w ON lower(btrim(w.serial_number)) = q.k AND w.archived_at IS NULL
      LEFT JOIN units tu ON tu.id = w.target_unit_id
      LEFT JOIN stations ts ON ts.id = w.target_station_id
      LEFT JOIN LATERAL (SELECT j.id FROM srv_calibration_jobs j
                          WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified' AND j.archived_at IS NULL LIMIT 1) j ON true
  ),
  label AS (
    SELECT * FROM (VALUES ('available_new', 'NEW'), ('available_calibrated', 'CALIBRATED'),
                          ('available_in_store_uc', 'UNDER CALIBRATION'), ('sent_to_station_received', 'AT STATION'),
                          ('sent_to_station_not_received', 'IN TRANSIT')) v(status, label)
  )
  SELECT * FROM installed
  UNION ALL
  SELECT st.serial, st.kind, st.kind <> 'sheet_sent',
         CASE st.kind WHEN 'calibration' THEN 'at the calibration company'
                      WHEN 'warehouse' THEN 'in the warehouse (' || l.label || ')'
                      ELSE concat_ws(' — ', 'store sheet: ' || l.label, st.dest) END,
         st.record_id
    FROM store st JOIN label l ON l.status = st.availability_status::text
   -- A sent-to-station sheet row whose valve is installed is the same valve: the installed record says where it is.
   WHERE st.kind <> 'sheet_sent' OR NOT EXISTS (SELECT 1 FROM installed i WHERE i.serial = st.serial)
  UNION ALL
  SELECT q.serial, 'log', true,
         concat_ws(' · ', 'awaiting return from ' || coalesce(f.unit_name, f.station_display), f.region_name), f.id
    FROM q JOIN v_srv_field_log f ON lower(btrim(f.serial_number)) = q.k AND f.status IN ('at_station', 'location_unconfirmed')
$$;
COMMENT ON FUNCTION cng_srv_serial_whereabouts(text[]) IS
  'Where each serial is held (owner request 2026-10-04): installed / warehouse / calibration / log block a new record; sheet_sent (store sheet AT STATION or IN TRANSIT with no live installed valve) does not. Security invoker.';
REVOKE ALL ON FUNCTION cng_srv_serial_whereabouts(text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_serial_whereabouts(text[]) TO authenticated;

CREATE OR REPLACE FUNCTION cng_srv_serials_refuse_known(p_serials text[])
RETURNS void LANGUAGE plpgsql STABLE SET search_path = pg_catalog, public AS $$
DECLARE v_msg text;
BEGIN
  SELECT string_agg(serial || ' — ' || places, '; ' ORDER BY serial) INTO v_msg
    FROM (SELECT serial, string_agg(DISTINCT place, ', ') AS places
            FROM cng_srv_serial_whereabouts(p_serials) WHERE blocking GROUP BY serial) b;
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION 'already recorded: %', v_msg USING ERRCODE = '23505';
  END IF;
END; $$;
REVOKE ALL ON FUNCTION cng_srv_serials_refuse_known(text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION cng_admin_add_warehouse_srvs(p jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_actor uuid := cng_require_admin();
  v_status text := p->>'availability';
  v_serials text[];
  v_qty int := coalesce((p->>'quantity')::int, 0);
  v_min numeric := (p->>'pressure_min')::numeric;
  v_max numeric := coalesce((p->>'pressure_max')::numeric, (p->>'pressure_min')::numeric);
  v_last date := (p->>'last_calibration_date')::date;
  v_next date := (p->>'next_calibration_date')::date;
  v_closed jsonb;
  v_ids uuid[] := '{}';
  v_id uuid;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_default record;
  d record;
  s text;
BEGIN
  IF v_status IS NULL OR v_status NOT IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN
    RAISE EXCEPTION 'choose the condition: new, calibrated or under calibration' USING ERRCODE = '22023';
  END IF;
  -- Per-serial rows win; plain serials are rows with no destination of their own.
  IF jsonb_typeof(p->'items') = 'array' AND jsonb_array_length(p->'items') > 0 THEN
    SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO v_items
      FROM jsonb_array_elements(p->'items') x WHERE btrim(coalesce(x->>'serial', '')) <> '';
  ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object('serial', x)), '[]'::jsonb) INTO v_items
      FROM jsonb_array_elements_text(coalesce(p->'serials', '[]'::jsonb)) x WHERE btrim(x) <> '';
  END IF;
  SELECT coalesce(array_agg(btrim(x->>'serial')), '{}') INTO v_serials FROM jsonb_array_elements(v_items) x;
  IF cardinality(v_serials) <> (SELECT count(DISTINCT x) FROM unnest(v_serials) x) THEN
    RAISE EXCEPTION 'the same serial is listed twice' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) = 0 AND v_qty < 1 THEN
    RAISE EXCEPTION 'give at least one serial, or a quantity for valves without a serial' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) > 0 AND v_qty > 0 THEN
    RAISE EXCEPTION 'give serials or a quantity, not both' USING ERRCODE = '22023';
  END IF;
  IF v_qty > 500 OR cardinality(v_serials) > 500 THEN
    RAISE EXCEPTION 'at most 500 valves at once' USING ERRCODE = '22023';
  END IF;
  IF v_min IS NOT NULL AND v_max < v_min THEN RAISE EXCEPTION 'pressure range is reversed' USING ERRCODE = '22023'; END IF;
  IF (p->>'pressure_unit') IS NOT NULL AND (p->>'pressure_unit') NOT IN ('BAR', 'PSI') THEN
    RAISE EXCEPTION 'pressure unit must be BAR or PSI' USING ERRCODE = '22023';
  END IF;
  -- Owner request 2026-10-04: a serial already somewhere in the system (installed, in the store, at calibration,
  -- awaiting return) is refused, saying where. A store-sheet row that only says the valve was SENT to a station, with
  -- no live installed valve behind it, is not a place: it is closed (archived, audited) and the valve is added anew.
  PERFORM cng_srv_serials_refuse_known(v_serials);
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', k.record_id, 'serial', k.serial, 'was', k.place)), '[]'::jsonb) INTO v_closed
    FROM cng_srv_serial_whereabouts(v_serials) k WHERE k.kind = 'sheet_sent';
  UPDATE warehouse_relief_valves w SET archived_at = now()
   WHERE w.id IN (SELECT (x->>'id')::uuid FROM jsonb_array_elements(v_closed) x);
  -- The owner rule for a calibration certificate: due again one year later.
  IF v_last IS NOT NULL AND v_next IS NULL THEN v_next := (v_last + interval '1 year')::date; END IF;
  SELECT * INTO v_default FROM cng_wrv_resolve_destination(nullif(p->>'station_id', '')::uuid, nullif(p->>'unit_id', '')::uuid);

  FOR v_item IN
    SELECT x FROM jsonb_array_elements(v_items) x
    UNION ALL SELECT '{}'::jsonb FROM generate_series(1, CASE WHEN cardinality(v_serials) = 0 THEN v_qty ELSE 0 END)
  LOOP
    s := nullif(btrim(v_item->>'serial'), '');
    IF nullif(v_item->>'station_id', '') IS NOT NULL OR nullif(v_item->>'unit_id', '') IS NOT NULL THEN
      SELECT * INTO d FROM cng_wrv_resolve_destination(nullif(v_item->>'station_id', '')::uuid, nullif(v_item->>'unit_id', '')::uuid);
    ELSE
      d := v_default;
    END IF;
    INSERT INTO warehouse_relief_valves (
      availability_status, serial_number, serial_number_raw, serial_status, manufacturer, part_number,
      size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
      warehouse_code, last_calibration_date, last_calibration_precision, next_calibration_date, next_calibration_precision,
      notes, target_station_id, target_region_id, target_unit_id, destination_set_at)
    VALUES (
      v_status::warehouse_availability, s, s, CASE WHEN s IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
      nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'part_number'), ''),
      nullif(btrim(p->>'size_type'), ''), nullif(btrim(p->>'inlet_size'), ''), nullif(btrim(p->>'outlet_size'), ''),
      CASE WHEN v_min IS NULL THEN NULL WHEN v_min = v_max THEN v_min::text ELSE v_min::text || '-' || v_max::text END,
      v_min, v_max, (p->>'pressure_unit')::pressure_unit,
      nullif(btrim(p->>'warehouse_code'), ''),
      v_last, CASE WHEN v_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      v_next, CASE WHEN v_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      nullif(btrim(p->>'notes'), ''), d.station_id, d.region_id, d.unit_id,
      CASE WHEN d.station_id IS NOT NULL THEN now() END)
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', 'warehouse_relief_valves', v_ids[1], v_actor, 'admin_add_warehouse_srvs',
          format('%s relief valve(s) added to the warehouse (%s).', cardinality(v_ids), v_status), NULL,
          p || jsonb_build_object('ids', to_jsonb(v_ids), 'closed_sheet_rows', v_closed), now());
  RETURN cardinality(v_ids);
END; $function$;
REVOKE ALL ON FUNCTION cng_admin_add_warehouse_srvs(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_warehouse_srvs(jsonb) TO authenticated;

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
    -- Ruling 6y: a storage vessel belongs to the Station (it may feed several Units), so no Unit is recorded.
    INSERT INTO storage_vessels (region_id, station_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, model,
                                 serial_number, serial_number_raw, serial_status, last_inspection_date, last_inspection_precision,
                                 next_inspection_date, next_inspection_precision, notes)
    VALUES (v_unit.region_id, v_unit.station_id, NULL, 'resolved', v_actor, now(),
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
    -- Owner request 2026-10-04: a serial already somewhere in the system is refused, saying where it is.
    PERFORM cng_srv_serials_refuse_known(ARRAY[t_serial]);
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
          format(CASE WHEN p_kind = 'storage_vessel' THEN '%s added to the Station (from a Unit).' ELSE '%s added to a Unit.' END, p_kind), NULL, p || jsonb_build_object('unit_id', v_unit.id), now());
  RETURN v_id;
END; $$;
REVOKE ALL ON FUNCTION cng_admin_add_unit_asset(text, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_unit_asset(text, uuid, jsonb) TO authenticated;
