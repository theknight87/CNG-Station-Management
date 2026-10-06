-- station_compressor_models.sql — regression suite for 20261006100000_station_compressor_models.sql (owner request
-- 2026-10-06): Stations filtered by compressor type.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT v.id::uuid, r.id, v.n FROM regions r,
  (VALUES ('7e100000-0000-0000-0000-000000000001','TSC ONE'), ('7e100000-0000-0000-0000-000000000002','TSC TWO'),
          ('7e100000-0000-0000-0000-000000000003','TSC NONE')) v(id, n) WHERE r.name = 'West';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT v.id::uuid, v.s::uuid, r.id, v.n FROM regions r,
  (VALUES ('7e200000-0000-0000-0000-000000000001','7e100000-0000-0000-0000-000000000001','TSC ONE 1'),
          ('7e200000-0000-0000-0000-000000000002','7e100000-0000-0000-0000-000000000001','TSC ONE 2'),
          ('7e200000-0000-0000-0000-000000000003','7e100000-0000-0000-0000-000000000002','TSC TWO'),
          ('7e200000-0000-0000-0000-000000000004','7e100000-0000-0000-0000-000000000003','TSC NONE')) v(id, s, n) WHERE r.name = 'West';
INSERT INTO compressors (region_id, station_id, unit_id, model, mapping_status) SELECT r.id, v.s::uuid, v.u::uuid, v.m, 'resolved' FROM regions r,
  (VALUES ('7e100000-0000-0000-0000-000000000001','7e200000-0000-0000-0000-000000000001','Kwangshin'),
          ('7e100000-0000-0000-0000-000000000001','7e200000-0000-0000-0000-000000000002',' KWANGSHIN '),
          ('7e100000-0000-0000-0000-000000000002','7e200000-0000-0000-0000-000000000003','GRAF MOTOR'),
          ('7e100000-0000-0000-0000-000000000003','7e200000-0000-0000-0000-000000000004','')) v(s, u, m) WHERE r.name = 'West';
INSERT INTO compressors (region_id, station_id, unit_id, model, mapping_status, archived_at) SELECT r.id,
  '7e100000-0000-0000-0000-000000000002', '7e200000-0000-0000-0000-000000000003', 'SAFE', 'resolved', now() FROM regions r WHERE r.name = 'West';

SELECT pg_temp.ck('SCM-1 one value per model: spellings differing only in case/spaces fold together; different words stay apart',
  (SELECT compressor_models FROM v_station_summary WHERE station_id = '7e100000-0000-0000-0000-000000000001') = ARRAY['KWANGSHIN']
  AND (SELECT compressor_models FROM v_station_summary WHERE station_id = '7e100000-0000-0000-0000-000000000002') = ARRAY['GRAF MOTOR']);
SELECT pg_temp.ck('SCM-2 an archived compressor adds nothing; a blank model adds nothing and the array is empty, never NULL',
  (SELECT compressor_models = '{}'::text[] FROM v_station_summary WHERE station_id = '7e100000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('SCM-3 the filter the page sends: "only these" overlaps, "all except" keeps a Station with nothing recorded',
  (SELECT array_agg(station_name ORDER BY station_name) FROM v_station_summary
    WHERE station_name LIKE 'TSC %' AND compressor_models && '{"GRAF MOTOR","KWANGSHIN"}') = ARRAY['TSC ONE','TSC TWO']
  AND (SELECT array_agg(station_name ORDER BY station_name) FROM v_station_summary
    WHERE station_name LIKE 'TSC %' AND NOT (compressor_models && '{"KWANGSHIN"}')) = ARRAY['TSC NONE','TSC TWO']);
SELECT pg_temp.ck('SCM-4 the view still runs as the caller (security_invoker restated) and anon reads nothing',
  (SELECT reloptions::text LIKE '%security_invoker=true%' FROM pg_class WHERE relname = 'v_station_summary')
  AND NOT has_table_privilege('anon', 'v_station_summary', 'SELECT'));

ROLLBACK;
