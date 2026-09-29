-- A valve received back from a station keeps its warehouse record (owner report 2026-09-29).
--
-- The owner issued valves to ابو المطامير, received the replaced ones back and sent them to 3rd party calibration: the
-- calibration form showed them with NO P/N and NO warehouse code. Cause, confirmed read-only in production: the
-- replaced valve was an INSTALLED record (from the installed-SRV workbook, which carries no P/N and no code), and
-- cng_srv_log_receive built a brand-new warehouse record from it. The SAME valve (same serial) already had a warehouse
-- record — with its P/N and code (e.g. 257854: 240-05a-12, sbc 87) — left behind as "sent to station".
--
-- Owner ruling 2026-09-24 (phase 6p): a valve is its serial. So:
--
-- (1) cng_srv_log_receive: when the returning installed valve has a serial and EXACTLY ONE live warehouse record carries
--     that serial in a "sent to station" state, that record IS the valve: it comes back to the store as under
--     calibration (the existing trigger turns sbc 87 into sbu 87), only its EMPTY fields are filled from the installed
--     record (nothing recorded is overwritten), and its own open SRV Log entries are closed as returned. No match, or
--     more than one (ambiguous), keeps the previous behaviour: a new warehouse record. Everything else is the deployed
--     body (md5 of prosrc b008229b… identical in production and the repository).
--
-- (2) One-time repair of records already received this way (4 in production: 257854, 250782, 1237088, 99/25218, each
--     with exactly one same-serial "sent to station" record). The RETURNED record is kept, because it carries the
--     receipt history and any calibration entry; its EMPTY fields are filled from the old record, the old record is
--     archived (never deleted; it keeps its source provenance) and its open SRV Log entries are closed as returned to
--     the kept record. Each repair writes a history row and an audit row with before/after. The rule is evaluated
--     here, server-side; no id is supplied.

