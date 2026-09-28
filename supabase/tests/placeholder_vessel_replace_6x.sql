-- placeholder_vessel_replace_6x.sql — regression suite for 20260928090000_placeholder_vessel_replace_6x.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name)
VALUES ('7e900000-0000-0000-0000-0000000000aa', gen_random_uuid(), 'tx-owner@example.test', 'admin', true, 'TX owner');
INSERT INTO stations (id, region_id, station_name) SELECT '7e100000-0000-0000-0000-000000000001', id, 'TX ST' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, '7e100000-0000-0000-0000-000000000001', r.id, v.nm
  FROM (VALUES ('7e200000-0000-0000-0000-000000000001', 'TX ST 1'), ('7e200000-0000-0000-0000-000000000002', 'TX ST 2')) v(id, nm), regions r WHERE r.name = 'East';
INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status, needs_review, source_file)
SELECT v.id::uuid, '7e100000-0000-0000-0000-000000000001', r.id, v.u::uuid, 'resolved', true, 'owner rule 6r'
  FROM (VALUES ('7e300000-0000-0000-0000-000000000001', '7e200000-0000-0000-0000-000000000001'),
               ('7e300000-0000-0000-0000-000000000002', '7e200000-0000-0000-0000-000000000002')) v(id, u), regions r WHERE r.name = 'East';
INSERT INTO installed_relief_valves (id, station_id, unit_id, region_id, mapping_status, expected_parent_kind, storage_vessel_id, serial_number, resolved_by, resolved_at)
SELECT v.id::uuid, '7e100000-0000-0000-0000-000000000001', v.u::uuid, r.id, 'resolved', 'storage_vessel', v.ves::uuid, v.sn, '7e900000-0000-0000-0000-0000000000aa', now()
  FROM (VALUES ('7e500000-0000-0000-0000-000000000001', '7e200000-0000-0000-0000-000000000001', '7e300000-0000-0000-0000-000000000001', 'S-1'),
               ('7e500000-0000-0000-0000-000000000002', '7e200000-0000-0000-0000-000000000001', '7e300000-0000-0000-0000-000000000001', 'S-2'),
               ('7e500000-0000-0000-0000-000000000003', '7e200000-0000-0000-0000-000000000002', '7e300000-0000-0000-0000-000000000002', 'S-3')) v(id, u, ves, sn),
       regions r WHERE r.name = 'East';

-- Unit 1 gets two real vessels (k 0, 1); Unit 2 gets one
\set rows '[["7e300000-0000-0000-0000-000000000001",0,10,"EKC","EKC","V-A","V-A","assigned","Kwangshin","2021-08-31","2021-08-31","exact_date","2026-08-31","2026-08-31","exact_date",null,{"x":1}],["7e300000-0000-0000-0000-000000000001",1,11,"EKC","EKC","V-B","V-B","assigned","Kwangshin","2021-08-31","2021-08-31","exact_date","2026-08-31","2026-08-31","exact_date",null,{"x":2}],["7e300000-0000-0000-0000-000000000002",0,12,"CMV","CMV","V-C","V-C","assigned",null,null,null,"unknown",null,null,"unknown",null,{"x":3}]]'

SELECT pg_temp.ck('X-1 preview: 3 rows, 2 placeholders, 1 new vessel, 2 SRVs to re-pair',
  (SELECT (rows_matched, placeholders, new_vessels, srvs_to_repair) = (3, 2, 1, 2) FROM cng_6x_preview(:'rows'::jsonb)));
SELECT pg_temp.ck('X-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6x_commit(jsonb, text, text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6x_commit('[]', 'f', 'wrong', 'x'); RAISE NOTICE 'FAILED: X-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  X-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6x_preview(:'rows'::jsonb) \gset
SELECT placeholders_replaced FROM cng_6x_commit(:'rows'::jsonb, 'wb.xlsx', :'fp', 'test') \gset
SELECT pg_temp.ck('X-4 placeholder became the real vessel, no longer flagged, with provenance',
  (SELECT serial_number = 'V-A' AND NOT needs_review AND source_file = 'wb.xlsx' AND source_row = 10 AND next_inspection_date = '2026-08-31'
     FROM storage_vessels WHERE id = '7e300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('X-5 the extra vessel is added to the same Unit; unknown dates stay NULL',
  (SELECT count(*) = 2 FROM storage_vessels WHERE unit_id = '7e200000-0000-0000-0000-000000000001' AND archived_at IS NULL)
  AND (SELECT last_inspection_date IS NULL FROM storage_vessels WHERE id = '7e300000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('X-6 Unit 1 SRVs return for 6s pairing; Unit 2 SRV stays on its (now real) vessel',
  (SELECT count(*) = 2 FROM installed_relief_valves WHERE unit_id = '7e200000-0000-0000-0000-000000000001'
     AND mapping_status = 'needs_equipment_mapping' AND storage_vessel_id IS NULL)
  AND (SELECT storage_vessel_id = '7e300000-0000-0000-0000-000000000002' FROM installed_relief_valves WHERE id = '7e500000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('X-7 replay: nothing left (the vessels are no longer placeholders)',
  (SELECT rows_matched = 0 FROM cng_6x_preview(:'rows'::jsonb)));
ROLLBACK;
