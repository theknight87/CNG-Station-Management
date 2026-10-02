-- dashboard_insights.sql — regression suite for 20261002110000_dashboard_insights.sql (owner request 2026-10-02:
-- the dashboard's Data quality strip is replaced by insights from the data).
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

SELECT pg_temp.ck('DINS-1 both insight views run with the caller''s rights (security_invoker), so RLS bounds every count',
  (SELECT count(*) = 2 FROM pg_class c
    WHERE c.relname IN ('v_dashboard_station_overdue', 'v_dashboard_srv_manufacturer_due')
      AND c.relnamespace = 'public'::regnamespace AND 'security_invoker=true' = ANY (c.reloptions)));
SELECT pg_temp.ck('DINS-2 authenticated may read them and write nothing; anon has no access',
  has_table_privilege('authenticated', 'public.v_dashboard_station_overdue', 'SELECT')
  AND has_table_privilege('authenticated', 'public.v_dashboard_srv_manufacturer_due', 'SELECT')
  AND NOT has_table_privilege('authenticated', 'public.v_dashboard_station_overdue', 'INSERT')
  AND NOT has_table_privilege('anon', 'public.v_dashboard_station_overdue', 'SELECT')
  AND NOT has_table_privilege('anon', 'public.v_dashboard_srv_manufacturer_due', 'SELECT'));
SELECT pg_temp.ck('DINS-3 per-Station overdue totals add up to the overdue rows of the due report that carry a Station',
  (SELECT coalesce(sum(overdue), 0) FROM v_dashboard_station_overdue)
  = (SELECT count(*) FROM v_report_due_compliance WHERE due_status = 'overdue' AND station_id IS NOT NULL));
SELECT pg_temp.ck('DINS-4 per-Station due-soon is overdue-free and stops at 30 days (due_60 is never "attention")',
  (SELECT coalesce(sum(approaching_due), 0) FROM v_dashboard_station_overdue)
  = (SELECT count(*) FROM v_report_due_compliance
      WHERE due_status IN ('due_today', 'due_7', 'due_15', 'due_30') AND station_id IS NOT NULL));
SELECT pg_temp.ck('DINS-5 manufacturer totals equal the installed valves that record a manufacturer',
  (SELECT coalesce(sum(total), 0) FROM v_dashboard_srv_manufacturer_due)
  = (SELECT count(*) FROM v_installed_srv_management WHERE manufacturer IS NOT NULL)
  AND (SELECT coalesce(sum(overdue), 0) FROM v_dashboard_srv_manufacturer_due)
  = (SELECT count(*) FROM v_installed_srv_management WHERE manufacturer IS NOT NULL AND due_status = 'overdue'));
SELECT pg_temp.ck('DINS-6 one row per Station and per manufacturer',
  (SELECT count(*) = count(DISTINCT station_id) FROM v_dashboard_station_overdue)
  AND (SELECT count(*) = count(DISTINCT manufacturer) FROM v_dashboard_srv_manufacturer_due));
ROLLBACK;