CREATE OR REPLACE FUNCTION public.cng_srv_log_receive(p_log_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor uuid := cng_require_admin(); l srv_field_log; o installed_relief_valves; v_wh uuid; n int := 0;
        v_match uuid; v_matches int; v_linked boolean;
BEGIN
  IF p_log_ids IS NULL OR cardinality(p_log_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM srv_field_log WHERE id = ANY (p_log_ids) AND returned_at IS NULL)
     <> (SELECT count(DISTINCT x) FROM unnest(p_log_ids) x) THEN
    RAISE EXCEPTION 'some selected valves were already received or are not in the SRV Log; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  FOR l IN SELECT * FROM srv_field_log WHERE id = ANY (p_log_ids) ORDER BY logged_at, id FOR UPDATE LOOP
    v_linked := false;
    IF l.warehouse_valve_id IS NOT NULL THEN
      v_wh := l.warehouse_valve_id;
      UPDATE warehouse_relief_valves
         SET availability_status = 'available_in_store_uc', target_region_id = NULL, target_station_id = NULL
       WHERE id = v_wh;
    ELSE
      SELECT * INTO o FROM installed_relief_valves WHERE id = l.installed_valve_id;
      -- A valve is its serial (6p): exactly one live warehouse record "sent to station" with this serial is this valve.
      v_matches := 0; v_match := NULL;
      IF nullif(btrim(o.serial_number), '') IS NOT NULL THEN
        SELECT count(*), (array_agg(w.id))[1] INTO v_matches, v_match
          FROM warehouse_relief_valves w
         WHERE w.archived_at IS NULL AND btrim(w.serial_number) = btrim(o.serial_number)
           AND w.availability_status IN ('sent_to_station_received', 'sent_to_station_not_received');
      END IF;
      IF v_matches = 1 THEN
        v_wh := v_match;
        v_linked := true;
        PERFORM 1 FROM warehouse_relief_valves WHERE id = v_wh FOR UPDATE;
        UPDATE warehouse_relief_valves w
           SET availability_status = 'available_in_store_uc', target_region_id = NULL, target_station_id = NULL,
               manufacturer = coalesce(w.manufacturer, o.manufacturer),
               manufacturer_raw = coalesce(w.manufacturer_raw, o.manufacturer_raw),
               part_number = coalesce(w.part_number, o.part_number),
               size_type = coalesce(w.size_type, o.size_type),
               inlet_size = coalesce(w.inlet_size, o.inlet_size),
               outlet_size = coalesce(w.outlet_size, o.outlet_size),
               set_pressure_raw = CASE WHEN w.pressure_min IS NULL AND w.pressure_max IS NULL THEN o.set_pressure_raw ELSE w.set_pressure_raw END,
               pressure_min = CASE WHEN w.pressure_min IS NULL AND w.pressure_max IS NULL THEN o.pressure_min ELSE w.pressure_min END,
               pressure_max = CASE WHEN w.pressure_min IS NULL AND w.pressure_max IS NULL THEN o.pressure_max ELSE w.pressure_max END,
               pressure_unit = CASE WHEN w.pressure_min IS NULL AND w.pressure_max IS NULL THEN o.pressure_unit ELSE w.pressure_unit END,
               warehouse_code = coalesce(w.warehouse_code, o.warehouse_code,
                                         (SELECT vi.warehouse_code FROM v_installed_srv_management vi WHERE vi.id = o.id))
         WHERE w.id = v_wh;
        -- It is physically back: its own "sent to this station" SRV Log entries are closed, returned to the same record.
        UPDATE srv_field_log SET returned_at = now(), returned_by = v_actor, returned_warehouse_valve_id = v_wh
         WHERE warehouse_valve_id = v_wh AND returned_at IS NULL AND archived_at IS NULL AND id <> l.id;
      ELSE
        v_wh := gen_random_uuid();
        INSERT INTO warehouse_relief_valves (
          id, availability_status, serial_number, serial_number_raw, serial_status, manufacturer, manufacturer_raw,
          part_number, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
          last_calibration_raw, last_calibration_date, last_calibration_precision,
          next_calibration_raw, next_calibration_date, next_calibration_precision, warehouse_code, notes)
        VALUES (
          v_wh, 'available_in_store_uc', o.serial_number, o.serial_number_raw, o.serial_status, o.manufacturer, o.manufacturer_raw,
          o.part_number, o.size_type, o.inlet_size, o.outlet_size, o.set_pressure_raw, o.pressure_min, o.pressure_max, o.pressure_unit,
          o.last_calibration_raw, o.last_calibration_date, o.last_calibration_precision,
          o.next_calibration_raw, o.next_calibration_date, o.next_calibration_precision,
          coalesce(o.warehouse_code, (SELECT vi.warehouse_code FROM v_installed_srv_management vi WHERE vi.id = o.id)),
          'Returned from the station (SRV Log)');
      END IF;
    END IF;
    UPDATE srv_field_log SET returned_at = now(), returned_by = v_actor, returned_warehouse_valve_id = v_wh WHERE id = l.id;
    INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (v_wh, l.installed_valve_id, NULL, 'received',
            CASE WHEN v_linked THEN 'Received back at the warehouse (same serial as its warehouse record); now available, under calibration'
                 ELSE 'Received back at the warehouse; now available, under calibration' END,
            jsonb_build_object('log_id', l.id, 'from_region_id', l.region_id, 'from_station_id', l.station_id, 'linked_by_serial', v_linked), v_actor);
    n := n + 1;
  END LOOP;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_field_log', NULL, v_actor, 'srv_log_receive',
          format('%s SRV(s) received back at the warehouse from the SRV Log', n), NULL,
          jsonb_build_object('log_ids', to_jsonb(p_log_ids)), now());
  RETURN n;
END;
$function$;

