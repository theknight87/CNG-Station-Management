-- warehouse_raw_station_30d.sql — regression suite for 20261001120000_warehouse_station_raw.sql and
-- 20261001130000_attention_30d_everywhere.sql (owner requests 2026-10-01).
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

INSERT INTO stations (id, region_id, station_name) SELECT '7e100000-0000-0000-0000-000000000001', id, 'WRS ALPHA' FROM regions WHERE name = 'Upper';

-- Warehouse: one valve sent to a Station the sheet names but the system does not hold, one linked, one plain stock.
INSERT INTO warehouse_relief_valves (id, availability_status, serial_number, target_region_id, target_station_id, source_raw)
SELECT v.id::uuid, v.st::warehouse_availability, v.sn, r.id, v.sid::uuid, v.raw::jsonb
  FROM regions r, (VALUES
    ('7e300000-0000-0000-0000-000000000001', 'available_in_store_uc', 'WRS-RAW', NULL, '{"Station":"  بني سويف 3 "}'),
    ('7e300000-0000-0000-0000-000000000002', 'available_in_store_uc', 'WRS-LINK', '7e100000-0000-0000-0000-000000000001', '{"Station":"WRS ALPHA"}'),
    ('7e300000-0000-0000-0000-000000000003', 'available_calibrated', 'WRS-STOCK', NULL, '{}')) v(id, st, sn, sid, raw)
 WHERE r.name = 'Upper';

SELECT pg_temp.ck('WRS-1 an unlinked destination shows the sheet text, trimmed, and is not called unassigned stock',
  (SELECT target_station_raw = 'بني سويف 3' AND target_station_id IS NULL AND NOT is_unassigned_stock
     FROM v_warehouse_srv_management WHERE id = '7e300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('WRS-2 the raw text never creates a link: target_station_id stays NULL on the table',
  (SELECT target_station_id IS NULL FROM warehouse_relief_valves WHERE id = '7e300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('WRS-3 stock with no Station in the sheet and none linked is still unassigned stock',
  (SELECT is_unassigned_stock AND target_station_raw IS NULL FROM v_warehouse_srv_management WHERE id = '7e300000-0000-0000-0000-000000000003'));
SELECT pg_temp.ck('WRS-4 the stock view the page reads carries the same raw destination',
  (SELECT target_station_raw = 'بني سويف 3' FROM v_srv_warehouse_stock WHERE id = '7e300000-0000-0000-0000-000000000001')
  AND (SELECT target_station_name = 'WRS ALPHA' FROM v_srv_warehouse_stock WHERE id = '7e300000-0000-0000-0000-000000000002'));

-- 30-day window: one hose due in 20 days (counts), one due in 45 days (due_60 — no longer counts).
INSERT INTO hoses (region_id, station_id, mapping_status, serial_number, next_test_date, next_test_precision)
SELECT r.id, '7e100000-0000-0000-0000-000000000001', 'needs_unit_mapping', v.sn, cng_business_date() + v.d, 'exact_date'
  FROM regions r, (VALUES ('WRS-H20', 20), ('WRS-H45', 45)) v(sn, d) WHERE r.name = 'Upper';

SELECT pg_temp.ck('WRS-5 the Station counts only the hose due within 30 days as approaching due',
  (SELECT approaching_due = 1 FROM v_station_summary WHERE station_id = '7e100000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('WRS-6 the 45-day hose is still classified due_60, it is just not "approaching"',
  (SELECT cng_due_status(next_test_date, next_test_precision) = 'due_60' FROM hoses WHERE serial_number = 'WRS-H45'));
SELECT pg_temp.ck('WRS-7 no attention / approaching list in the summary views contains due_60',
  (SELECT bool_and(position('''due_30''::due_status, ''due_60''::due_status]' IN pg_get_viewdef(oid)) = 0) FROM pg_class
    WHERE relname IN ('v_station_summary','v_dashboard_region_summary','v_dashboard_warehouse_summary','v_hose_summary')));
SELECT pg_temp.ck('WRS-8 the replaced views still run with the caller''s rights',
  (SELECT bool_and(reloptions @> ARRAY['security_invoker=true']) FROM pg_class
    WHERE relname IN ('v_warehouse_srv_management','v_srv_warehouse_stock','v_station_summary','v_dashboard_region_summary',
                      'v_dashboard_warehouse_summary','v_hose_summary')));
ROLLBACK;
