-- rls_initplan_perf.sql — regression suite for 20260923130000_rls_initplan_alerts_audit.sql
--
-- Proves two things and rolls everything back:
--   1. SHAPE: each row-independent permission check in alerts_select and
--      audit_logs_select is an InitPlan (evaluated once per statement), never a
--      per-row Filter call. It is read from EXPLAIN, not trusted from the policy text.
--   2. AUTHORIZATION UNCHANGED: an exact visibility matrix for authorized and
--      unauthorized callers over both tables and both views.
-- Run: psql -v ON_ERROR_STOP=1 -f supabase/tests/rls_initplan_perf.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

-- Runs one statement as `authenticated` with the given subject (NULL = no subject)
-- and returns its single scalar result. Role and claims are restored afterwards.
CREATE FUNCTION pg_temp.as_user(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
  PERFORM set_config('request.jwt.claims',
    CASE WHEN p_sub IS NULL THEN '{"role":"authenticated"}'
         ELSE json_build_object('sub', p_sub, 'role', 'authenticated')::text END, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  EXECUTE p_sql INTO r;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN r;
END $$;

-- Full EXPLAIN text for a statement run as the given subject.
CREATE FUNCTION pg_temp.plan_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE l text; o text := '';
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_sub, 'role', 'authenticated')::text, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
  FOR l IN EXECUTE 'EXPLAIN (COSTS OFF) ' || p_sql LOOP o := o || l || chr(10); END LOOP;
  EXECUTE 'RESET ROLE';
  PERFORM set_config('request.jwt.claims', '', true);
  RETURN o;
END $$;

-- ---------------------------------------------------------------- fixture
INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('b1000000-0000-0000-0000-00000000000a','perf_admin',   'admin',    true,  'TESTDATA Perf Admin'),
  ('b1000000-0000-0000-0000-00000000000b','perf_manager', 'manager',  true,  'TESTDATA Perf Manager'),
  ('b1000000-0000-0000-0000-00000000000c','perf_eng_east','engineer', true,  'TESTDATA Perf Eng East'),
  ('b1000000-0000-0000-0000-00000000000d','perf_eng_west','engineer', true,  'TESTDATA Perf Eng West'),
  ('b1000000-0000-0000-0000-00000000000e','perf_view_east','viewer',  true,  'TESTDATA Perf Viewer East'),
  ('b1000000-0000-0000-0000-00000000000f','perf_inactive','admin',    false, 'TESTDATA Perf Inactive Admin');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT 'b1000000-0000-0000-0000-00000000000c'::uuid, id, true  FROM regions WHERE name = 'East'
UNION ALL SELECT 'b1000000-0000-0000-0000-00000000000d'::uuid, id, true  FROM regions WHERE name = 'West'
UNION ALL SELECT 'b1000000-0000-0000-0000-00000000000e'::uuid, id, false FROM regions WHERE name = 'East';

INSERT INTO stations (id, region_id, station_name)
SELECT 'b2000000-0000-0000-0000-0000000000e1'::uuid, id, 'TESTDATA-PERF-EAST' FROM regions WHERE name = 'East'
UNION ALL
SELECT 'b2000000-0000-0000-0000-0000000000f1'::uuid, id, 'TESTDATA-PERF-WEST' FROM regions WHERE name = 'West';

-- Three alerts: East-bound, West-bound, and Station-less (unmapped SRV, East Region).
INSERT INTO alerts (id, alert_rule_id, subject, threshold, asset_type, asset_id, region_id, station_id,
                    due_date, needs_mapping, needs_station_mapping)
SELECT v.id, ar.id, ar.subject, ar.threshold, 'installed_relief_valve', gen_random_uuid(),
       (SELECT id FROM regions WHERE name = v.reg), v.st, date '2026-10-01', v.st IS NULL, v.st IS NULL
  FROM (VALUES ('b3000000-0000-0000-0000-000000000001'::uuid, 'East', 'b2000000-0000-0000-0000-0000000000e1'::uuid),
               ('b3000000-0000-0000-0000-000000000002'::uuid, 'West', 'b2000000-0000-0000-0000-0000000000f1'::uuid),
               ('b3000000-0000-0000-0000-000000000003'::uuid, 'East', NULL::uuid)) v(id, reg, st)
 CROSS JOIN (SELECT * FROM alert_rules ORDER BY id LIMIT 1) ar;

-- Four audit rows: by admin, by East engineer, by viewer, and a service row (actor NULL).
INSERT INTO audit_logs (id, action, entity_table, entity_id, actor_id, actor_label, summary, occurred_at)
SELECT v.id, 'import_executed', 'alerts', gen_random_uuid(), v.actor, 'perf', 'TESTDATA-PERF', now()
  FROM (VALUES ('b4000000-0000-0000-0000-000000000001'::uuid, 'b1000000-0000-0000-0000-00000000000a'::uuid),
               ('b4000000-0000-0000-0000-000000000002'::uuid, 'b1000000-0000-0000-0000-00000000000c'::uuid),
               ('b4000000-0000-0000-0000-000000000003'::uuid, 'b1000000-0000-0000-0000-00000000000e'::uuid),
               ('b4000000-0000-0000-0000-000000000004'::uuid, NULL::uuid)) v(id, actor);

-- ---------------------------------------------------------------- 1. catalog shape
SELECT pg_temp.ck('RLSPERF-1  alerts_select and audit_logs_select remain PERMISSIVE SELECT policies for authenticated only',
  (SELECT count(*) = 2 FROM pg_policies
    WHERE (tablename, policyname) IN (('alerts','alerts_select'), ('audit_logs','audit_logs_select'))
      AND cmd = 'SELECT' AND permissive = 'PERMISSIVE' AND roles = '{authenticated}'));
SELECT pg_temp.ck('RLSPERF-2  alerts_select wraps cng_can_access_unmapped_srv() in a scalar sub-SELECT',
  (SELECT qual LIKE '%( SELECT cng_can_access_unmapped_srv()%' FROM pg_policies WHERE policyname = 'alerts_select'));
SELECT pg_temp.ck('RLSPERF-3  alerts_select keeps the row-dependent cng_can_read_region(s.region_id) check',
  (SELECT qual LIKE '%cng_can_read_region(s.region_id)%' FROM pg_policies WHERE policyname = 'alerts_select'));
SELECT pg_temp.ck('RLSPERF-4  audit_logs_select wraps cng_is_admin() and cng_current_app_user_id() in sub-SELECTs',
  (SELECT qual LIKE '%( SELECT cng_is_admin()%' AND qual LIKE '%( SELECT cng_current_app_user_id()%'
     FROM pg_policies WHERE policyname = 'audit_logs_select'));

-- ---------------------------------------------------------------- 2. plan shape (once per statement)
-- A per-row call shows up as the function name inside a Filter line. An InitPlan
-- shows up as "(InitPlan n).col1" in the Filter and the name never appears there.
SELECT pg_temp.ck('RLSPERF-5  alerts: cng_can_access_unmapped_srv() is an InitPlan, not a per-row Filter call',
  (SELECT p ~ 'InitPlan' AND NOT EXISTS (
            SELECT 1 FROM regexp_split_to_table(p, chr(10)) ln
             WHERE ln ~ 'Filter:' AND ln ~ 'cng_can_access_unmapped_srv\(\)')
     FROM (SELECT pg_temp.plan_as('perf_admin', 'SELECT count(*) FROM alerts') p) z));
SELECT pg_temp.ck('RLSPERF-6  audit_logs: cng_is_admin() is an InitPlan, not a per-row Filter call',
  (SELECT p ~ 'InitPlan' AND NOT EXISTS (
            SELECT 1 FROM regexp_split_to_table(p, chr(10)) ln
             WHERE ln ~ 'Filter:' AND ln ~ 'cng_is_admin\(\)')
     FROM (SELECT pg_temp.plan_as('perf_admin', 'SELECT count(*) FROM audit_logs') p) z));
SELECT pg_temp.ck('RLSPERF-7  audit_logs: cng_current_app_user_id() is an InitPlan, not a per-row Filter call',
  (SELECT NOT EXISTS (
            SELECT 1 FROM regexp_split_to_table(p, chr(10)) ln
             WHERE ln ~ 'Filter:' AND ln ~ 'cng_current_app_user_id\(\)')
     FROM (SELECT pg_temp.plan_as('perf_view_east', 'SELECT count(*) FROM audit_logs') p) z));

-- ---------------------------------------------------------------- 3. visibility matrix
-- Only this suite's fixture rows are counted, so pre-existing data cannot move a result.
CREATE TEMP TABLE expect (who text, sub text, alerts int, audit int);
INSERT INTO expect VALUES
  ('admin',                  'perf_admin',     3, 4),  -- everything
  ('manager',                'perf_manager',   3, 0),  -- all alerts incl. unmapped; audit: only own rows (none)
  ('engineer East',          'perf_eng_east',  1, 1),  -- East alert only; NOT the Station-less one; own audit row
  ('engineer West',          'perf_eng_west',  1, 0),  -- West alert only; no audit rows of their own
  ('viewer East',            'perf_view_east', 1, 1),  -- East alert only; own audit row
  ('inactive admin',         'perf_inactive',  0, 0),  -- deactivated: nothing, despite role admin
  ('no subject',             NULL,             0, 0),  -- unauthenticated claims: nothing
  ('unknown subject',        'perf_nobody',    0, 0);  -- a subject with no app_user: nothing
GRANT SELECT ON expect TO authenticated;

SELECT pg_temp.ck(format('RLSPERF-%s  %s sees %s alert(s) in alerts and v_alert_inbox', 7 + n, who, alerts),
         pg_temp.as_user(sub, $q$SELECT count(*) FROM alerts WHERE id::text LIKE 'b3000000-%'$q$)::int = alerts
     AND pg_temp.as_user(sub, $q$SELECT count(*) FROM v_alert_inbox WHERE id::text LIKE 'b3000000-%'$q$)::int = alerts)
  FROM (SELECT *, row_number() OVER () n FROM expect) e;

SELECT pg_temp.ck(format('RLSPERF-%s  %s sees %s audit row(s) in audit_logs and v_admin_audit_log', 15 + n, who, audit),
         pg_temp.as_user(sub, $q$SELECT count(*) FROM audit_logs WHERE summary = 'TESTDATA-PERF'$q$)::int = audit
     AND pg_temp.as_user(sub, $q$SELECT count(*) FROM v_admin_audit_log WHERE id::text LIKE 'b4000000-%'$q$)::int = audit)
  FROM (SELECT *, row_number() OVER () n FROM expect) e;

SELECT pg_temp.ck('RLSPERF-24 a Region-scoped engineer never sees the Station-less (unmapped) alert',
  pg_temp.as_user('perf_eng_east',
    $q$SELECT count(*) FROM alerts WHERE id = 'b3000000-0000-0000-0000-000000000003'$q$)::int = 0);
SELECT pg_temp.ck('RLSPERF-25 a non-admin never sees another user''s or a service audit row',
  pg_temp.as_user('perf_eng_east',
    $q$SELECT count(*) FROM audit_logs WHERE id IN ('b4000000-0000-0000-0000-000000000001',
        'b4000000-0000-0000-0000-000000000003','b4000000-0000-0000-0000-000000000004')$q$)::int = 0);

ROLLBACK;
