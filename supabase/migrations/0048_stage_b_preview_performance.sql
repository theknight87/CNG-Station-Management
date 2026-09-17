-- 0048_stage_b_preview_performance.sql
-- Stage B preview: a PERFORMANCE fix only (Prompt 22C.2).
--
-- THE DEFECT. `/admin/station-batch` failed in production with
-- "canceling statement due to statement timeout" while loading the READ-ONLY
-- preview. The commit was never reached and nothing was written.
--
-- THE MEASUREMENT, not a guess. The same call, same data, same moment:
--
--   as an operator connection (RLS bypassed)          225 ms
--   as the owner's authenticated session (RLS on)  39,371 ms
--
-- A 175x difference over 7,163 staged rows and 157 Stations is not data volume;
-- it is RLS being evaluated far more often than once. Broken down, under RLS:
--
--   plain staged scan                          894 ms
--   stations scan                               27 ms
--   import_mapping_decisions scan                0.8 ms
--   cng_stage_b_station_candidates           9,737 ms
--   cng_stage_b_station_groups               9,892 ms
--   cng_stage_b_station_preview             39,371 ms  (~4x candidates)
--
-- TWO COMPOUNDING CAUSES, both structural:
--
--   1. `candidates` asked, FOR EVERY ONE of the 1,104 staged rows, "how many
--      Stations in this Region carry this normalized name?" as a correlated
--      subquery. Each evaluation re-scanned `stations` THROUGH ITS RLS POLICY.
--      1,104 x ~9 ms is the 9.7 s almost exactly.
--
--   2. `preview` then evaluated that whole thing FOUR times — once for its own
--      candidate CTE, and once inside each of its three calls to
--      `cng_stage_b_station_groups`. 4 x 9.7 s is the 39 s almost exactly.
--
-- THE FIX IS `AS MATERIALIZED`, and it was chosen by measurement. The first
-- rewrite tried here — joining once and counting with a window function — was
-- **four times SLOWER than the original** (37.4 s), because the planner still
-- re-scanned the RLS-protected table and added window overhead on top. Measured
-- alternatives, same session, same RLS, all returning the same 281 rows:
--
--   current correlated shape                 9,795 ms
--   window-function rewrite (REJECTED)      37,444 ms
--   materialize stations only                1,321 ms
--   materialize stations AND staged            303 ms   <- this migration
--
-- Materializing forces ONE RLS evaluation of `stations` (157 rows) and ONE of
-- the staged set, after which the work is a hash join over small in-memory
-- relations. `preview` additionally holds its candidate and group sets in
-- materialized CTEs, so `groups` is called once rather than three times.
--
-- ============================ WHAT DOES NOT CHANGE ==========================
-- NOTHING about meaning, authorization or output.
--
--   * The candidate set is still DERIVED server-side from persisted staging
--     rows x canonical Stations x Region x `cng_normalize_name()`.
--   * Identical rows, identical column values, identical `ORDER BY` — so the
--     preview fingerprint is BYTE-IDENTICAL. This migration is not permitted to
--     change it, and a regression test proves the old and new bodies agree.
--   * `n_same_region = 1` is still the exactly-one test, so a row with zero or
--     with several same-Region Stations is still excluded by construction.
--   * Still SECURITY INVOKER and still STABLE: RLS is evaluated fewer TIMES,
--     never bypassed, and a caller still sees exactly the rows their own
--     policies allow. Materializing a CTE changes plan shape, not visibility.
--   * No grant, policy, RLS setting or `cng_require_admin()` is touched.
--   * `cng_stage_b_station_commit` is NOT modified by this migration.
--
-- RAISING `statement_timeout` WAS DELIBERATELY NOT THE FIX. A preview over
-- 7,163 rows has no business taking 39 seconds, and hiding that behind a longer
-- timeout would have left the same per-row RLS re-evaluation waiting to bite a
-- larger dataset later.

