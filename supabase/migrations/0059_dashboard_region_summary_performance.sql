-- Aggregate each RLS-scoped source once instead of running correlated counts
-- once per region. The public shape and security-invoker boundary are unchanged.

CREATE OR REPLACE VIEW public.v_dashboard_region_summary
WITH (security_invoker = true) AS
WITH station_counts AS MATERIALIZED (
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
    public.cng_due_status(next_calibration_date, next_calibration_precision) AS due_status,
    mapping_status::text AS mapping_status
  FROM public.installed_relief_valves

  UNION ALL

  SELECT
    region_id,
    public.cng_due_status(next_inspection_date, next_inspection_precision),
    mapping_status::text
  FROM public.storage_vessels

  UNION ALL

  SELECT
    region_id,
    public.cng_due_status(next_inspection_date, next_inspection_precision),
    mapping_status::text
  FROM public.recovery_tanks

  UNION ALL

  SELECT
    region_id,
    public.cng_due_status(next_calibration_date, next_calibration_precision),
    mapping_status::text
  FROM public.gas_detectors

  UNION ALL

  SELECT
    region_id,
    public.cng_due_status(next_test_date, next_test_precision),
    mapping_status::text
  FROM public.hoses
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
  FROM asset_facts
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
  'One row per region the caller may read. Each RLS-scoped source is aggregated once; a region outside the caller scope produces no row.';
