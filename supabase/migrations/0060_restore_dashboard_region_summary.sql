-- Roll back 0059 after production measurements showed no improvement.
-- Keep the successful RLS initplan optimization from 0058 unchanged.

CREATE OR REPLACE VIEW public.v_dashboard_region_summary
WITH (security_invoker = true) AS
SELECT
  r.id   AS region_id,
  r.code AS region_code,
  r.name AS region_name,
  r.sort_order,
  (SELECT count(*) FROM public.stations s WHERE s.region_id = r.id)::bigint AS stations,
  (SELECT count(*) FROM public.units u WHERE u.region_id = r.id)::bigint    AS units,
  (
    (SELECT count(*) FROM public.installed_relief_valves v WHERE v.region_id = r.id) +
    (SELECT count(*) FROM public.storage_vessels sv WHERE sv.region_id = r.id) +
    (SELECT count(*) FROM public.recovery_tanks rt WHERE rt.region_id = r.id) +
    (SELECT count(*) FROM public.gas_detectors g WHERE g.region_id = r.id) +
    (SELECT count(*) FROM public.hoses h WHERE h.region_id = r.id)
  )::bigint AS assets,
  (
    (SELECT count(*) FROM public.installed_relief_valves v
      WHERE v.region_id = r.id
        AND public.cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM public.storage_vessels sv
      WHERE sv.region_id = r.id
        AND public.cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM public.recovery_tanks rt
      WHERE rt.region_id = r.id
        AND public.cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM public.gas_detectors g
      WHERE g.region_id = r.id
        AND public.cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM public.hoses h
      WHERE h.region_id = r.id
        AND public.cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue')
  )::bigint AS overdue,
  (
    (SELECT count(*) FROM public.installed_relief_valves v
      WHERE v.region_id = r.id
        AND public.cng_due_status(v.next_calibration_date, v.next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM public.storage_vessels sv
      WHERE sv.region_id = r.id
        AND public.cng_due_status(sv.next_inspection_date, sv.next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM public.recovery_tanks rt
      WHERE rt.region_id = r.id
        AND public.cng_due_status(rt.next_inspection_date, rt.next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM public.gas_detectors g
      WHERE g.region_id = r.id
        AND public.cng_due_status(g.next_calibration_date, g.next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM public.hoses h
      WHERE h.region_id = r.id
        AND public.cng_due_status(h.next_test_date, h.next_test_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
  )::bigint AS approaching_due,
  (
    (SELECT count(*) FROM public.installed_relief_valves v
      WHERE v.region_id = r.id AND v.mapping_status <> 'resolved') +
    (SELECT count(*) FROM public.storage_vessels sv
      WHERE sv.region_id = r.id AND sv.mapping_status <> 'resolved') +
    (SELECT count(*) FROM public.recovery_tanks rt
      WHERE rt.region_id = r.id AND rt.mapping_status <> 'resolved') +
    (SELECT count(*) FROM public.gas_detectors g
      WHERE g.region_id = r.id AND g.mapping_status <> 'resolved') +
    (SELECT count(*) FROM public.hoses h
      WHERE h.region_id = r.id AND h.mapping_status <> 'resolved')
  )::bigint AS unresolved_mapping
FROM public.regions r;

COMMENT ON VIEW public.v_dashboard_region_summary IS
  'One row per region the caller may read. A region outside the caller scope produces no row, so its size cannot be inferred from the dashboard.';
