-- merge_damanhour.sql — owner 2026-10-06: merge Station دمنهور into دمنهور الموقف as ONE Station with ONE Unit, and delete
-- دمنهور permanently ("ادمج دمنهور في دمنهور الموقف، مسح نهائي للتانية"; "yes its a single unit").
--
-- Data only, no migration. Paste the whole file into the Supabase SQL editor of project cng-station-management
-- (ypkggegquetvpsflkaxg) and run it once. It is ONE transaction: it either does everything or nothing.
--
--   * Unit دمنهور's contents go onto Unit دمنهور الموقف: 13 installed SRVs (its 10 Stage SRVs onto the SAFE compressor),
--     5 recovery tanks, 3 Station-level storage vessels, 2 store destinations, 4 alerts.
--   * Unit دمنهور's compressor was a placeholder (owner rule 6r: no model, no serial) and is deleted; دمنهور الموقف keeps its SAFE compressor.
--   * The old compressor, Unit and Station are deleted; three record_deleted audit rows keep each deleted row in full.
-- Dry run on production (without the deletes, rolled back) passed on 2026-10-06. The ids are fixed: if any no longer
-- matches (already run, or changed), the script stops with an error and changes nothing.

DO $$
DECLARE
  ks uuid := '8e19db29-99cd-454f-8199-61987e94625b'; ds uuid := '58c2b19e-afac-44e9-b2c3-ae65ba1314cb';
  ku uuid := 'c9422bd9-2776-479f-9f52-4eda33ee9b95'; du uuid := 'cd7a60a8-5f3e-4947-b302-56b9d6ab8505';
  kc uuid := 'de2cc415-6e08-42e9-a9a9-2f6e760455c0'; dc uuid := 'c426952d-bb1a-4d02-abf3-ed165069f1db';
  v jsonb := '{}'; n int; v_actor uuid; v_wrv uuid[]; d_station jsonb; d_unit jsonb; d_comp jsonb;
