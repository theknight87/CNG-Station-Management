-- merge_station.sql — merge one Station into another and delete it permanently (owner request 2026-10-06:
-- "دمنهور الموقف ودمنهور ادمج بيانتهم خليهم محطة واحدة اسمها دمنهور الموقف والغي التانية خالص امسحها من ال database";
-- confirmed "ايوة امسحها نهائي").
--
-- Data only, no migration. Run as ONE call (it is one transaction): it defines a session-temporary function and calls it.
-- Everything that points at the dropped Station moves to the kept one — its Units (with everything on them), Station-level
-- equipment, store destinations, SRV issues / Log, alerts, import lineage and decisions, aliases — then the dropped Station
-- row is DELETED. The kept Station's empty fields (notes, bay status) are filled from the dropped one. One audit row
-- (record_deleted, entity stations/<dropped id>) keeps the deleted row and what moved; history rows in audit_logs that name
-- the old id are left as they are (they are history).
--
-- It REFUSES, changing nothing, when: either name does not match exactly one Station; the two are in different Regions; or a
-- Unit of the dropped Station has the same name as one of the kept Station (that needs the owner to say which is which).

CREATE OR REPLACE FUNCTION pg_temp.cng_merge_station(p_keep text, p_drop text, p_label text) RETURNS jsonb
LANGUAGE plpgsql AS $$
DECLARE
  k stations; d stations;
  v_actor uuid;
  v_clash text;
  v_units jsonb;
  v_moved jsonb;
  v_wrv_units jsonb;
