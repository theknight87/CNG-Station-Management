-- single_equipment_srv_link_6m.sql — regression suite for 20260924220000_single_equipment_srv_link_6m.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

UPDATE app_users SET created_at = now() WHERE role = 'admin';
INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name)
VALUES ('6f000000-0000-0000-0000-000000000001', gen_random_uuid(), 'tm-owner@example.test', 'admin', true, 'TM owner');
UPDATE app_users SET created_at = '2000-01-01' WHERE id = '6f000000-0000-0000-0000-000000000001';

-- Unit A: one compressor, one vessel. Unit B: one compressor, two vessels.
INSERT INTO stations (id, region_id, station_name) SELECT '6f100000-0000-0000-0000-000000000001', id, 'TM ST' FROM regions WHERE name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, '6f100000-0000-0000-0000-000000000001', r.id, v.nm
  FROM (VALUES ('6f200000-0000-0000-0000-000000000001', 'TM A'), ('6f200000-0000-0000-0000-000000000002', 'TM B')) v(id, nm), regions r WHERE r.name = 'West';
INSERT INTO compressors (id, station_id, region_id, unit_id, mapping_status)
SELECT v.id::uuid, '6f100000-0000-0000-0000-000000000001', r.id, v.u::uuid, 'resolved'
  FROM (VALUES ('6f300000-0000-0000-0000-000000000001', '6f200000-0000-0000-0000-000000000001'),
               ('6f300000-0000-0000-0000-000000000002', '6f200000-0000-0000-0000-000000000002')) v(id, u), regions r WHERE r.name = 'West';
INSERT INTO storage_vessels (id, station_id, region_id, unit_id, mapping_status)
SELECT v.id::uuid, '6f100000-0000-0000-0000-000000000001', r.id, v.u::uuid, 'resolved'
  FROM (VALUES ('6f400000-0000-0000-0000-000000000001', '6f200000-0000-0000-0000-000000000001'),
               ('6f400000-0000-0000-0000-000000000002', '6f200000-0000-0000-0000-000000000002'),
               ('6f400000-0000-0000-0000-000000000003', '6f200000-0000-0000-0000-000000000002')) v(id, u), regions r WHERE r.name = 'West';
INSERT INTO installed_relief_valves (id, station_id, region_id, unit_id, mapping_status, expected_parent_kind, serial_number)
SELECT v.id::uuid, '6f100000-0000-0000-0000-000000000001', r.id, v.u::uuid, 'needs_equipment_mapping', v.k::srv_parent_kind, v.id
  FROM (VALUES ('6f500000-0000-0000-0000-000000000001', '6f200000-0000-0000-0000-000000000001', 'compressor'),
               ('6f500000-0000-0000-0000-000000000002', '6f200000-0000-0000-0000-000000000001', 'storage_vessel'),
               ('6f500000-0000-0000-0000-000000000003', '6f200000-0000-0000-0000-000000000002', 'compressor'),
               ('6f500000-0000-0000-0000-000000000004', '6f200000-0000-0000-0000-000000000002', 'storage_vessel')) v(id, u, k), regions r WHERE r.name = 'West';

SELECT pg_temp.ck('M-1 Stage -> the only compressor, Storage -> the only vessel; two-vessel Storage is not proposed',
  (SELECT count(*) FROM cng_6m_proposal() WHERE srv_id::text LIKE '6f5%') = 3
  AND NOT EXISTS (SELECT 1 FROM cng_6m_proposal() WHERE srv_id = '6f500000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('M-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6m_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6m_commit('wrong', 'x'); RAISE NOTICE 'FAILED: M-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  M-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6m_preview() \gset
SELECT linked FROM cng_6m_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('M-4 Stage SRV resolved on the compressor, attributed to the owner',
  (SELECT compressor_id = '6f300000-0000-0000-0000-000000000001' AND storage_vessel_id IS NULL AND mapping_status = 'resolved'
          AND resolved_by = '6f000000-0000-0000-0000-000000000001' FROM installed_relief_valves WHERE id = '6f500000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('M-5 Storage SRV resolved on the only vessel',
  (SELECT storage_vessel_id = '6f400000-0000-0000-0000-000000000001' AND mapping_status = 'resolved'
     FROM installed_relief_valves WHERE id = '6f500000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('M-6 the two-vessel Storage SRV is untouched',
  (SELECT mapping_status = 'needs_equipment_mapping' AND storage_vessel_id IS NULL FROM installed_relief_valves WHERE id = '6f500000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('M-7 replay: nothing left at the test Unit',
  NOT EXISTS (SELECT 1 FROM cng_6m_proposal() WHERE srv_id::text LIKE '6f5%'));
ROLLBACK;