BEGIN
  SELECT to_jsonb(s) INTO STRICT d_station FROM stations s WHERE id = ds AND station_name = 'دمنهور';
  SELECT to_jsonb(u) INTO STRICT d_unit FROM units u WHERE id = du AND station_id = ds;
  SELECT to_jsonb(c) INTO STRICT d_comp FROM compressors c WHERE id = dc AND unit_id = du;
  PERFORM 1 FROM units WHERE id = ku AND station_id = ks; IF NOT FOUND THEN RAISE EXCEPTION 'kept unit'; END IF;
  PERFORM 1 FROM compressors WHERE id = kc AND unit_id = ku; IF NOT FOUND THEN RAISE EXCEPTION 'kept compressor'; END IF;
  SELECT id INTO v_actor FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;

  -- Equipment and its SRVs in ONE statement: the composite (vessel/compressor, station/unit) keys are checked at its end.
  WITH
    irv AS (UPDATE installed_relief_valves SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END,
                   compressor_id = CASE WHEN compressor_id = dc THEN kc ELSE compressor_id END WHERE station_id = ds RETURNING 1),
    sv  AS (UPDATE storage_vessels SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1),
    rt  AS (UPDATE recovery_tanks SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1),
    dp  AS (UPDATE dispensers SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1),
    gd  AS (UPDATE gas_detectors SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1),
    gp  AS (UPDATE gas_detector_presence SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1),
    ho  AS (UPDATE hoses SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds RETURNING 1)
  SELECT jsonb_build_object('installed_relief_valves', (SELECT count(*) FROM irv), 'storage_vessels', (SELECT count(*) FROM sv),
         'recovery_tanks', (SELECT count(*) FROM rt), 'dispensers', (SELECT count(*) FROM dp), 'gas_detectors', (SELECT count(*) FROM gd),
         'gas_detector_presence', (SELECT count(*) FROM gp), 'hoses', (SELECT count(*) FROM ho)) INTO v;

  SELECT array_agg(id) INTO v_wrv FROM warehouse_relief_valves WHERE target_unit_id = du;
  UPDATE warehouse_relief_valves SET target_station_id = ks, target_unit_id = CASE WHEN target_unit_id = du THEN ku ELSE target_unit_id END
   WHERE target_station_id = ds;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('warehouse_destinations', n);
  UPDATE warehouse_relief_valves SET target_unit_id = ku WHERE id = ANY (coalesce(v_wrv, '{}')) AND target_unit_id IS DISTINCT FROM ku;

  UPDATE unit_aliases SET station_id = ks, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('unit_aliases', n);
  UPDATE station_aliases SET station_id = ks WHERE station_id = ds; GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('station_aliases', n);
  UPDATE alerts SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END
   WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('alerts', n);
  UPDATE import_issues SET station_id = ks WHERE station_id = ds; GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('import_issues', n);
  UPDATE import_staging_rows
     SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END,
         unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END,
         committed_entity_id = CASE WHEN committed_entity_kind = 'station' AND committed_entity_id = ds THEN ks
                                    WHEN committed_entity_kind = 'unit' AND committed_entity_id = du THEN ku
                                    WHEN committed_entity_kind = 'compressor' AND committed_entity_id = dc THEN kc
                                    ELSE committed_entity_id END
   WHERE station_id = ds OR unit_id = du OR committed_entity_id IN (ds, du, dc);
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('import_staging_rows', n);
  UPDATE import_mapping_decisions SET confirmed_station_id = ks, confirmed_unit_id = CASE WHEN confirmed_unit_id = du THEN ku ELSE confirmed_unit_id END
   WHERE confirmed_station_id = ds;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('import_mapping_decisions', n);
  UPDATE asset_mapping_audit
     SET previous_station_id = CASE WHEN previous_station_id = ds THEN ks ELSE previous_station_id END,
         new_station_id = CASE WHEN new_station_id = ds THEN ks ELSE new_station_id END,
         previous_unit_id = CASE WHEN previous_unit_id = du THEN ku ELSE previous_unit_id END,
         new_unit_id = CASE WHEN new_unit_id = du THEN ku ELSE new_unit_id END
   WHERE ds IN (previous_station_id, new_station_id) OR du IN (previous_unit_id, new_unit_id);
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('asset_mapping_audit', n);
  UPDATE srv_issues SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END
   WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('srv_issues', n);
  UPDATE srv_field_log SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END
   WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('srv_field_log', n);
  UPDATE equipment_issues SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END
   WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('equipment_issues', n);
  UPDATE equipment_field_log SET station_id = CASE WHEN station_id = ds THEN ks ELSE station_id END, unit_id = CASE WHEN unit_id = du THEN ku ELSE unit_id END
   WHERE station_id = ds OR unit_id = du;
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('equipment_field_log', n);
  UPDATE equipment_stock SET target_station_id = ks WHERE target_station_id = ds; GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('equipment_stock', n);
  UPDATE asset_photos SET entity_id = CASE entity_id WHEN ds THEN ks WHEN du THEN ku WHEN dc THEN kc END
   WHERE (entity_table = 'stations' AND entity_id = ds) OR (entity_table = 'units' AND entity_id = du) OR (entity_table = 'compressors' AND entity_id = dc);
  GET DIAGNOSTICS n = ROW_COUNT; v := v || jsonb_build_object('photos', n);

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at) VALUES
   ('record_deleted', 'compressors', dc, v_actor, 'owner_ruling:2026-10-06', 'Placeholder compressor of Unit دمنهور merged into the compressor of دمنهور الموقف (owner: one Station, one Unit).', d_comp, jsonb_build_object('merged_into', kc), now()),
   ('record_deleted', 'units', du, v_actor, 'owner_ruling:2026-10-06', 'Unit دمنهور merged into Unit دمنهور الموقف and deleted (owner: one Station, one Unit).', d_unit, jsonb_build_object('merged_into', ku), now()),
   ('record_deleted', 'stations', ds, v_actor, 'owner_ruling:2026-10-06', 'Station دمنهور merged into دمنهور الموقف and deleted permanently (owner request).', d_station, jsonb_build_object('merged_into', ks, 'moved', v), now());
  DELETE FROM compressors WHERE id = dc;
  DELETE FROM units WHERE id = du;
  DELETE FROM stations WHERE id = ds;
END $$;
