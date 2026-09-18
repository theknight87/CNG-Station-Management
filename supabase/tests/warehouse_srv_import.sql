\set ON_ERROR_STOP on
SET client_min_messages TO notice;
CREATE OR REPLACE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE OR REPLACE FUNCTION pg_temp.refused(l text, s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE s; RAISE NOTICE 'FAILED: % (accepted)', l;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PASS  % refused [%]', l, SQLSTATE; END $$;
\set RUN '''cccc1111-2222-3333-4444-555566667777'''

CREATE TEMP TABLE pv AS SELECT * FROM cng_wrv_import_preview(:RUN::uuid);
CREATE TEMP TABLE base AS SELECT
  (SELECT count(*) FROM installed_relief_valves) irv,
  (SELECT count(*) FROM installed_relief_valves WHERE station_id IS NOT NULL) irv_st,
  (SELECT count(*) FROM storage_vessels) sv, (SELECT count(*) FROM recovery_tanks) rt,
  (SELECT count(*) FROM gas_detectors) gd, (SELECT count(*) FROM hoses) ho,
  (SELECT count(*) FROM stations) st, (SELECT count(*) FROM units) un;

SELECT pg_temp.ck('WRV-1  preview: 2,188 eligible, 0 excluded, 0 already, 0 invalid',
  (SELECT eligible_rows=2188 AND excluded_rows=0 AND already_imported=0 AND invalid_evidence=0 FROM pv));
SELECT pg_temp.ck('WRV-2  2,188 distinct keys and 2,188 distinct hashes, 0 duplicates, 0 bad hashes',
  (SELECT distinct_source_keys=2188 AND distinct_source_hashes=2188
      AND duplicate_source_keys=0 AND invalid_hashes=0 FROM pv));
SELECT pg_temp.ck('WRV-3  NO row proposes a target Station',
  (SELECT rows_with_target_station=0 FROM pv));

-- rollback atomicity, before the real run
BEGIN;
SELECT pg_temp.ck('WRV-4  in-transaction: 2,188 created and linked',
  (SELECT valves_created=2188 AND rows_linked=2188 FROM cng_wrv_import_commit(
     :RUN::uuid,'whmanifest',(SELECT preview_fingerprint FROM pv),2188,'rollback probe')));
ROLLBACK;
SELECT pg_temp.ck('WRV-5  rollback left ZERO valves and ZERO lineage',
  (SELECT (SELECT count(*) FROM warehouse_relief_valves)=0
      AND (SELECT count(*) FROM import_staging_rows WHERE committed_entity_kind='warehouse_relief_valve')=0));

SELECT pg_temp.refused('WRV-6  wrong preview fingerprint', format(
  'SELECT cng_wrv_import_commit(%L::uuid,''whmanifest'',%L,2188,''x'')', :RUN, repeat('a',64)));
SELECT pg_temp.refused('WRV-7  wrong manifest', format(
  'SELECT cng_wrv_import_commit(%L::uuid,''nope'',%L,2188,''x'')', :RUN, (SELECT preview_fingerprint FROM pv)));
SELECT pg_temp.refused('WRV-8  wrong row count', format(
  'SELECT cng_wrv_import_commit(%L::uuid,''whmanifest'',%L,2187,''x'')', :RUN, (SELECT preview_fingerprint FROM pv)));

-- THE AUTHORIZED RUN
CREATE TEMP TABLE res AS SELECT * FROM cng_wrv_import_commit(
  :RUN::uuid,'whmanifest',(SELECT preview_fingerprint FROM pv),2188,'Prompt 27 local');

SELECT pg_temp.ck('WRV-9  2,188 created and 2,188 linked', (SELECT valves_created=2188 AND rows_linked=2188 FROM res));
SELECT pg_temp.ck('WRV-10 canonical warehouse_relief_valves = 2,188',
  (SELECT count(*)=2188 FROM warehouse_relief_valves));
SELECT pg_temp.ck('WRV-11 no staged row lost: 2,188 linked, 0 unlinked',
  (SELECT count(*) FILTER (WHERE committed_entity_id IS NOT NULL)=2188
      AND count(*) FILTER (WHERE committed_entity_id IS NULL)=0
     FROM import_staging_rows WHERE target_table='warehouse_relief_valves'));
SELECT pg_temp.ck('WRV-12 lineage exact: key and hash match on every row, 0 orphans',
  (SELECT count(*)=0 FROM import_staging_rows r JOIN warehouse_relief_valves w ON w.id=r.committed_entity_id
    WHERE r.target_table='warehouse_relief_valves'
      AND (w.source_raw->>'source_row_key' <> r.source_row_key
        OR w.source_raw->>'source_row_hash' <> r.source_row_hash)));
SELECT pg_temp.ck('WRV-13 2,188 distinct source keys across 2,188 valves (nothing deduplicated)',
  (SELECT count(DISTINCT source_raw->>'source_row_key')=2188 FROM warehouse_relief_valves));
SELECT pg_temp.ck('WRV-14 ONE committed_at (one transaction)',
  (SELECT count(DISTINCT committed_at)=1 FROM import_staging_rows WHERE committed_entity_kind='warehouse_relief_valve'));

-- FIELD PRESERVATION, compared against the staged source
SELECT pg_temp.ck('WRV-15 every supported field equals its source value (0 mismatches)',
  (SELECT count(*)=0 FROM import_staging_rows r JOIN warehouse_relief_valves w ON w.id=r.committed_entity_id
    WHERE r.target_table='warehouse_relief_valves' AND (
         w.warehouse_code   IS DISTINCT FROM r.normalized->>'warehouse_code'
      OR w.serial_number    IS DISTINCT FROM r.normalized->>'serial_number'
      OR w.serial_number_raw IS DISTINCT FROM r.normalized->>'serial_number_raw'
      OR w.part_number      IS DISTINCT FROM r.normalized->>'part_number'
      OR w.manufacturer     IS DISTINCT FROM r.normalized->>'manufacturer'
      OR w.size_type        IS DISTINCT FROM r.normalized->>'size_type'
      OR w.inlet_size       IS DISTINCT FROM r.normalized->>'port_in'
      OR w.outlet_size      IS DISTINCT FROM r.normalized->>'port_out'
      OR w.set_pressure_raw IS DISTINCT FROM r.normalized->'set_pressure'->>'raw'
      OR w.calibration_location IS DISTINCT FROM r.normalized->>'calibration_location'
      OR w.availability_raw IS DISTINCT FROM r.normalized->>'availability_status_raw'
      OR w.notes            IS DISTINCT FROM r.normalized->>'notes')));
SELECT pg_temp.ck('WRV-16 serial coverage preserved exactly: 2,187 with, 1 without',
  (SELECT count(*) FILTER (WHERE serial_number IS NOT NULL)=2187
      AND count(*) FILTER (WHERE serial_number IS NULL)=1 FROM warehouse_relief_valves));
SELECT pg_temp.ck('WRV-17 NULL stays NULL: notes present on exactly 140, part_number on 2,167',
  (SELECT count(*) FILTER (WHERE notes IS NOT NULL)=140
      AND count(*) FILTER (WHERE part_number IS NOT NULL)=2167 FROM warehouse_relief_valves));
SELECT pg_temp.ck('WRV-18 a date exists ONLY at exact_date precision (all three date fields)',
  (SELECT count(*)=0 FROM warehouse_relief_valves WHERE
      (next_calibration_precision='exact_date') <> (next_calibration_date IS NOT NULL)
   OR (last_calibration_precision='exact_date') <> (last_calibration_date IS NOT NULL)
   OR (warehouse_issue_precision='exact_date')  <> (warehouse_issue_date  IS NOT NULL)));
SELECT pg_temp.ck('WRV-19 raw date text retained on the non-exact rows',
  (SELECT count(*)>0 FROM warehouse_relief_valves
    WHERE next_calibration_precision<>'exact_date' AND next_calibration_raw IS NOT NULL));
SELECT pg_temp.ck('WRV-20 availability mapped 1:1 from the source phrasing, none invented',
  (SELECT count(*)=0 FROM import_staging_rows r JOIN warehouse_relief_valves w ON w.id=r.committed_entity_id
    WHERE r.target_table='warehouse_relief_valves'
      AND w.availability_status::text <> (CASE r.normalized->>'availability_status_raw'
        WHEN 'Available New' THEN 'available_new'
        WHEN 'Available Calibrated' THEN 'available_calibrated'
        WHEN 'Available in Store UC' THEN 'available_in_store_uc'
        WHEN 'Sent to Station - Received' THEN 'sent_to_station_received'
        WHEN 'Sent to Station - Not Received' THEN 'sent_to_station_not_received' END)));

-- NO FABRICATED HIERARCHY
SELECT pg_temp.ck('WRV-21 NO fabricated Station: target_station_id NULL on all 2,188',
  (SELECT count(*)=0 FROM warehouse_relief_valves WHERE target_station_id IS NOT NULL));
SELECT pg_temp.ck('WRV-22 NO Unit column exists on this table at all (structurally impossible)',
  (SELECT count(*)=0 FROM information_schema.columns
    WHERE table_name='warehouse_relief_valves' AND column_name IN ('unit_id','compressor_id','storage_vessel_id','dispenser_id','mapping_status')));
SELECT pg_temp.ck('WRV-23 target Region resolved only from the closed canonical set: 1,775, all real',
  (SELECT count(*) FILTER (WHERE target_region_id IS NOT NULL)=1775 FROM warehouse_relief_valves)
  AND (SELECT count(*)=0 FROM warehouse_relief_valves w WHERE w.target_region_id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM regions g WHERE g.id=w.target_region_id)));
