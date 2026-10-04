-- warehouse_destination.sql — regression suite for 20261004100000_warehouse_destination.sql (owner request 2026-10-04):
-- a store valve's destination is a Station or a Unit, chosen when adding (one for the batch, or per serial) and
-- editable later; the Region follows the Station, a Unit fixes its Station, and the sheet's own text is never altered.
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
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE || ' ' || SQLERRM; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;
CREATE TEMP TABLE r (k text PRIMARY KEY, v text);
GRANT ALL ON r TO authenticated;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('9c000000-0000-0000-0000-00000000000a', 'wd_admin', 'admin', true, 'TESTDATA WD Admin'),
  ('9c000000-0000-0000-0000-00000000000b', 'wd_eng', 'engineer', true, 'TESTDATA WD Engineer');
INSERT INTO stations (id, region_id, station_name) VALUES
  ('9c100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TWD NASR'),
  ('9c100000-0000-0000-0000-000000000002', (SELECT id FROM regions WHERE name = 'West'), 'TWD WEST');
INSERT INTO units (id, station_id, region_id, unit_name) VALUES
  ('9c200000-0000-0000-0000-000000000001', '9c100000-0000-0000-0000-000000000001', (SELECT id FROM regions WHERE name = 'East'), 'TWD NASR 1'),
  ('9c200000-0000-0000-0000-000000000002', '9c100000-0000-0000-0000-000000000002', (SELECT id FROM regions WHERE name = 'West'), 'TWD WEST 1');

