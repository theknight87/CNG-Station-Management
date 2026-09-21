-- Combine the single-pass region aggregation with the measured fast due-date
-- classifier from 0061. Unlike 0059, this evaluates the Cairo business date
-- once rather than calling cng_due_status() for every asset row.

CREATE OR REPLACE VIEW public.v_dashboard_region_summary
WITH (security_invoker = true) AS
WITH business_clock AS MATERIALIZED (
  SELECT public.cng_business_date() AS today
),
station_counts AS MATERIALIZED (
  SELECT region_id, count(*)::bigint AS stations
  FROM public.stations
  GROUP BY region_id
),
unit_counts AS MATERIALIZED (
  SELECT region_id, count(*)::bigint AS units
  FROM public.units
  GROUP BY region_id
),
asset_facts AS MATERIALIZED (
  SELECT
    region_id,
    next_calibration_date AS due_date,
    next_calibration_precision AS due_precision,
    mapping_status::text AS mapping_status
  FROM public.installed_relief_valves

  UNION ALL

  SELECT region_id, next_inspection_date, next_inspection_precision, mapping_status::text
  FROM public.storage_vessels

  UNION ALL

  SELECT region_id, next_inspection_date, next_inspection_precision, mapping_status::text
  FROM public.recovery_tanks

  UNION ALL

  SELECT region_id, next_calibration_date, next_calibration_precision, mapping_status::text
  FROM public.gas_detectors

  UNION ALL

  SELECT region_id, next_test_date, next_test_precision, mapping_status::text
  FROM public.hoses
),
classified_assets AS MATERIALIZED (
  SELECT
    f.region_id,
    f.mapping_status,
    CASE
      WHEN f.due_precision <> 'exact_date' OR f.due_date IS NULL THEN 'unknown'::public.due_status
      WHEN f.due_date <  b.today      THEN 'overdue'::public.due_status
      WHEN f.due_date =  b.today      THEN 'due_today'::public.due_status
      WHEN f.due_date <= b.today + 7  THEN 'due_7'::public.due_status
      WHEN f.due_date <= b.today + 15 THEN 'due_15'::public.due_status
      WHEN f.due_date <= b.today + 30 THEN 'due_30'::public.due_status
      WHEN f.due_date <= b.today + 60 THEN 'due_60'::public.due_status
      ELSE 'valid'::public.due_status
    END AS due_status
  FROM asset_facts f
  CROSS JOIN business_clock b
),
asset_counts AS MATERIALIZED (
  SELECT
    region_id,
    count(*)::bigint AS assets,
    count(*) FILTER (WHERE due_status = 'overdue')::bigint AS overdue,
    count(*) FILTER (
      WHERE due_status IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')
    )::bigint AS approaching_due,
    count(*) FILTER (WHERE mapping_status <> 'resolved')::bigint AS unresolved_mapping
  FROM classified_assets
  GROUP BY region_id
)
SELECT
  r.id AS region_id,
  r.code AS region_code,
  r.name AS region_name,
  r.sort_order,
  coalesce(sc.stations, 0::bigint) AS stations,
  coalesce(uc.units, 0::bigint) AS units,
  coalesce(ac.assets, 0::bigint) AS assets,
  coalesce(ac.overdue, 0::bigint) AS overdue,
  coalesce(ac.approaching_due, 0::bigint) AS approaching_due,
  coalesce(ac.unresolved_mapping, 0::bigint) AS unresolved_mapping
FROM public.regions r
LEFT JOIN station_counts sc ON sc.region_id = r.id
LEFT JOIN unit_counts uc ON uc.region_id = r.id
LEFT JOIN asset_counts ac ON ac.region_id = r.id;

COMMENT ON VIEW public.v_dashboard_region_summary IS
  'One RLS-scoped row per visible region. Source tables and the Cairo business date are each evaluated once per statement.';
