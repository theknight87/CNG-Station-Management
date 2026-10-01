-- station_level_storage_6y.sql — regression suite for ruling 6y (20261001090000..090400): storage belongs to the Station.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;
CREATE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END; RETURN s; END $$;

UPDATE app_users SET created_at = now() WHERE role = 'admin';
INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name, created_at) VALUES
  ('6a000000-0000-0000-0000-00000000000a','sl_admin','admin',true,'TESTDATA SL Admin','2000-01-01');
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;

-- Station A (two Units, one vessel per Unit — the old shape), Station B (one Unit, one vessel), Station C (other).
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('6a100000-0000-0000-0000-000000000001','TSL A'),
  ('6a100000-0000-0000-0000-000000000002','TSL B'), ('6a100000-0000-0000-0000-000000000003','TSL C')) v(id, nm), regions r WHERE r.name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm FROM (VALUES
  ('6a200000-0000-0000-0000-000000000001','6a100000-0000-0000-0000-000000000001','TSL A 1'),
  ('6a200000-0000-0000-0000-000000000002','6a100000-0000-0000-0000-000000000001','TSL A 2'),
  ('6a200000-0000-0000-0000-000000000003','6a100000-0000-0000-0000-000000000002','TSL B 1'),
  ('6a200000-0000-0000-0000-000000000004','6a100000-0000-0000-0000-000000000003','TSL C 1')) v(id, st, nm), regions r WHERE r.name = 'West';
INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status, serial_number)
SELECT v.id::uuid, v.st::uuid, r.id, v.u::uuid, v.ms::asset_mapping_status, v.id FROM (VALUES
  ('6a300000-0000-0000-0000-000000000001','6a100000-0000-0000-0000-000000000001','6a200000-0000-0000-0000-000000000001','resolved'),
  ('6a300000-0000-0000-0000-000000000002','6a100000-0000-0000-0000-000000000001','6a200000-0000-0000-0000-000000000002','resolved'),
  ('6a300000-0000-0000-0000-000000000003','6a100000-0000-0000-0000-000000000002',NULL,'needs_unit_mapping'),
  ('6a300000-0000-0000-0000-000000000004','6a100000-0000-0000-0000-000000000003','6a200000-0000-0000-0000-000000000004','resolved')) v(id, st, u, ms), regions r WHERE r.name = 'West';
INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status)
SELECT '6a400000-0000-0000-0000-000000000001', '6a100000-0000-0000-0000-000000000001', r.id, '6a200000-0000-0000-0000-000000000001', 'resolved'
  FROM regions r WHERE r.name = 'West';
-- Before the move: one valve on vessel 1 (Unit 1, resolved), one Storage valve awaiting its vessel in Unit 2, one
-- Storage valve at Station B awaiting its Unit, and a compressor valve that must not move.
INSERT INTO installed_relief_valves (id, station_id, region_id, unit_id, compressor_id, storage_vessel_id, mapping_status,
                                     resolved_by, resolved_at, expected_parent_kind, serial_number, next_calibration_date, next_calibration_precision)
SELECT v.id::uuid, v.st::uuid, r.id, v.u::uuid, v.c::uuid, v.sv::uuid, v.ms::srv_mapping_status,
       CASE WHEN v.ms = 'resolved' THEN '6a000000-0000-0000-0000-00000000000a'::uuid END, CASE WHEN v.ms = 'resolved' THEN now() END,
       v.k::srv_parent_kind, v.id, date '2020-01-01', 'exact_date' FROM (VALUES
  ('6a500000-0000-0000-0000-000000000001','6a100000-0000-0000-0000-000000000001','6a200000-0000-0000-0000-000000000001',NULL,'6a300000-0000-0000-0000-000000000001','resolved','storage_vessel'),
  ('6a500000-0000-0000-0000-000000000002','6a100000-0000-0000-0000-000000000001','6a200000-0000-0000-0000-000000000002',NULL,NULL,'needs_equipment_mapping','storage_vessel'),
  ('6a500000-0000-0000-0000-000000000003','6a100000-0000-0000-0000-000000000002',NULL,NULL,NULL,'needs_unit_mapping','storage_vessel'),
  ('6a500000-0000-0000-0000-000000000004','6a100000-0000-0000-0000-000000000001','6a200000-0000-0000-0000-000000000001','6a400000-0000-0000-0000-000000000001',NULL,'resolved','compressor')
  ) v(id, st, u, c, sv, ms, k), regions r WHERE r.name = 'West';

SELECT pg_temp.ck('6Y-1 the move is service_role only',
  NOT has_function_privilege('authenticated', 'cng_6y_move_storage()', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'cng_6y_move_storage()', 'EXECUTE'));

