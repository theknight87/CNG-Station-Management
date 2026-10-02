-- multi_choice_filters.sql — regression suite for 20261002100000_multi_choice_filters.sql (owner request 2026-10-02:
-- filters may hold several values and may exclude them, e.g. overdue valves of every manufacturer except EKC).
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;
CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;

SELECT pg_temp.ck('MCF-1 no choice keeps every row, including an unrecorded value',
  cng_multi_match('EKC', NULL) AND cng_multi_match('EKC', '') AND cng_multi_match('EKC', 'all') AND cng_multi_match(NULL, ''));
SELECT pg_temp.ck('MCF-2 "only these" keeps exactly the listed values and never an unrecorded one',
  cng_multi_match('overdue', 'overdue') AND cng_multi_match('due_7', 'overdue|due_7')
  AND NOT cng_multi_match('valid', 'overdue|due_7') AND NOT cng_multi_match(NULL, 'overdue'));
SELECT pg_temp.ck('MCF-3 "all except" drops the listed values and keeps everything else, unrecorded included',
  NOT cng_multi_match('EKC', '!EKC') AND cng_multi_match('COI', '!EKC') AND cng_multi_match(NULL, '!EKC')
  AND NOT cng_multi_match('COI', '!EKC|COI'));
SELECT pg_temp.ck('MCF-4 a manufacturer compares case-insensitively only when asked',
  cng_multi_match('ekc', 'EKC', true) AND NOT cng_multi_match('ekc', '!EKC', true) AND NOT cng_multi_match('ekc', 'EKC'));
SELECT pg_temp.ck('MCF-5 the predicate is IMMUTABLE SQL with no SET clause (inlinable), and not SECURITY DEFINER',
  (SELECT provolatile = 'i' AND proconfig IS NULL AND NOT prosecdef FROM pg_proc
    WHERE proname = 'cng_multi_match' AND pronamespace = 'public'::regnamespace));
SELECT pg_temp.ck('MCF-6 anon may not execute either function; authenticated may',
  NOT has_function_privilege('anon', 'public.cng_multi_match(text, text, boolean)', 'EXECUTE')
  AND NOT has_function_privilege('anon', 'public.cng_installed_srv_summary_filtered(jsonb)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.cng_multi_match(text, text, boolean)', 'EXECUTE')
  AND has_function_privilege('authenticated', 'public.cng_installed_srv_summary_filtered(jsonb)', 'EXECUTE'));
SELECT pg_temp.ck('MCF-7 the summary stays SECURITY INVOKER, so RLS still bounds every count',
  (SELECT NOT prosecdef FROM pg_proc WHERE proname = 'cng_installed_srv_summary_filtered'));

-- The strip must count what the table shows: same view, same predicate, for single, multi, excluded and legacy values.
SELECT pg_temp.ck('MCF-8 summary counts equal the table''s rows for single, multi, excluded and legacy due choices',
  (SELECT bool_and(s.total = (SELECT count(*) FROM v_installed_srv_management m WHERE cng_multi_match(m.due_status::text, v.expanded)))
     FROM (VALUES ('overdue', 'overdue'), ('overdue|due_7', 'overdue|due_7'), ('!valid|unknown', '!valid|unknown'),
                  ('attention', 'overdue|due_today|due_7|due_15|due_30')) v(choice, expanded),
          LATERAL cng_installed_srv_summary_filtered(jsonb_build_object('due', v.choice)) s));
SELECT pg_temp.ck('MCF-9 an excluded manufacturer leaves exactly the rows that are not that manufacturer',
  (SELECT total FROM cng_installed_srv_summary_filtered('{"manufacturer": "!EKC"}'))
  = (SELECT count(*) FROM v_installed_srv_management WHERE manufacturer IS NULL OR lower(manufacturer) <> 'ekc'));
ROLLBACK;
