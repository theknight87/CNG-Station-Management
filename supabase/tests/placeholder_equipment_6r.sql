-- placeholder_equipment_6r.sql — regression suite for 20260925040000_placeholder_equipment_6r.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO app_users (id, auth_user_id, email, role, is_active, full_name)
VALUES ('6e900000-0000-0000-0000-0000000000aa', gen_random_uuid(), 'tr-owner@example.test', 'admin', true, 'TR owner');
INSERT INTO stations (id, region_id, station_name) SELECT '6e900000-0000-0000-0000-000000000001', id, 'TR ST' FROM regions WHERE name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT '6e900000-0000-0000-0000-000000000002', '6e900000-0000-0000-0000-000000000001', id, 'TR ST' FROM regions WHERE name = 'West';
INSERT INTO installed_relief_valves (id, station_id, unit_id, region_id, mapping_status, expected_parent_kind, serial_number)
SELECT v.id::uuid, '6e900000-0000-0000-0000-000000000001', '6e900000-0000-0000-0000-000000000002', r.id, 'needs_equipment_mapping', v.k::srv_parent_kind, v.id
  FROM (VALUES ('6e900000-0000-0000-0000-000000000003', 'compressor'), ('6e900000-0000-0000-0000-000000000004', 'storage_vessel')) v(id, k),
       regions r WHERE r.name = 'West';

SELECT pg_temp.ck('R-1 a Unit with neither gets one of each proposed',
  (SELECT count(*) = 2 FROM cng_6r_proposal() WHERE unit_id = '6e900000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('R-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6r_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6r_commit('wrong', 'x'); RAISE NOTICE 'FAILED: R-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  R-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6r_preview() \gset
SELECT compressors_created FROM cng_6r_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('R-4 one compressor and one placeholder vessel (flagged for review) exist under the Unit',
  (SELECT count(*) = 1 FROM compressors WHERE unit_id = '6e900000-0000-0000-0000-000000000002' AND model IS NULL AND serial_number IS NULL)
  AND (SELECT count(*) = 1 FROM storage_vessels WHERE unit_id = '6e900000-0000-0000-0000-000000000002' AND needs_review AND serial_number IS NULL));
SELECT preview_fingerprint AS fm FROM cng_6m_preview() \gset
SELECT linked FROM cng_6m_commit(:'fm', 'test') \gset
SELECT pg_temp.ck('R-5 after 6m both SRVs are resolved on the new equipment',
  (SELECT count(*) = 2 FROM installed_relief_valves WHERE unit_id = '6e900000-0000-0000-0000-000000000002' AND mapping_status = 'resolved'));
SELECT pg_temp.ck('R-6 replay: nothing left to create for the Unit',
  NOT EXISTS (SELECT 1 FROM cng_6r_proposal() WHERE unit_id = '6e900000-0000-0000-0000-000000000002'));
ROLLBACK;
