-- installed_srv_warehouse_code.sql — regression suite for 20260923220000_installed_srv_warehouse_code.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name)
SELECT '7a100000-0000-0000-0000-000000000001', id, 'TWH STATION' FROM regions WHERE name = 'East';

-- Warehouse: serial S1 once (code W1), serial S2 twice (codes W2a, W2b), serial S4 once (code W4).
INSERT INTO warehouse_relief_valves (id, serial_number, warehouse_code, availability_status)
VALUES ('7a200000-0000-0000-0000-000000000001', 'TWH-S1', 'W1', 'available_new'),
       ('7a200000-0000-0000-0000-000000000002', 'TWH-S2', 'W2a', 'available_new'),
       ('7a200000-0000-0000-0000-000000000003', 'TWH-S2', 'W2b', 'available_new'),
       ('7a200000-0000-0000-0000-000000000004', 'TWH-S4', 'W4', 'available_new');

-- Installed: S1 (one match), S2 (two matches), S3 (none), S4 with a recorded code.
INSERT INTO installed_relief_valves (id, region_id, station_id, mapping_status, serial_number, warehouse_code)
SELECT ('7a300000-0000-0000-0000-00000000000' || n)::uuid, r.id, '7a100000-0000-0000-0000-000000000001', 'needs_unit_mapping', s, c
  FROM (VALUES (1,'TWH-S1',NULL),(2,'TWH-S2',NULL),(3,'TWH-S3',NULL),(4,'TWH-S4','REC-4')) v(n,s,c)
  JOIN regions r ON r.name = 'East';

CREATE TEMP TABLE v AS SELECT id, warehouse_code, warehouse_code_source, warehouse_code_by_serial, warehouse_code_recorded
  FROM v_installed_srv_management WHERE id::text LIKE '7a3%';

SELECT pg_temp.ck('WHC-1 exactly one warehouse record with the serial -> its code, labelled serial_match',
  (SELECT (warehouse_code, warehouse_code_source) = ('W1', 'serial_match') FROM v WHERE id = '7a300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('WHC-2 a serial held by two warehouse records gives NO code (repeated serial is not evidence)',
  (SELECT warehouse_code IS NULL AND warehouse_code_source IS NULL FROM v WHERE id = '7a300000-0000-0000-0000-000000000002'));
SELECT pg_temp.ck('WHC-3 no match -> NULL', (SELECT warehouse_code IS NULL FROM v WHERE id = '7a300000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('WHC-4 a recorded code wins over the serial match and is labelled recorded',
  (SELECT (warehouse_code, warehouse_code_source, warehouse_code_by_serial) = ('REC-4', 'recorded', 'W4') FROM v WHERE id = '7a300000-0000-0000-0000-000000000004'));
SELECT pg_temp.ck('WHC-5 one view row per installed valve (the lookup never duplicates rows)', (SELECT count(*) FROM v) = 4);
SELECT pg_temp.ck('WHC-6 the lookup never writes the stored column',
  (SELECT count(*) FROM installed_relief_valves WHERE id::text LIKE '7a3%' AND warehouse_code IS NOT NULL) = 1);
SELECT pg_temp.ck('WHC-7 view still runs with the caller''s rights (security_invoker restated)',
  (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class WHERE relname = 'v_installed_srv_management'));
SELECT pg_temp.ck('WHC-8 dependent views still resolve',
  (SELECT count(*) FROM pg_class WHERE relname IN ('v_installed_srv_summary','v_report_due_compliance','v_srv_mapping_queue','v_unit_srvs')) = 4);

ROLLBACK;
