-- one_unit_asset_link_6l.sql — regression suite for 20260924200000_one_unit_asset_link_6l.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- ONE: one Unit. TWO: two Units.
INSERT INTO stations (id, region_id, station_name)
SELECT v.id::uuid, r.id, v.nm FROM (VALUES ('6e100000-0000-0000-0000-000000000001', 'TL ONE'), ('6e100000-0000-0000-0000-000000000002', 'TL TWO')) v(id, nm), regions r WHERE r.name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT v.id::uuid, v.st::uuid, r.id, v.nm
  FROM (VALUES ('6e200000-0000-0000-0000-000000000001', '6e100000-0000-0000-0000-000000000001', 'TL ONE'),
               ('6e200000-0000-0000-0000-000000000002', '6e100000-0000-0000-0000-000000000002', 'TL TWO 1'),
               ('6e200000-0000-0000-0000-000000000003', '6e100000-0000-0000-0000-000000000002', 'TL TWO 2')) v(id, st, nm), regions r WHERE r.name = 'West';
INSERT INTO storage_vessels (id, station_id, region_id, mapping_status, serial_number)
SELECT v.id::uuid, v.st::uuid, r.id, 'needs_unit_mapping', v.sn
  FROM (VALUES ('6e300000-0000-0000-0000-000000000001', '6e100000-0000-0000-0000-000000000001', 'TL-SV1'),
               ('6e300000-0000-0000-0000-000000000002', '6e100000-0000-0000-0000-000000000002', 'TL-SV2')) v(id, st, sn), regions r WHERE r.name = 'West';
INSERT INTO installed_relief_valves (id, station_id, region_id, mapping_status, serial_number)
SELECT '6e400000-0000-0000-0000-000000000001', '6e100000-0000-0000-0000-000000000001', id, 'needs_unit_mapping', 'TL-V1' FROM regions WHERE name = 'West';

SELECT pg_temp.ck('L-1 only records at a one-Unit Station are proposed, with that Unit',
  (SELECT unit_id FROM cng_6l_proposal() WHERE entity_id = '6e300000-0000-0000-0000-000000000001') = '6e200000-0000-0000-0000-000000000001'
  AND NOT EXISTS (SELECT 1 FROM cng_6l_proposal() WHERE entity_id = '6e300000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('L-2 service_role only', NOT has_function_privilege('authenticated', 'cng_6l_commit(text, text)', 'EXECUTE'));
DO $$ BEGIN PERFORM cng_6l_commit('wrong', 'x'); RAISE NOTICE 'FAILED: L-3';
EXCEPTION WHEN SQLSTATE '22023' THEN RAISE NOTICE 'PASS  L-3 a wrong fingerprint is refused'; END $$;
SELECT preview_fingerprint AS fp FROM cng_6l_preview() \gset
SELECT linked FROM cng_6l_commit(:'fp', 'test') \gset
SELECT pg_temp.ck('L-4 the vessel is resolved under the Unit; the two-Unit Station''s vessel is untouched',
  (SELECT (unit_id, mapping_status::text) = ('6e200000-0000-0000-0000-000000000001'::uuid, 'resolved') FROM storage_vessels WHERE id = '6e300000-0000-0000-0000-000000000001')
  AND (SELECT unit_id IS NULL FROM storage_vessels WHERE id = '6e300000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('L-5 the SRV gets the Unit, needs equipment mapping, no parent',
  (SELECT (unit_id, mapping_status::text, num_nonnulls(compressor_id, storage_vessel_id, dispenser_id))
          = ('6e200000-0000-0000-0000-000000000001'::uuid, 'needs_equipment_mapping', 0) FROM installed_relief_valves WHERE id = '6e400000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('L-6 replay: nothing left at the test Stations',
  NOT EXISTS (SELECT 1 FROM cng_6l_proposal() WHERE entity_id::text LIKE '6e%'));
ROLLBACK;
