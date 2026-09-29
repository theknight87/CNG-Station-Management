-- srv_stock_group_sort.sql — regression suite for 20260929130000_srv_stock_group_sort.sql
-- Owner request 2026-09-29: Warehouse SRVs ordered by set pressure, then each size together (smallest first), and
-- within one pressure and size calibrated first (oldest calibration first), then new, then under calibration.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('7f000000-0000-0000-0000-00000000000a','gs_admin','admin',true,'TESTDATA GS Admin'),
  ('7f000000-0000-0000-0000-00000000000b','gs_viewer','viewer',true,'TESTDATA GS Viewer');

-- The owner's example: 30 PSI in two sizes (3/4" and 1"), calibrated on different days, plus under-calibration and
-- new valves, a bigger pressure, and a size that is not a plain number.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, size_type, inlet_size, outlet_size,
                                     pressure_min, pressure_max, pressure_unit, last_calibration_date, last_calibration_precision, source_raw) VALUES
  ('7f400000-0000-0000-0000-000000000001','available_in_store_uc','TGS-01','Male','1"','1"',30,30,'PSI',NULL,'unknown','{}'),
  ('7f400000-0000-0000-0000-000000000002','available_calibrated','TGS-02','Male','1"','1"',30,30,'PSI','2026-09-30','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000003','available_calibrated','TGS-03','Male','3/4"','1"',30,30,'PSI','2026-09-15','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000004','available_in_store_uc','TGS-04','Male','3/4"','1"',30,30,'PSI',NULL,'unknown','{}'),
  ('7f400000-0000-0000-0000-000000000005','available_calibrated','TGS-05','Male','3/4"','1"',30,30,'PSI','2026-07-01','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000006','available_new','TGS-06','Male','3/4"','1"',30,30,'PSI',NULL,'unknown','{}'),
  ('7f400000-0000-0000-0000-000000000007','available_calibrated','TGS-07','Male','1"','1"',30,30,'PSI','2026-08-10','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000008','available_calibrated','TGS-08','Male','1/2"','3/4"',90,90,'BAR','2026-01-01','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000009','available_calibrated','TGS-09','Flange','1-1/4"','1 1/2"',30,30,'PSI','2026-02-01','exact_date','{}'),
  ('7f400000-0000-0000-0000-000000000010','available_calibrated','TGS-10','Flange','Flange',NULL,30,30,'PSI','2026-02-01','exact_date','{}');

-- The exact order the Warehouse tab asks for (useSrvManagement WAREHOUSE_SORT.pressure).
CREATE TEMP VIEW got AS
SELECT row_number() OVER (ORDER BY pressure_sort_bar, inlet_sort_in NULLS LAST, outlet_sort_in NULLS LAST, inlet_size, outlet_size,
                                   size_type, availability_rank, last_calibration_date NULLS LAST, warehouse_code, id) AS n,
       serial_number, inlet_sort_in, outlet_sort_in, availability_rank
  FROM v_srv_warehouse_stock WHERE serial_number LIKE 'TGS-%';

SELECT pg_temp.ck('GS-1 30 PSI 3/4": calibrated oldest first (Jul, 15 Sep), then new, then under calibration',
  (SELECT array_agg(serial_number ORDER BY n) FROM got WHERE n <= 4) = ARRAY['TGS-05','TGS-03','TGS-06','TGS-04']);
SELECT pg_temp.ck('GS-2 then 30 PSI 1": calibrated (Aug, 30 Sep), then under calibration',
  (SELECT array_agg(serial_number ORDER BY n) FROM got WHERE n BETWEEN 5 AND 7) = ARRAY['TGS-07','TGS-02','TGS-01']);
SELECT pg_temp.ck('GS-3 a bigger size of the same pressure follows; a size that is not a number sorts after every size; a higher pressure comes last',
  (SELECT array_agg(serial_number ORDER BY n) FROM got WHERE n >= 8) = ARRAY['TGS-09','TGS-10','TGS-08']);
SELECT pg_temp.ck('GS-4 sizes are read in inches from the recorded text, nothing guessed',
  (SELECT inlet_sort_in = 0.75 AND outlet_sort_in = 1 FROM got WHERE serial_number = 'TGS-03')
  AND (SELECT inlet_sort_in = 1.25 AND outlet_sort_in = 1.5 FROM got WHERE serial_number = 'TGS-09')
  AND (SELECT inlet_sort_in IS NULL AND outlet_sort_in IS NULL FROM got WHERE serial_number = 'TGS-10'));
SELECT pg_temp.ck('GS-5 availability rank: calibrated 1, new 2, under calibration 3',
  (SELECT availability_rank FROM got WHERE serial_number = 'TGS-05') = 1
  AND (SELECT availability_rank FROM got WHERE serial_number = 'TGS-06') = 2
  AND (SELECT availability_rank FROM got WHERE serial_number = 'TGS-04') = 3);
SELECT pg_temp.ck('GS-6 the recorded values are untouched (the keys are read-only additions)',
  (SELECT inlet_size = '1-1/4"' AND outlet_size = '1 1/2"' FROM v_srv_warehouse_stock WHERE serial_number = 'TGS-09'));
SELECT pg_temp.ck('GS-7 the view still runs with the caller''s rights (security_invoker) and anon has no access',
  (SELECT reloptions::text LIKE '%security_invoker=true%' FROM pg_class WHERE relname = 'v_srv_warehouse_stock')
  AND NOT has_table_privilege('anon', 'v_srv_warehouse_stock', 'SELECT')
  AND has_table_privilege('authenticated', 'v_srv_warehouse_stock', 'SELECT'));

-- As a signed-in user, the new columns are readable and ordering by them works (what PostgREST will do).
SELECT set_config('request.jwt.claims', json_build_object('sub', 'gs_viewer', 'role', 'authenticated')::text, true);
SET LOCAL ROLE authenticated;
CREATE TEMP TABLE seen AS
SELECT serial_number FROM v_srv_warehouse_stock WHERE serial_number LIKE 'TGS-%'
 ORDER BY pressure_sort_bar, inlet_sort_in, outlet_sort_in, availability_rank, last_calibration_date LIMIT 1;
RESET ROLE;
SELECT pg_temp.ck('GS-8 a signed-in user reads and orders by the new keys', (SELECT serial_number FROM seen) = 'TGS-05');

ROLLBACK;