SELECT pg_temp.ck('WRV-24 the assigned Station NAME survives in provenance though it has no column',
  (SELECT count(*)=1774 FROM warehouse_relief_valves WHERE source_raw ? 'assigned_station_raw'));

-- REPLAY
SELECT pg_temp.refused('WRV-25 replay with the approved fingerprint', format(
  'SELECT cng_wrv_import_commit(%L::uuid,''whmanifest'',%L,2188,''x'')', :RUN, (SELECT preview_fingerprint FROM pv)));
SELECT pg_temp.ck('WRV-26 preview is now empty and all rows are D_ALREADY_IMPORTED',
  (SELECT eligible_rows=0 AND already_imported=2188 FROM cng_wrv_import_preview(:RUN::uuid)));

-- NOTHING ELSE MOVED
SELECT pg_temp.ck('WRV-27 installed SRVs and the four families are untouched',
  (SELECT (SELECT count(*) FROM installed_relief_valves)=b.irv
      AND (SELECT count(*) FROM installed_relief_valves WHERE station_id IS NOT NULL)=b.irv_st
      AND (SELECT count(*) FROM storage_vessels)=b.sv AND (SELECT count(*) FROM recovery_tanks)=b.rt
      AND (SELECT count(*) FROM gas_detectors)=b.gd AND (SELECT count(*) FROM hoses)=b.ho
      AND (SELECT count(*) FROM stations)=b.st AND (SELECT count(*) FROM units)=b.un FROM base b));
