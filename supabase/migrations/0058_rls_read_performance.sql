-- Cache caller-wide authorization checks once per statement.
--
-- The original read policies called cng_can_read_region(region_id) for every
-- visible candidate row. That helper resolves the caller's app_users row before
-- it can decide that an admin or manager has company-wide access. On asset
-- tables with thousands of rows this repeated the same identity lookup
-- thousands of times.
--
-- A scalar SELECT in an RLS policy becomes an initplan in PostgreSQL, so the
-- company-wide role check below is evaluated once per statement. Region-scoped
-- users still go through cng_has_region_grant(region_id, false), preserving the
-- exact authorization boundary.

ALTER POLICY regions_select ON public.regions
  USING (
    (SELECT public.cng_is_manager_or_admin())
    OR public.cng_has_region_grant(id, false)
  );

ALTER POLICY stations_select ON public.stations
  USING (
    (SELECT public.cng_is_manager_or_admin())
    OR public.cng_has_region_grant(region_id, false)
  );

ALTER POLICY units_select ON public.units
  USING (
    (SELECT public.cng_is_manager_or_admin())
    OR public.cng_has_region_grant(region_id, false)
  );

DO $policies$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'compressors', 'recovery_tanks', 'storage_vessels', 'dispensers',
    'gas_detectors', 'gas_detector_presence', 'hoses'
  ]
  LOOP
    EXECUTE format($policy$
      ALTER POLICY %1$I_select ON public.%1$I
        USING (
          (SELECT public.cng_is_manager_or_admin())
          OR public.cng_has_region_grant(region_id, false)
        )
    $policy$, t);
  END LOOP;
END;
$policies$;

ALTER POLICY irv_select ON public.installed_relief_valves
  USING (
    (SELECT public.cng_is_manager_or_admin())
    OR (
      station_id IS NOT NULL
      AND public.cng_has_region_grant(region_id, false)
    )
  );

ALTER POLICY wrv_select ON public.warehouse_relief_valves
  USING ((SELECT public.cng_current_role()) IS NOT NULL);