BEGIN
  IF (SELECT count(*) FROM stations WHERE normalized_name = cng_normalize_name(p_keep)) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one Station named %', p_keep;
  END IF;
  IF (SELECT count(*) FROM stations WHERE normalized_name = cng_normalize_name(p_drop)) <> 1 THEN
    RAISE EXCEPTION 'expected exactly one Station named %', p_drop;
  END IF;
  SELECT * INTO k FROM stations WHERE normalized_name = cng_normalize_name(p_keep);
  SELECT * INTO d FROM stations WHERE normalized_name = cng_normalize_name(p_drop);
  IF k.id = d.id THEN RAISE EXCEPTION 'the two names are the same Station'; END IF;
  IF k.region_id <> d.region_id THEN RAISE EXCEPTION 'the two Stations are in different Regions; nothing was changed'; END IF;

  SELECT string_agg(du.unit_name, ', ') INTO v_clash
    FROM units du JOIN units ku ON ku.station_id = k.id AND ku.normalized_name = du.normalized_name
   WHERE du.station_id = d.id;
  IF v_clash IS NOT NULL THEN RAISE EXCEPTION 'both Stations have a Unit named: % — the owner must say which is which', v_clash; END IF;

  SELECT id INTO v_actor FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;

  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'unit_name', unit_name) ORDER BY unit_name), '[]') INTO v_units
    FROM units WHERE station_id = d.id;
  -- A store valve's destination Unit is cleared by wrv_unit_follows_station when its Station changes; keep it to put back.
  SELECT coalesce(jsonb_agg(jsonb_build_object('id', id, 'unit', target_unit_id)), '[]') INTO v_wrv_units
    FROM warehouse_relief_valves WHERE target_station_id = d.id AND target_unit_id IS NOT NULL;

  -- ONE statement, so the composite (station, unit) foreign keys are checked only after the Units and everything on them moved.
  WITH
    u   AS (UPDATE units SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    c   AS (UPDATE compressors SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    dp  AS (UPDATE dispensers SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    sv  AS (UPDATE storage_vessels SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    rt  AS (UPDATE recovery_tanks SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    gd  AS (UPDATE gas_detectors SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    gp  AS (UPDATE gas_detector_presence SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    ho  AS (UPDATE hoses SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    irv AS (UPDATE installed_relief_valves SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    wrv AS (UPDATE warehouse_relief_valves SET target_station_id = k.id WHERE target_station_id = d.id RETURNING 1),
    al  AS (UPDATE alerts SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    ii  AS (UPDATE import_issues SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    isr AS (UPDATE import_staging_rows
               SET station_id = CASE WHEN station_id = d.id THEN k.id ELSE station_id END,
                   committed_entity_id = CASE WHEN committed_entity_kind = 'station' AND committed_entity_id = d.id THEN k.id
                                              ELSE committed_entity_id END
             WHERE station_id = d.id OR (committed_entity_kind = 'station' AND committed_entity_id = d.id) RETURNING 1),
    imd AS (UPDATE import_mapping_decisions SET confirmed_station_id = k.id WHERE confirmed_station_id = d.id RETURNING 1),
    sa  AS (UPDATE station_aliases SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    ua  AS (UPDATE unit_aliases SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    ama AS (UPDATE asset_mapping_audit
               SET previous_station_id = CASE WHEN previous_station_id = d.id THEN k.id ELSE previous_station_id END,
                   new_station_id = CASE WHEN new_station_id = d.id THEN k.id ELSE new_station_id END
             WHERE previous_station_id = d.id OR new_station_id = d.id RETURNING 1),
    si  AS (UPDATE srv_issues SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    sfl AS (UPDATE srv_field_log SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    ei  AS (UPDATE equipment_issues SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    efl AS (UPDATE equipment_field_log SET station_id = k.id WHERE station_id = d.id RETURNING 1),
    es  AS (UPDATE equipment_stock SET target_station_id = k.id WHERE target_station_id = d.id RETURNING 1),
    ph  AS (UPDATE asset_photos SET entity_id = k.id WHERE entity_table = 'stations' AND entity_id = d.id RETURNING 1)
  SELECT jsonb_build_object(
      'units', (SELECT count(*) FROM u), 'compressors', (SELECT count(*) FROM c), 'dispensers', (SELECT count(*) FROM dp),
      'storage_vessels', (SELECT count(*) FROM sv), 'recovery_tanks', (SELECT count(*) FROM rt),
      'gas_detectors', (SELECT count(*) FROM gd), 'gas_detector_presence', (SELECT count(*) FROM gp), 'hoses', (SELECT count(*) FROM ho),
      'installed_relief_valves', (SELECT count(*) FROM irv), 'warehouse_destinations', (SELECT count(*) FROM wrv),
      'alerts', (SELECT count(*) FROM al), 'import_issues', (SELECT count(*) FROM ii), 'import_staging_rows', (SELECT count(*) FROM isr),
      'import_mapping_decisions', (SELECT count(*) FROM imd), 'station_aliases', (SELECT count(*) FROM sa),
      'unit_aliases', (SELECT count(*) FROM ua), 'asset_mapping_audit', (SELECT count(*) FROM ama),
      'srv_issues', (SELECT count(*) FROM si), 'srv_field_log', (SELECT count(*) FROM sfl),
      'equipment_issues', (SELECT count(*) FROM ei), 'equipment_field_log', (SELECT count(*) FROM efl),
      'equipment_stock', (SELECT count(*) FROM es), 'photos', (SELECT count(*) FROM ph))
    INTO v_moved;

  -- Put back the destination Units the trigger cleared (those Units moved with the Station, so they still apply).
  UPDATE warehouse_relief_valves w SET target_unit_id = (x->>'unit')::uuid
    FROM jsonb_array_elements(v_wrv_units) x WHERE w.id = (x->>'id')::uuid;

  UPDATE stations SET notes = coalesce(k.notes, d.notes), bay_status = coalesce(k.bay_status, d.bay_status),
                      bay_status_raw = coalesce(k.bay_status_raw, d.bay_status_raw)
   WHERE id = k.id;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', 'stations', d.id, v_actor, p_label,
          format('Station %s merged into %s and deleted permanently (owner request).', d.station_name, k.station_name),
          to_jsonb(d), jsonb_build_object('merged_into', k.id, 'merged_into_name', k.station_name, 'units_moved', v_units, 'moved', v_moved),
          now());

  DELETE FROM stations WHERE id = d.id;

  RETURN jsonb_build_object('kept', k.station_name, 'kept_id', k.id, 'deleted', d.station_name, 'deleted_id', d.id,
                            'units_moved', v_units, 'moved', v_moved);
END $$;

SELECT pg_temp.cng_merge_station('دمنهور الموقف', 'دمنهور', 'owner_ruling:2026-10-06');