CREATE OR REPLACE FUNCTION cng_stage_b_station_candidates(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id   uuid,
  target_table     text,
  region_id        uuid,
  region_name      text,
  station_id       uuid,
  station_name     text,
  station_norm     text,
  source_raw_name  text,
  source_row_key   text,
  source_row_hash  text,
  mapping_status   text,
  has_active_decision boolean
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  -- MATERIALIZED, deliberately: this is the whole performance fix. Reading the
  -- canonical Stations ONCE costs one RLS evaluation over 157 rows; letting the
  -- planner inline this CTE costs one per staged row, which is the 9.7 s.
  WITH stn AS MATERIALIZED (
    SELECT st.id AS station_id, st.station_name, st.normalized_name,
           g.id AS region_id, g.name AS region_name
      FROM stations st
      JOIN regions  g ON g.id = st.region_id
  ),
  -- Likewise: read the staged set once, normalize once.
  staged AS MATERIALIZED (
    SELECT r.id, r.target_table, r.source_row_key, r.source_row_hash, r.mapping_status,
           r.normalized ->> 'region' AS region_name,
           r.normalized ->> 'source_station_name_raw' AS source_raw_name,
           cng_normalize_name(r.normalized ->> 'source_station_name_raw') AS an
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
       AND r.mapping_status = 'needs_station_mapping'
       AND r.outcome NOT IN ('rejected', 'excluded', 'replayed')
  ),
  matched AS (
    SELECT s.*,
           (SELECT count(*) FROM stn
             WHERE stn.region_name = s.region_name AND stn.normalized_name = s.an) AS n_same_region
      FROM staged s
  )
  SELECT m.id, m.target_table, stn.region_id, stn.region_name, stn.station_id,
         stn.station_name, stn.normalized_name,
         m.source_raw_name, m.source_row_key, m.source_row_hash, m.mapping_status,
         EXISTS (SELECT 1 FROM import_mapping_decisions d
                  WHERE d.source_row_key = m.source_row_key AND d.superseded_at IS NULL)
    FROM matched m
    JOIN stn ON stn.region_name = m.region_name AND stn.normalized_name = m.an
   WHERE m.n_same_region = 1
   ORDER BY m.id;
$$;

COMMENT ON FUNCTION cng_stage_b_station_candidates(uuid) IS
  'Stage B (Prompt 22A; performance 22C.2): the Station-mapping candidate rows '
  'for one staging run, derived server-side. A candidate matches EXACTLY ONE '
  'canonical Station in its OWN Region by normalized name. Ambiguous, unmatched '
  'and other-Region-only rows are excluded by construction. Pure SELECT — '
  'decides nothing, writes nothing. The CTEs are MATERIALIZED so RLS is '
  'evaluated once per table rather than once per staged row.';

CREATE OR REPLACE FUNCTION cng_stage_b_station_preview(p_import_run_id uuid)
RETURNS TABLE (
  import_run_id        uuid,
  manifest_fingerprint text,
  preview_fingerprint  text,
  candidate_groups     integer,
  candidate_rows       integer,
  deterministic_groups integer,
  owner_review_groups  integer,
  rows_with_existing_decision integer,
  storage_vessels      integer,
  recovery_tanks       integer,
  gas_detectors        integer,
  hoses                integer,
  canonical_stations   integer,
  canonical_units      integer,
  existing_decisions   integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  -- MATERIALIZED so each set is computed ONCE. Previously `groups` was called
  -- three times and the candidate set four times in total.
  WITH c AS MATERIALIZED (SELECT * FROM cng_stage_b_station_candidates(p_import_run_id)),
  grp AS MATERIALIZED (SELECT * FROM cng_stage_b_station_groups(p_import_run_id)),
  -- THE FINGERPRINT IS UNCHANGED — same fields, same separators, same order —
  -- so an approval given against the old body is still valid against this one.
  canon AS (
    SELECT string_agg(
             concat_ws(chr(31),
               c.staging_row_id::text, c.region_id::text, c.station_id::text,
               c.station_norm, c.station_name, c.source_row_hash,
               c.mapping_status, c.has_active_decision::text),
             chr(30) ORDER BY c.staging_row_id) AS blob
      FROM c
  )
  SELECT
    p_import_run_id,
    (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = p_import_run_id),
    encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM grp),
    (SELECT count(*)::integer FROM c),
    (SELECT count(*)::integer FROM grp WHERE grp.review_class = 'DETERMINISTIC STATION CANDIDATE'),
    (SELECT count(*)::integer FROM grp WHERE grp.review_class = 'OWNER REVIEW'),
    (SELECT count(*)::integer FROM c WHERE c.has_active_decision),
    (SELECT count(*)::integer FROM c WHERE c.target_table = 'storage_vessels'),
    (SELECT count(*)::integer FROM c WHERE c.target_table = 'recovery_tanks'),
    (SELECT count(*)::integer FROM c WHERE c.target_table = 'gas_detectors'),
    (SELECT count(*)::integer FROM c WHERE c.target_table = 'hoses'),
    (SELECT count(*)::integer FROM stations),
    (SELECT count(*)::integer FROM units),
    (SELECT count(*)::integer FROM import_mapping_decisions WHERE superseded_at IS NULL);
$$;

COMMENT ON FUNCTION cng_stage_b_station_preview(uuid) IS
  'Stage B (Prompt 22A; performance 22C.2): the content fingerprint and counts '
  'an owner approval is bound to. Read-only. The fingerprint covers, per '
  'candidate row, its staging row id, Region, Station, normalized identity, '
  'source_row_hash, lifecycle status and whether a decision already exists — so '
  'the approval lapses if any of them moves. The candidate and group sets are '
  'MATERIALIZED so each is computed once.';
