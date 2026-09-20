-- Return the complete dashboard snapshot in one authenticated round trip.
-- SECURITY INVOKER is intentional: every underlying dashboard view retains
-- the caller's RLS scope, exactly as when the browser queried each view alone.

CREATE OR REPLACE FUNCTION public.cng_dashboard_snapshot()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT jsonb_build_object(
    'assets', coalesce(
      (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.asset_kind)
         FROM public.v_dashboard_asset_counts v),
      '[]'::jsonb
    ),
    'due', coalesce(
      (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.asset_kind, v.due_status)
         FROM public.v_dashboard_due_summary v),
      '[]'::jsonb
    ),
    'regions', coalesce(
      (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.sort_order)
         FROM public.v_dashboard_region_summary v),
      '[]'::jsonb
    ),
    'mapping', coalesce(
      (SELECT jsonb_agg(to_jsonb(v) ORDER BY v.asset_kind, v.mapping_status)
         FROM public.v_dashboard_mapping_summary v),
      '[]'::jsonb
    ),
    'warehouse', coalesce(
      (SELECT to_jsonb(v) FROM public.v_dashboard_warehouse_summary v LIMIT 1),
      jsonb_build_object('total', 0, 'overdue', 0, 'approaching_due', 0)
    )
  );
$$;

REVOKE ALL ON FUNCTION public.cng_dashboard_snapshot() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cng_dashboard_snapshot() TO authenticated;

COMMENT ON FUNCTION public.cng_dashboard_snapshot() IS
  'Returns all five RLS-scoped dashboard summaries in one network request.';
