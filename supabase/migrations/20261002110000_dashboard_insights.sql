-- Dashboard insights (owner request 2026-10-02): the Data quality strip leaves the dashboard and its space shows
-- what the data says about where work is piling up.
--
--   v_dashboard_station_overdue      — per Station: assets overdue, due within 30 days, and with a due date at all,
--                                      across every family the Due & Overdue report already unifies;
--   v_dashboard_srv_manufacturer_due — per manufacturer: installed relief valves, how many are overdue and how many
--                                      fall due within 30 days.
--
-- Both are aggregates over existing security_invoker views, so they are security_invoker too: every count is the
-- caller's own under RLS and never reveals a Region the caller may not read. Due states come from those views
-- (cng_due_status), not re-derived. Station-unconfirmed rows have no station_id and are left out of the per-Station
-- list rather than grouped under raw source text. No table, column, policy or data is touched.

CREATE VIEW public.v_dashboard_station_overdue WITH (security_invoker = true) AS
SELECT d.station_id,
       d.station_name,
       d.region_name,
       count(*) FILTER (WHERE d.due_status = 'overdue')::integer AS overdue,
       count(*) FILTER (WHERE d.due_status IN ('due_today', 'due_7', 'due_15', 'due_30'))::integer AS approaching_due,
       count(*)::integer AS assets
  FROM public.v_report_due_compliance d
 WHERE d.station_id IS NOT NULL
 GROUP BY d.station_id, d.station_name, d.region_name;

COMMENT ON VIEW public.v_dashboard_station_overdue IS
  'Dashboard insight: per Station, assets overdue / due within 30 days / total, over v_report_due_compliance. security_invoker, so RLS bounds every count.';

CREATE VIEW public.v_dashboard_srv_manufacturer_due WITH (security_invoker = true) AS
SELECT m.manufacturer,
       count(*)::integer AS total,
       count(*) FILTER (WHERE m.due_status = 'overdue')::integer AS overdue,
       count(*) FILTER (WHERE m.due_status IN ('due_today', 'due_7', 'due_15', 'due_30'))::integer AS approaching_due
  FROM public.v_installed_srv_management m
 WHERE m.manufacturer IS NOT NULL
 GROUP BY m.manufacturer;

COMMENT ON VIEW public.v_dashboard_srv_manufacturer_due IS
  'Dashboard insight: installed relief valves per manufacturer, overdue and due within 30 days. security_invoker, so RLS bounds every count.';

REVOKE ALL ON public.v_dashboard_station_overdue, public.v_dashboard_srv_manufacturer_due FROM PUBLIC, anon;
GRANT SELECT ON public.v_dashboard_station_overdue, public.v_dashboard_srv_manufacturer_due TO authenticated;