CREATE TEMP TABLE mv AS SELECT * FROM cng_6y_move_storage();
SELECT pg_temp.ck('6Y-2 the move: 3 storage valves and 4 vessels to Station level, 1 linked to its Station''s only vessel',
  (SELECT srvs = 3 AND vessels = 4 AND linked = 1 FROM mv));
SELECT pg_temp.ck('6Y-3 valves: kept vessel kept; single-vessel Station linked; two-vessel Station left on the storage bank; all resolved, no Unit',
  (SELECT unit_id IS NULL AND storage_vessel_id = '6a300000-0000-0000-0000-000000000001' AND mapping_status = 'resolved'
     FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000001')
  AND (SELECT unit_id IS NULL AND storage_vessel_id IS NULL AND mapping_status = 'resolved' AND resolved_by = '6a000000-0000-0000-0000-00000000000a'
     FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000002')
  AND (SELECT unit_id IS NULL AND storage_vessel_id = '6a300000-0000-0000-0000-000000000003' AND mapping_status = 'resolved'
     FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('6Y-4 a compressor valve and its Unit are untouched; every vessel is Station-level and resolved',
  (SELECT unit_id = '6a200000-0000-0000-0000-000000000001' AND compressor_id IS NOT NULL FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000004')
  AND (SELECT bool_and(unit_id IS NULL AND mapping_status = 'resolved') FROM storage_vessels WHERE id::text LIKE '6a3%'));
SELECT pg_temp.ck('6Y-5 a second run moves nothing (idempotent)',
  (SELECT srvs = 0 AND vessels = 0 AND linked = 0 FROM cng_6y_move_storage()));

-- Shape rules.
INSERT INTO r VALUES ('comp_noun', pg_temp.try($q$UPDATE installed_relief_valves SET unit_id = NULL WHERE id = '6a500000-0000-0000-0000-000000000004'$q$));
INSERT INTO r VALUES ('noparent_comp', pg_temp.try($q$UPDATE installed_relief_valves SET expected_parent_kind = 'compressor' WHERE id = '6a500000-0000-0000-0000-000000000002'$q$));
INSERT INTO r VALUES ('other_station', pg_temp.try($q$UPDATE installed_relief_valves SET storage_vessel_id = '6a300000-0000-0000-0000-000000000004' WHERE id = '6a500000-0000-0000-0000-000000000002'$q$));
INSERT INTO r VALUES ('unit_on_station_vessel', pg_temp.try($q$UPDATE installed_relief_valves SET unit_id = '6a200000-0000-0000-0000-000000000001' WHERE id = '6a500000-0000-0000-0000-000000000001'$q$));
SELECT pg_temp.ck('6Y-6 refused: a compressor valve without a Unit, a no-parent valve not stated as storage, a vessel of another Station, a Unit on a Station-level vessel',
  (SELECT v FROM r WHERE k='comp_noun') = '23514' AND (SELECT v FROM r WHERE k='noparent_comp') = '23514'
  AND (SELECT v FROM r WHERE k='other_station') = '23503' AND (SELECT v FROM r WHERE k='unit_on_station_vessel') = '23503');

-- Views.
SELECT pg_temp.ck('6Y-7 the Unit SRV tab shows Station-level storage under BOTH Units of Station A, one record each, record Unit NULL',
  (SELECT count(*) FROM v_unit_srvs WHERE view_unit_id = '6a200000-0000-0000-0000-000000000001' AND station_level AND unit_id IS NULL) = 2
  AND (SELECT count(*) FROM v_unit_srvs WHERE view_unit_id = '6a200000-0000-0000-0000-000000000002' AND station_level) = 2
  AND (SELECT count(*) FROM v_unit_srvs WHERE view_unit_id = '6a200000-0000-0000-0000-000000000001' AND NOT station_level) = 1
  AND NOT EXISTS (SELECT 1 FROM v_unit_srvs WHERE view_unit_id = '6a200000-0000-0000-0000-000000000004')
  AND (SELECT count(*) FROM installed_relief_valves WHERE station_id = '6a100000-0000-0000-0000-000000000001') = 3);
SELECT pg_temp.ck('6Y-8 the Unit Storage tab shows the Station''s vessels under every Unit and never another Station''s',
  (SELECT count(*) FROM v_unit_storage_vessels WHERE view_unit_id = '6a200000-0000-0000-0000-000000000002') = 2
  AND (SELECT count(*) FROM v_unit_storage_vessels WHERE view_unit_id = '6a200000-0000-0000-0000-000000000003') = 1
  AND (SELECT bool_and(station_id = '6a100000-0000-0000-0000-000000000001') FROM v_unit_storage_vessels WHERE view_unit_id = '6a200000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('6Y-9 Unit summaries count Station storage under each Unit; the Station counts each record once',
  (SELECT storage_vessels = 2 AND installed_srvs = 3 AND overdue = 3 FROM v_unit_summary WHERE unit_id = '6a200000-0000-0000-0000-000000000001')
  AND (SELECT storage_vessels = 2 AND installed_srvs = 2 AND overdue = 2 FROM v_unit_summary WHERE unit_id = '6a200000-0000-0000-0000-000000000002')
  AND (SELECT assets = 6 AND overdue = 3 AND unresolved_mapping = 0 FROM v_station_summary WHERE station_id = '6a100000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('6Y-10 the new and replaced views run with the caller''s rights; anon reads none of them',
  (SELECT bool_and(reloptions @> ARRAY['security_invoker=true']) FROM pg_class WHERE relname IN ('v_unit_srvs','v_unit_storage_vessels','v_unit_summary'))
  AND NOT has_table_privilege('anon', 'v_unit_storage_vessels', 'SELECT')
  AND has_table_privilege('authenticated', 'v_unit_storage_vessels', 'SELECT'));

-- Admin mapping: storage resolves at Station level.
INSERT INTO installed_relief_valves (id, station_id, region_id, unit_id, mapping_status, serial_number)
SELECT v.id::uuid, '6a100000-0000-0000-0000-000000000001', r.id, '6a200000-0000-0000-0000-000000000002', 'needs_equipment_mapping', v.id
  FROM (VALUES ('6a500000-0000-0000-0000-000000000011'), ('6a500000-0000-0000-0000-000000000012'), ('6a500000-0000-0000-0000-000000000013')) v(id), regions r WHERE r.name = 'West';
INSERT INTO r VALUES ('map_bank', pg_temp.try_as('sl_admin', $q$SELECT cng_admin_map_srv('6a500000-0000-0000-0000-000000000011', '6a100000-0000-0000-0000-000000000001', '6a200000-0000-0000-0000-000000000002', 'storage_vessel', NULL)$q$));
INSERT INTO r VALUES ('map_vessel', pg_temp.try_as('sl_admin', $q$SELECT cng_admin_map_srv('6a500000-0000-0000-0000-000000000012', '6a100000-0000-0000-0000-000000000001', NULL, 'storage_vessel', '6a300000-0000-0000-0000-000000000002')$q$));
INSERT INTO r VALUES ('map_comp_nounit', pg_temp.try_as('sl_admin', $q$SELECT cng_admin_map_srv('6a500000-0000-0000-0000-000000000013', '6a100000-0000-0000-0000-000000000001', NULL, 'compressor', '6a400000-0000-0000-0000-000000000001')$q$));
SELECT pg_temp.ck('6Y-11 admin mapping to storage resolves at Station level (bank or vessel, never a Unit); a compressor still needs its Unit; audited',
  (SELECT v FROM r WHERE k='map_bank') = 'OK' AND (SELECT v FROM r WHERE k='map_vessel') = 'OK' AND (SELECT v FROM r WHERE k='map_comp_nounit') = '23514'
  AND (SELECT unit_id IS NULL AND storage_vessel_id IS NULL AND mapping_status = 'resolved' AND expected_parent_kind = 'storage_vessel'
         AND resolved_by = '6a000000-0000-0000-0000-00000000000a' FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000011')
  AND (SELECT unit_id IS NULL AND storage_vessel_id = '6a300000-0000-0000-0000-000000000002' AND mapping_status = 'resolved'
         FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000012')
  AND (SELECT count(*) FROM asset_mapping_audit WHERE asset_id IN ('6a500000-0000-0000-0000-000000000011','6a500000-0000-0000-0000-000000000012')) = 2);

-- Issuing a warehouse valve in place of a Station-level storage valve keeps the Station-level place.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, pressure_min, pressure_max, pressure_unit, source_raw)
VALUES ('6a600000-0000-0000-0000-000000000001', 'available_new', 'TSL-NEW', NULL, NULL, NULL, '{}');
INSERT INTO r VALUES ('issue', pg_temp.try_as('sl_admin', $q$SELECT cng_srv_issue('6a600000-0000-0000-0000-000000000001',
  (SELECT updated_at FROM warehouse_relief_valves WHERE id = '6a600000-0000-0000-0000-000000000001'),
  '6a200000-0000-0000-0000-000000000002', '6a500000-0000-0000-0000-000000000001')$q$));
SELECT pg_temp.ck('6Y-12 a valve issued in place of Station-level storage takes the same Station-level place on the same vessel',
  (SELECT v FROM r WHERE k='issue') = 'OK'
  AND (SELECT unit_id IS NULL AND storage_vessel_id = '6a300000-0000-0000-0000-000000000001' AND mapping_status = 'resolved'
         FROM installed_relief_valves WHERE serial_number = 'TSL-NEW' AND archived_at IS NULL)
  AND (SELECT archived_at IS NOT NULL FROM installed_relief_valves WHERE id = '6a500000-0000-0000-0000-000000000001'));
ROLLBACK;
