-- 20260923130000_rls_initplan_alerts_audit.sql
-- Evaluate row-independent permission checks ONCE PER QUERY in two SELECT
-- policies (Phase 3 performance, measured in production 2026-09-23).
--
-- ADDS NO TABLE, COLUMN, FUNCTION, GRANT OR POLICY. It ALTERs the USING clause
-- of exactly two existing policies. Names, commands, roles and PERMISSIVE mode
-- are unchanged because ALTER POLICY ... USING changes nothing else.
--
-- THE DEFECT (performance only):
--   alerts_select      called cng_can_access_unmapped_srv() once per row
--                      with station_id NULL (1,500 calls for 1,500 rows).
--   audit_logs_select  called cng_is_admin() once per row (5,000 calls for
--                      5,000 rows), about 0.24 ms each under production RLS.
-- Neither function takes a row argument. Both are STABLE and read only the
-- caller's identity, so the result is the same for every row of a statement.
--
-- THE FIX: wrap each call in a scalar sub-SELECT. PostgreSQL then plans it as
-- an InitPlan and evaluates it once per statement (the standard Supabase RLS
-- pattern). The boolean result is identical, NULL included: a sub-SELECT
-- over a function returns exactly that function's value. The row-DEPENDENT
-- check (cng_can_read_region(s.region_id) inside the EXISTS) is deliberately
-- left as it is.
--
-- AUTHORIZATION IS UNCHANGED, and this is proved rather than asserted: the
-- visible id set of alerts, audit_logs, v_alert_inbox and v_admin_audit_log
-- is fingerprinted for admin, manager, engineer, viewer, inactive and
-- no-subject callers, and must be identical before and after
-- (supabase/tests/rls_initplan_perf.sql).

ALTER POLICY alerts_select ON alerts
  USING (
    CASE
      WHEN station_id IS NOT NULL THEN EXISTS (
        SELECT 1 FROM stations s
         WHERE s.id = alerts.station_id
           AND cng_can_read_region(s.region_id))
      ELSE (SELECT cng_can_access_unmapped_srv())
    END
  );

ALTER POLICY audit_logs_select ON audit_logs
  USING (
    (SELECT cng_is_admin()) OR actor_id = (SELECT cng_current_app_user_id())
  );