-- (2) One-time repair of valves already received as a second record. A named function so the regression suite can run
-- it against constructed data; service_role only (no browser path), called once at the end of this migration.
CREATE OR REPLACE FUNCTION public.cng_srv_receive_serial_repair()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE r record; v_before jsonb; v_old jsonb; n int := 0; v_by uuid; v_at timestamptz;
BEGIN
  FOR r IN
    SELECT k.id AS keep_id, s.id AS old_id
      FROM warehouse_relief_valves k
      JOIN LATERAL (
        SELECT s.id, count(*) OVER () AS n
          FROM warehouse_relief_valves s
         WHERE s.archived_at IS NULL AND s.id <> k.id AND nullif(btrim(k.serial_number), '') IS NOT NULL
           AND btrim(s.serial_number) = btrim(k.serial_number)
           AND s.availability_status IN ('sent_to_station_received', 'sent_to_station_not_received')
      ) s ON s.n = 1
     WHERE k.archived_at IS NULL
       AND EXISTS (SELECT 1 FROM srv_field_log l WHERE l.returned_warehouse_valve_id = k.id AND l.warehouse_valve_id IS NULL)
       AND NOT EXISTS (SELECT 1 FROM srv_field_log l WHERE l.returned_warehouse_valve_id = k.id AND l.warehouse_valve_id IS NOT NULL)
  LOOP
    -- Who received the valve and when: the SRV Log receipt that created the kept record (the physical return).
    SELECT l.returned_by, l.returned_at INTO v_by, v_at FROM srv_field_log l
     WHERE l.returned_warehouse_valve_id = r.keep_id AND l.warehouse_valve_id IS NULL ORDER BY l.returned_at DESC LIMIT 1;
    SELECT to_jsonb(w) INTO v_before FROM warehouse_relief_valves w WHERE w.id = r.keep_id FOR UPDATE;
    SELECT to_jsonb(w) INTO v_old FROM warehouse_relief_valves w WHERE w.id = r.old_id FOR UPDATE;
    UPDATE warehouse_relief_valves k
       SET manufacturer = coalesce(k.manufacturer, s.manufacturer),
           manufacturer_raw = coalesce(k.manufacturer_raw, s.manufacturer_raw),
           part_number = coalesce(k.part_number, s.part_number),
           size_type = coalesce(k.size_type, s.size_type),
           inlet_size = coalesce(k.inlet_size, s.inlet_size),
           outlet_size = coalesce(k.outlet_size, s.outlet_size),
           set_pressure_raw = CASE WHEN k.pressure_min IS NULL AND k.pressure_max IS NULL THEN s.set_pressure_raw ELSE k.set_pressure_raw END,
           pressure_min = CASE WHEN k.pressure_min IS NULL AND k.pressure_max IS NULL THEN s.pressure_min ELSE k.pressure_min END,
           pressure_max = CASE WHEN k.pressure_min IS NULL AND k.pressure_max IS NULL THEN s.pressure_max ELSE k.pressure_max END,
           pressure_unit = CASE WHEN k.pressure_min IS NULL AND k.pressure_max IS NULL THEN s.pressure_unit ELSE k.pressure_unit END,
           warehouse_code = coalesce(k.warehouse_code, s.warehouse_code)
      FROM warehouse_relief_valves s
     WHERE k.id = r.keep_id AND s.id = r.old_id;
    UPDATE warehouse_relief_valves SET archived_at = now() WHERE id = r.old_id;
    UPDATE srv_field_log SET returned_at = v_at, returned_by = v_by, returned_warehouse_valve_id = r.keep_id
     WHERE warehouse_valve_id = r.old_id AND returned_at IS NULL AND archived_at IS NULL;
    INSERT INTO srv_history (warehouse_valve_id, event, summary, details, actor_id)
    VALUES (r.keep_id, 'received', 'Linked to its earlier warehouse record by serial; P/N and warehouse code restored',
            jsonb_build_object('merged_warehouse_valve_id', r.old_id, 'migration', '20260929110000'), v_by);
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
    VALUES ('admin_action', 'warehouse_relief_valves', r.keep_id, NULL, 'migration:srv_receive_links_serial',
            format('Returned valve %s linked by serial to its earlier warehouse record %s (archived); empty fields filled from it',
                   v_before->>'serial_number', r.old_id),
            jsonb_build_object('kept', v_before, 'archived', v_old),
            (SELECT to_jsonb(w) FROM warehouse_relief_valves w WHERE w.id = r.keep_id), now());
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$function$;

REVOKE ALL ON FUNCTION public.cng_srv_receive_serial_repair() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.cng_srv_receive_serial_repair() TO service_role;

SELECT public.cng_srv_receive_serial_repair();
