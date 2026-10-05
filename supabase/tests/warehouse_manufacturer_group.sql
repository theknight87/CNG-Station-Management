-- warehouse_manufacturer_group.sql — regression suite for 20261005090000_warehouse_manufacturer_group.sql (owner 2026-10-05):
-- the store list groups each manufacturer, Mercer and Anderson (incl. Tyco Anderson) as one family; the view keeps the
-- caller's rights.
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, manufacturer, source_raw) VALUES
  ('9e400000-0000-0000-0000-000000000001', 'available_new', 'TMG-1', 'Mercer', '{}'),
  ('9e400000-0000-0000-0000-000000000002', 'available_new', 'TMG-2', ' ANDERSON ', '{}'),
  ('9e400000-0000-0000-0000-000000000003', 'available_new', 'TMG-3', 'Tyco Anderson', '{}'),
  ('9e400000-0000-0000-0000-000000000004', 'available_new', 'TMG-4', 'Technical', '{}'),
  ('9e400000-0000-0000-0000-000000000005', 'available_new', 'TMG-5', NULL, '{}');

SELECT pg_temp.ck('MG-1 Mercer, Anderson and Tyco Anderson share one family; others keep their own (case and spaces folded)',
  (SELECT count(DISTINCT manufacturer_group) = 1 AND min(manufacturer_group) = 'anderson / mercer'
     FROM v_srv_warehouse_stock WHERE serial_number IN ('TMG-1', 'TMG-2', 'TMG-3'))
  AND (SELECT manufacturer_group = 'technical' FROM v_srv_warehouse_stock WHERE serial_number = 'TMG-4'));
SELECT pg_temp.ck('MG-2 a valve with no manufacturer has no family (it sorts last), and its row is not lost',
  (SELECT manufacturer_group IS NULL FROM v_srv_warehouse_stock WHERE serial_number = 'TMG-5'));
SELECT pg_temp.ck('MG-3 the store list still runs with the caller''s rights and keeps the Unit columns',
  (SELECT 'security_invoker=true' = ANY (reloptions) FROM pg_class WHERE relname = 'v_srv_warehouse_stock')
  AND (SELECT count(*) FROM information_schema.columns WHERE table_name = 'v_srv_warehouse_stock'
         AND column_name IN ('target_unit_id', 'target_unit_name', 'manufacturer_group')) = 3);
ROLLBACK;
