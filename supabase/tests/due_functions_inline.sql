-- due_functions_inline.sql — regression suite for 20261002090000_due_functions_inline.sql (owner report 2026-10-02:
-- tile clicks and due filters were slow because the due-date functions could not be inlined).
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

SELECT pg_temp.ck('DFI-1 the three due functions set no configuration, so the planner can inline them',
  (SELECT count(*) = 3 AND bool_and(proconfig IS NULL) FROM pg_proc
    WHERE proname IN ('cng_business_date', 'cng_days_left', 'cng_due_status') AND pronamespace = 'public'::regnamespace));
SELECT pg_temp.ck('DFI-2 they stay SECURITY INVOKER, STABLE SQL functions',
  (SELECT bool_and(NOT prosecdef AND provolatile = 's' AND prolang = (SELECT oid FROM pg_language WHERE lanname = 'sql'))
     FROM pg_proc WHERE proname IN ('cng_business_date', 'cng_days_left', 'cng_due_status') AND pronamespace = 'public'::regnamespace));

-- Same answers at every boundary (day 7 is due_7, day 8 is due_15; anything not exact is unknown and has no days).
SELECT pg_temp.ck('DFI-3 boundaries are unchanged',
  (SELECT bool_and(cng_due_status(cng_business_date() + d, 'exact_date') = s::due_status) FROM (VALUES
     (-1, 'overdue'), (0, 'due_today'), (1, 'due_7'), (7, 'due_7'), (8, 'due_15'), (15, 'due_15'), (16, 'due_30'),
     (30, 'due_30'), (31, 'due_60'), (60, 'due_60'), (61, 'valid')) v(d, s)));
SELECT pg_temp.ck('DFI-4 a non-exact or missing date is unknown and has no days left',
  cng_due_status(cng_business_date(), 'year_only') = 'unknown' AND cng_due_status(NULL, 'exact_date') = 'unknown'
  AND cng_days_left(cng_business_date(), 'year_only') IS NULL AND cng_days_left(cng_business_date() + 5, 'exact_date') = 5);
SELECT pg_temp.ck('DFI-5 the business date is the Cairo calendar date',
  cng_business_date() = (now() AT TIME ZONE 'Africa/Cairo')::date);

-- The point of the change: a due filter is planned as an expression, not as a call per row.
CREATE FUNCTION pg_temp.plan_mentions(q text, fn text) RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE l text; hit boolean := false;
BEGIN
  FOR l IN EXECUTE 'EXPLAIN (VERBOSE, COSTS OFF) ' || q LOOP
    IF position(fn IN l) > 0 THEN hit := true; END IF;
  END LOOP;
  RETURN hit;
END $$;
SELECT pg_temp.ck('DFI-6 filtering installed valves by due state inlines cng_due_status and cng_business_date',
  NOT pg_temp.plan_mentions($q$SELECT count(*) FROM installed_relief_valves
                               WHERE cng_due_status(next_calibration_date, next_calibration_precision) = 'overdue'$q$, 'cng_due_status')
  AND NOT pg_temp.plan_mentions($q$SELECT count(*) FROM installed_relief_valves
                               WHERE cng_due_status(next_calibration_date, next_calibration_precision) = 'overdue'$q$, 'cng_business_date'));
ROLLBACK;
