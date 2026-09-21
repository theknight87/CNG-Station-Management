-- Classify due dates with one business-date lookup per statement.
-- The previous view called cng_due_status() for every asset row; that helper in
-- turn evaluated cng_business_date() repeatedly inside its CASE expression.
-- This keeps the exact bucket semantics while making the statement-wide value
-- explicit and reusable.

CREATE OR REPLACE VIEW public.v_dashboard_due_summary
WITH (security_invoker = true) AS
WITH business_clock AS MATERIALIZED (
  SELECT public.cng_business_date() AS today
),
due_facts AS MATERIALIZED (
  SELECT
    'installed_relief_valve'::text AS asset_kind,
    next_calibration_date AS due_date,
    next_calibration_precision AS due_precision
  FROM public.installed_relief_valves

  UNION ALL

  SELECT 'storage_vessel', next_inspection_date, next_inspection_precision
  FROM public.storage_vessels

  UNION ALL

  SELECT 'recovery_tank', next_inspection_date, next_inspection_precision
  FROM public.recovery_tanks

  UNION ALL

  SELECT 'gas_detector', next_calibration_date, next_calibration_precision
  FROM public.gas_detectors

  UNION ALL

  SELECT 'hose', next_test_date, next_test_precision
  FROM public.hoses
),
classified AS (
  SELECT
    f.asset_kind,
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
  FROM due_facts f
  CROSS JOIN business_clock b
)
SELECT asset_kind, due_status, count(*)::bigint AS total
FROM classified
GROUP BY asset_kind, due_status;

COMMENT ON VIEW public.v_dashboard_due_summary IS
  'Asset kind x mutually exclusive due bucket under caller RLS. The Cairo business date is evaluated once per statement.';