SELECT pg_temp.ck('WRV-28 no alias, no mapping decision, no Station or Unit created',
  (SELECT (SELECT count(*) FROM station_aliases)=0 AND (SELECT count(*) FROM unit_aliases)=0
      AND (SELECT count(*) FROM import_mapping_decisions)=0));
SELECT pg_temp.ck('WRV-29 exactly one audit row, service_role attributed, 0 target Stations recorded',
  (SELECT count(*)=1 FROM audit_logs WHERE actor_label='service_role:warehouse_srv_import'
     AND (after_data->>'target_stations_assigned')::int=0 AND actor_id IS NULL));

-- SECURITY + UI CONTRACT
SELECT pg_temp.ck('WRV-30 service_role only: anon and authenticated hold no EXECUTE',
  (SELECT bool_and(has_function_privilege('service_role',oid,'EXECUTE')
      AND NOT has_function_privilege('anon',oid,'EXECUTE')
      AND NOT has_function_privilege('authenticated',oid,'EXECUTE'))
     FROM pg_proc WHERE proname LIKE 'cng_wrv_import%'));
SELECT pg_temp.ck('WRV-31 commit is definer with pinned search_path; read paths are STABLE invoker',
  (SELECT bool_and(CASE WHEN proname='cng_wrv_import_commit' THEN prosecdef AND provolatile='v'
                        ELSE NOT prosecdef AND provolatile='s' END
                   AND proconfig::text LIKE '%search_path=pg_catalog, public%')
     FROM pg_proc WHERE proname LIKE 'cng_wrv_import%'));
SELECT pg_temp.ck('WRV-32 no dynamic SQL anywhere',
  (SELECT bool_and(prosrc !~* '\mEXECUTE\M' AND prosrc !~* 'quote_ident')
     FROM pg_proc WHERE proname LIKE 'cng_wrv_import%'));
SELECT pg_temp.ck('WRV-33 the management view returns all 2,188 with due status computed',
  (SELECT count(*)=2188 FROM v_warehouse_srv_management)
  AND (SELECT count(*)=0 FROM v_warehouse_srv_management WHERE due_status IS NULL));
SELECT pg_temp.ck('WRV-34 is_unassigned_stock is TRUE on all 2,188 (no target Station assigned)',
  (SELECT count(*) FILTER (WHERE is_unassigned_stock)=2188 FROM v_warehouse_srv_management));
SELECT pg_temp.ck('WRV-35 the view exposes the target Region name for the 1,775 that have one',
  (SELECT count(*) FILTER (WHERE target_region_name IS NOT NULL)=1775 FROM v_warehouse_srv_management));
SELECT pg_temp.ck('WRV-36 days_left only where the next date is exact',
  (SELECT count(*)=0 FROM v_warehouse_srv_management
    WHERE days_left IS NOT NULL AND next_calibration_precision<>'exact_date'));