-- Add: a batch Station, one serial with its own Unit (another Region), one with nothing of its own.
INSERT INTO r VALUES ('add', pg_temp.try_as('wd_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_calibrated", "manufacturer": "TWD", "pressure_min": 18, "pressure_unit": "BAR",
  "station_id": "9c100000-0000-0000-0000-000000000001",
  "items": [{"serial": "TWD-1"}, {"serial": "TWD-2", "unit_id": "9c200000-0000-0000-0000-000000000002"}]}'::jsonb)$q$));
SELECT pg_temp.ck('WD-1 per-serial destinations: a row without its own takes the batch Station; a Unit brings its Station and Region',
  (SELECT v FROM r WHERE k = 'add') = 'OK'
  AND (SELECT target_station_id = '9c100000-0000-0000-0000-000000000001' AND target_unit_id IS NULL
            AND target_region_id = (SELECT id FROM regions WHERE name = 'East') AND destination_set_at IS NOT NULL
         FROM warehouse_relief_valves WHERE serial_number = 'TWD-1')
  AND (SELECT target_station_id = '9c100000-0000-0000-0000-000000000002' AND target_unit_id = '9c200000-0000-0000-0000-000000000002'
            AND target_region_id = (SELECT id FROM regions WHERE name = 'West')
         FROM warehouse_relief_valves WHERE serial_number = 'TWD-2'));

INSERT INTO r VALUES ('plain', pg_temp.try_as('wd_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_new", "manufacturer": "TWD", "serials": ["TWD-3"]}'::jsonb)$q$));
SELECT pg_temp.ck('WD-2 the old call (serials, no destination) still adds a valve with no destination',
  (SELECT v FROM r WHERE k = 'plain') = 'OK'
  AND (SELECT target_station_id IS NULL AND target_unit_id IS NULL AND destination_set_at IS NULL
         FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'));

INSERT INTO r VALUES ('bad', pg_temp.try_as('wd_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_new", "station_id": "9c100000-0000-0000-0000-000000000001",
  "items": [{"serial": "TWD-4", "station_id": "9c100000-0000-0000-0000-000000000001", "unit_id": "9c200000-0000-0000-0000-000000000002"}]}'::jsonb)$q$));
INSERT INTO r VALUES ('dup', pg_temp.try_as('wd_admin', $q$SELECT cng_admin_add_warehouse_srvs('{
  "availability": "available_new", "items": [{"serial": "TWD-5"}, {"serial": "TWD-5"}]}'::jsonb)$q$));
SELECT pg_temp.ck('WD-3 a Unit of another Station, or one serial listed twice, is refused and adds nothing',
  (SELECT v FROM r WHERE k = 'bad') LIKE '22023%another Station%' AND (SELECT v FROM r WHERE k = 'dup') LIKE '22023%twice%'
  AND NOT EXISTS (SELECT 1 FROM warehouse_relief_valves WHERE serial_number IN ('TWD-4', 'TWD-5')));

-- Edit: change to a Unit, then clear.
INSERT INTO r VALUES ('set', pg_temp.try_as('wd_admin', format('SELECT cng_admin_set_warehouse_destination(%L, %L, NULL, %L)',
  (SELECT id FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'), (SELECT updated_at FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'),
  '9c200000-0000-0000-0000-000000000001')));
SELECT pg_temp.ck('WD-4 setting a Unit sets its Station and Region and is audited with the before value',
  (SELECT v FROM r WHERE k = 'set') = 'OK'
  AND (SELECT target_unit_id = '9c200000-0000-0000-0000-000000000001' AND target_station_id = '9c100000-0000-0000-0000-000000000001'
         FROM warehouse_relief_valves WHERE serial_number = 'TWD-3')
  AND EXISTS (SELECT 1 FROM audit_logs WHERE actor_label = 'admin_set_warehouse_destination'
                AND entity_id = (SELECT id FROM warehouse_relief_valves WHERE serial_number = 'TWD-3')
                AND before_data->>'target_station_id' IS NULL));

INSERT INTO r VALUES ('stale', pg_temp.try_as('wd_admin', format('SELECT cng_admin_set_warehouse_destination(%L, %L, NULL, NULL)',
  (SELECT id FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'), '2000-01-01')));
INSERT INTO r VALUES ('eng', pg_temp.try_as('wd_eng', format('SELECT cng_admin_set_warehouse_destination(%L, %L, NULL, NULL)',
  (SELECT id FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'), (SELECT updated_at FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'))));
SELECT pg_temp.ck('WD-5 a stale edit is refused with PT409 and a non-admin is refused; nothing changes',
  (SELECT v FROM r WHERE k = 'stale') LIKE 'PT409%' AND (SELECT v FROM r WHERE k = 'eng') LIKE '42501%'
  AND (SELECT target_unit_id IS NOT NULL FROM warehouse_relief_valves WHERE serial_number = 'TWD-3'));

-- A sheet row: its own Station text shows until a destination is set by hand; clearing then really clears it.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, source_raw)
VALUES ('9c400000-0000-0000-0000-000000000001', 'available_calibrated', 'TWD-SHEET', '{"Station": "TWD as written"}');
SELECT pg_temp.ck('WD-6 before any edit the sheet''s own Station text is shown and the valve is not unassigned',
  (SELECT target_station_raw = 'TWD as written' AND NOT is_unassigned_stock FROM v_warehouse_srv_management
     WHERE id = '9c400000-0000-0000-0000-000000000001'));
INSERT INTO r VALUES ('clear', pg_temp.try_as('wd_admin', format('SELECT cng_admin_set_warehouse_destination(%L, %L, NULL, NULL)',
  '9c400000-0000-0000-0000-000000000001', (SELECT updated_at FROM warehouse_relief_valves WHERE id = '9c400000-0000-0000-0000-000000000001'))));
SELECT pg_temp.ck('WD-7 clearing hides the sheet text and leaves the valve unassigned; source_raw is untouched',
  (SELECT v FROM r WHERE k = 'clear') = 'OK'
  AND (SELECT target_station_raw IS NULL AND is_unassigned_stock FROM v_warehouse_srv_management WHERE id = '9c400000-0000-0000-0000-000000000001')
  AND (SELECT source_raw->>'Station' = 'TWD as written' FROM warehouse_relief_valves WHERE id = '9c400000-0000-0000-0000-000000000001'));

-- The workflow moves the Station without knowing about the Unit: the Unit is cleared, never left pointing elsewhere.
UPDATE warehouse_relief_valves SET target_station_id = NULL, target_region_id = NULL WHERE serial_number = 'TWD-2';
SELECT pg_temp.ck('WD-8 when the Station changes without the Unit, the Unit is cleared',
  (SELECT target_unit_id IS NULL FROM warehouse_relief_valves WHERE serial_number = 'TWD-2'));
SELECT pg_temp.ck('WD-9 a Unit can never stand without its Station (CHECK) nor under another Station (FK)',
  EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wrv_target_unit_needs_station_ck')
  AND EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wrv_target_unit_station_fk'));
SELECT pg_temp.ck('WD-10 the view shows the Unit, still runs with the caller''s rights, and the helper is not callable from the browser',
  (SELECT target_unit_name = 'TWD NASR 1' FROM v_warehouse_srv_management v JOIN warehouse_relief_valves w ON w.id = v.id WHERE w.serial_number = 'TWD-3')
  AND (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE relname = 'v_warehouse_srv_management')
  AND NOT has_function_privilege('authenticated', 'cng_wrv_resolve_destination(uuid, uuid)', 'EXECUTE'));

-- Owner report 2026-10-04: the store list reads v_srv_warehouse_stock, which lacked the Unit columns.
SELECT pg_temp.ck('WD-11 the store list view carries the destination Unit too, and runs with the caller''s rights',
  (SELECT count(*) FROM information_schema.columns WHERE table_name = 'v_srv_warehouse_stock'
     AND column_name IN ('target_unit_id', 'target_unit_name')) = 2
  AND (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE relname = 'v_srv_warehouse_stock'));

ROLLBACK;
