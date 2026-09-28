-- summaries_archived.sql — regression suite for 20260928190000_summaries_ignore_archived.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '7d100000-0000-0000-0000-000000000001', id, 'TSA ALPHA' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name)
SELECT '7d200000-0000-0000-0000-000000000001', '7d100000-0000-0000-0000-000000000001', id, 'TSA ALPHA 1' FROM regions WHERE name = 'East';
INSERT INTO installed_relief_valves (region_id, station_id, unit_id, mapping_status, serial_number, next_calibration_date, next_calibration_precision, archived_at)
SELECT r.id, '7d100000-0000-0000-0000-000000000001', '7d200000-0000-0000-0000-000000000001', 'needs_equipment_mapping', v.sn, date '2020-01-01', 'exact_date', v.arch
  FROM regions r, (VALUES ('TSA-LIVE', NULL::timestamptz), ('TSA-OLD1', now()), ('TSA-OLD2', now())) v(sn, arch) WHERE r.name = 'East';

SELECT pg_temp.ck('SA-1 the Unit counts one overdue valve, not the two archived ones',
  (SELECT overdue = 1 AND installed_srvs = 1 FROM v_unit_summary WHERE unit_id = '7d200000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('SA-2 the Station counts one overdue and one asset',
  (SELECT overdue = 1 AND assets = 1 FROM v_station_summary WHERE station_id = '7d100000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('SA-3 no summary view counts an archived valve anywhere',
  (SELECT count(*) FROM v_data_quality_queue q JOIN installed_relief_valves v ON v.id = q.asset_id WHERE v.archived_at IS NOT NULL) = 0
  AND (SELECT total FROM v_dashboard_asset_counts WHERE asset_kind = 'installed_relief_valve')
      = (SELECT count(*) FROM installed_relief_valves WHERE archived_at IS NULL));
SELECT pg_temp.ck('SA-4 the replaced views still run with the caller''s rights',
  (SELECT bool_and(reloptions @> ARRAY['security_invoker=true']) FROM pg_class
    WHERE relname IN ('v_unit_summary','v_station_summary','v_dashboard_region_summary','v_dashboard_due_summary','v_dashboard_asset_counts','v_data_quality_queue')));
ROLLBACK;
