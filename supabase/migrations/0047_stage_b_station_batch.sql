-- 0047_stage_b_station_batch.sql
-- Stage B, step one: the batch STATION mapping mechanism (Prompt 22A).
--
-- WHAT THIS IS. Stage A committed 157 Stations and 188 Units. 281 staged asset
-- rows across four families now resolve, by exact Region-aware normalized name,
-- to exactly one canonical Station each. This records that confirmation for a
-- reviewed batch, all-or-nothing, bound to the exact preview an owner read.
--
-- WHAT IT IS NOT. It confirms a STATION and nothing else. It writes no Unit, no
-- compressor, dispenser, vessel, tank, detector or hose parent, creates no
-- alias, imports no canonical asset, and touches no staging row outside the
-- approved candidate set.
--
-- APPLYING THIS MIGRATION DECIDES NOTHING. It installs three functions.
--
-- ===================== IT REUSES THE EXISTING ARCHITECTURE ===================
-- No parallel mapping system was invented. `import_mapping_decisions` (0039) and
-- its content binding (0041) already hold exactly this: one human decision per
-- SOURCE ROW, keyed by `source_row_key`, bound to the `source_row_hash` the
-- decider actually read, superseding rather than overwriting, with
-- `imd_one_active_per_source_row` making "exactly one active decision" a
-- DATABASE property. The batch writes the same rows the single-row path writes,
-- in the same shape, with the same server-side hash capture.
--
-- The resulting status is likewise NOT a new rule. `cng_admin_decide_staged_mapping`
-- already derives it, and this uses the identical expression:
--
--     confirmed Station, no Unit  ->  needs_unit_mapping
--
-- which is the lifecycle CLAUDE.md §4 states. All four families behave the same
-- way, because all four carry the same `station_id NOT NULL` / `unit_id NULL`
-- shape. Station confirmation is NOT Unit confirmation and NOT equipment
-- resolution, and no convenience rule was added to make a batch tidier.
--
-- ========================= WHY THIS IS ADMIN, NOT service_role ===============
-- Prompt 22A asked for a `service_role`-only function. THE SCHEMA FORBIDS IT,
-- and the reason matters: `import_mapping_decisions.decided_by` is
-- `NOT NULL REFERENCES app_users(id)`, because CLAUDE.md §9 requires every
-- mapping change to record who made it, and §10 forbids a forgeable actor
-- column. `service_role` carries no Clerk subject, so a `service_role` batch
-- could only satisfy that column by accepting an actor parameter — which Prompt
-- 22A itself forbids — or by making the column nullable, which would create
-- unattributed human rulings.
--
-- So the actor is derived server-side from the verified Clerk subject via
-- `cng_require_admin()`, exactly as the single-row path has done since 0039, and
-- EXECUTE is granted to `authenticated` ONLY — where the admin check, not the
-- grant, is the gate. This satisfies the requirement that actually protects the
-- data (no caller-supplied identity, no unattributed decision) at the cost of
-- the one that cannot be met without weakening it.
--
-- Stage A differs precisely because a Station carries no `created_by`: creating
-- the hierarchy is an operator action with no human ruling to attribute, so it
-- could be, and is, `service_role` only.
--
-- ============================ THE CANONICAL SCOPE ============================
-- The commit writes TWO tables, named as literals: `import_mapping_decisions`
-- and `audit_logs`. There is NO dynamic SQL. It cannot reach a canonical asset
-- table, `stations`, `units`, `station_aliases` or `unit_aliases` — and it
-- cannot record an equipment parent even in principle, because the decision
-- table has no equipment column at all. Assertions re-derive this from
-- `pg_proc.prosrc`.

-- ---------------------------------------------------------------------------
-- 1. THE CANDIDATE SET — derived server-side, never supplied
-- ---------------------------------------------------------------------------
-- A candidate is a staged row of one of the four pre-import families, still
-- `needs_station_mapping`, whose normalized source Station name matches EXACTLY
-- ONE canonical Station IN ITS OWN REGION.
--
-- Everything else is excluded by construction, not by a filter a caller could
-- omit: zero matches, more than one match, and a match that exists only in a
-- DIFFERENT Region. Region is identity (CLAUDE.md §8), so a cross-Region name
-- match is not a match, and 5 such rows stay unmapped.
--
-- There is no similarity, no suffix stripping, no edit distance and no alias
-- lookup. `cng_normalize_name` is the only comparison, and it is the same
-- deployed function Stage A used.

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
  WITH staged AS (
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
           (SELECT count(*) FROM stations st JOIN regions g ON g.id = st.region_id
             WHERE g.name = s.region_name AND st.normalized_name = s.an) AS n_same_region
      FROM staged s
  )
  SELECT m.id, m.target_table, g.id, g.name, st.id, st.station_name, st.normalized_name,
         m.source_raw_name, m.source_row_key, m.source_row_hash, m.mapping_status,
         EXISTS (SELECT 1 FROM import_mapping_decisions d
                  WHERE d.source_row_key = m.source_row_key AND d.superseded_at IS NULL)
    FROM matched m
    JOIN regions  g  ON g.name = m.region_name
    JOIN stations st ON st.region_id = g.id AND st.normalized_name = m.an
   WHERE m.n_same_region = 1
   ORDER BY m.id;
$$;

COMMENT ON FUNCTION cng_stage_b_station_candidates(uuid) IS
  'Stage B (Prompt 22A): the Station-mapping candidate rows for one staging run, '
  'derived server-side. A candidate matches EXACTLY ONE canonical Station in its '
  'OWN Region by normalized name. Ambiguous, unmatched and other-Region-only rows '
  'are excluded by construction. Pure SELECT — decides nothing, writes nothing.';

-- ---------------------------------------------------------------------------
-- 2. THE OWNER-REVIEW GROUPING AND ITS FINGERPRINT
-- ---------------------------------------------------------------------------
-- Review is grouped by the Region-aware normalized identity, so an owner reads
-- 69 groups rather than 281 rows — but the COMMIT is still bound to every
-- individual staging row, because a group is a convenience for a human and never
-- the unit of record.
--
-- A group carries every raw source spelling that folded into it, so an owner can
-- see exactly which written forms they are accepting as one Station.

CREATE OR REPLACE FUNCTION cng_stage_b_station_groups(p_import_run_id uuid)
RETURNS TABLE (
  region_name      text,
  region_id        uuid,
  station_id       uuid,
  station_name     text,
  station_norm     text,
  source_spellings text[],
  row_count        integer,
  storage_vessels  integer,
  recovery_tanks   integer,
  gas_detectors    integer,
  hoses            integer,
  staging_row_ids  uuid[],
  source_row_hashes text[],
  mapping_statuses text[],
  rows_with_existing_decision integer,
  review_class     text,
  warning          text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT
    c.region_name, c.region_id, c.station_id, c.station_name, c.station_norm,
    array_agg(DISTINCT c.source_raw_name ORDER BY c.source_raw_name),
    count(*)::integer,
    count(*) FILTER (WHERE c.target_table = 'storage_vessels')::integer,
    count(*) FILTER (WHERE c.target_table = 'recovery_tanks')::integer,
    count(*) FILTER (WHERE c.target_table = 'gas_detectors')::integer,
    count(*) FILTER (WHERE c.target_table = 'hoses')::integer,
    array_agg(c.staging_row_id ORDER BY c.staging_row_id),
    array_agg(c.source_row_hash ORDER BY c.staging_row_id),
    array_agg(DISTINCT c.mapping_status),
    count(*) FILTER (WHERE c.has_active_decision)::integer,
    -- A candidate is DETERMINISTIC only when every row in it is still awaiting a
    -- decision and still in the expected lifecycle state. Anything else is
    -- separated out for a human rather than folded into the batch.
    CASE
      WHEN count(*) FILTER (WHERE c.has_active_decision) > 0 THEN 'OWNER REVIEW'
      WHEN count(DISTINCT c.mapping_status) > 1 THEN 'OWNER REVIEW'
      ELSE 'DETERMINISTIC STATION CANDIDATE'
    END,
    CASE
      WHEN count(*) FILTER (WHERE c.has_active_decision) > 0
        THEN 'Some rows already carry an active mapping decision; this group is excluded from the batch.'
      WHEN count(DISTINCT c.mapping_status) > 1
        THEN 'Rows in this group are in different lifecycle states; excluded from the batch.'
      ELSE ''
    END
  FROM cng_stage_b_station_candidates(p_import_run_id) c
  GROUP BY c.region_name, c.region_id, c.station_id, c.station_name, c.station_norm
  ORDER BY c.region_name, c.station_norm;
$$;

COMMENT ON FUNCTION cng_stage_b_station_groups(uuid) IS
  'Stage B (Prompt 22A): the candidate rows grouped into Region-aware Station '
  'identities for owner review, carrying every raw source spelling, the exact '
  'staging row ids and their source_row_hash evidence. Read-only. Grouping is a '
  'review convenience; the commit stays bound to every individual row.';

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
  WITH c AS (SELECT * FROM cng_stage_b_station_candidates(p_import_run_id)),
  -- THE FINGERPRINT BINDS EVERY ITEM PROMPT 22A PHASE 4 REQUIRES, per row:
  --   staging row id      -> a candidate disappearing or appearing changes it
  --   station id + name   -> a Station changed, renamed or deleted changes it
  --   region id           -> a Region changing changes it
  --   normalized identity -> a normalization change changes it
  --   source_row_hash     -> the source row changing changes it
  --   mapping_status      -> a lifecycle move changes it
  --   has_active_decision -> a decision appearing after preview changes it
  -- Ambiguity is covered by membership: a row that gains a second candidate
  -- Station leaves the set entirely, which changes the fingerprint.
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
    (SELECT count(*)::integer FROM cng_stage_b_station_groups(p_import_run_id)),
    (SELECT count(*)::integer FROM c),
    (SELECT count(*)::integer FROM cng_stage_b_station_groups(p_import_run_id) WHERE review_class = 'DETERMINISTIC STATION CANDIDATE'),
    (SELECT count(*)::integer FROM cng_stage_b_station_groups(p_import_run_id) WHERE review_class = 'OWNER REVIEW'),
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
  'Stage B (Prompt 22A): the content fingerprint and counts an owner approval is '
  'bound to. Read-only. The fingerprint covers, per candidate row, its staging '
  'row id, Region, Station, normalized identity, source_row_hash, lifecycle '
  'status and whether a decision already exists — so the approval lapses if any '
  'of them moves.';

-- ---------------------------------------------------------------------------
-- 3. THE BATCH COMMIT — one transaction, all or nothing
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION cng_stage_b_station_commit(
  p_import_run_id                 uuid,
  p_expected_manifest_fingerprint text,
  p_expected_preview_fingerprint  text,
  p_reason                        text DEFAULT NULL
)
RETURNS TABLE (
  import_run_id       uuid,
  decisions_written   integer,
  rows_confirmed      integer,
  groups_confirmed    integer,
  preview_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor    uuid := cng_require_admin();
  v_manifest text;
  v_preview  text;
  v_completed timestamptz;
  v_blocked  integer;
  v_written  integer := 0;
  v_groups   integer := 0;
BEGIN
  -- --- GATE 1: an approval must actually be presented ----------------------
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint), '') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint), '')  = '' THEN
    RAISE EXCEPTION 'Stage B commit requires an explicit import run and both approval fingerprints'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 2: the run must exist and be completed --------------------------
  SELECT run.completed_at, run.summary ->> 'manifest_fingerprint'
    INTO v_completed, v_manifest
    FROM import_runs run WHERE run.id = p_import_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stage B commit: import run % does not exist', p_import_run_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF v_completed IS NULL THEN
    RAISE EXCEPTION 'Stage B commit: import run % is not completed', p_import_run_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 3: the approved SOURCE CONTENT ---------------------------------
  IF v_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Stage B commit refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 4: the approved CANDIDATE SET ----------------------------------
  -- One comparison covers every drift Prompt 22A lists, because all of them are
  -- folded into the fingerprint: a changed source row, a changed, renamed or
  -- deleted Station, a changed Region, a changed normalization, a moved
  -- lifecycle status, a decision that appeared after the preview, a candidate
  -- that became ambiguous, and a candidate that disappeared.
  SELECT pv.preview_fingerprint INTO v_preview
    FROM cng_stage_b_station_preview(p_import_run_id) pv;

  IF v_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Stage B commit refused: the candidate set no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_preview
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 5: nothing in the batch may already be decided ------------------
  -- Also enforced by `imd_one_active_per_source_row`, so a race that slipped
  -- past the fingerprint still cannot produce a duplicate. This says WHY.
  SELECT count(*)::integer INTO v_blocked
    FROM cng_stage_b_station_candidates(p_import_run_id) c
   WHERE c.has_active_decision;

  IF v_blocked > 0 THEN
    RAISE EXCEPTION 'Stage B commit refused: % candidate rows already carry an active mapping decision', v_blocked
      USING ERRCODE = 'unique_violation';
  END IF;

  -- ======================= THE DECISIONS ===================================
  -- STATION ONLY. `confirmed_unit_id` is written as NULL, so the derived status
  -- is `needs_unit_mapping` — the same expression the single-row path uses. The
  -- decision table has no equipment column, so no equipment parent can be
  -- recorded here even by mistake.
  WITH cand AS (
    SELECT * FROM cng_stage_b_station_candidates(p_import_run_id)
  ), ins AS (
    INSERT INTO import_mapping_decisions (
      staging_row_id, source_row_key, reviewed_source_row_hash,
      target_table, asset_type,
      region_id, confirmed_station_id, confirmed_unit_id,
      previous_mapping_status, resulting_mapping_status,
      decided_by, reason, source_evidence)
    SELECT
      c.staging_row_id, c.source_row_key,
      -- SERVER-SIDE, from the staged row itself. No parameter names it.
      r.source_row_hash,
      c.target_table,
      CASE c.target_table
        WHEN 'storage_vessels' THEN 'storage_vessel'::asset_type
        WHEN 'recovery_tanks'  THEN 'recovery_tank'
        WHEN 'gas_detectors'   THEN 'gas_detector'
        WHEN 'hoses'           THEN 'hose'
      END,
      c.region_id, c.station_id, NULL,
      c.mapping_status, 'needs_unit_mapping',
      v_actor, p_reason,
      jsonb_build_object(
        'source_file', r.source_file, 'source_sheet', r.source_sheet,
        'source_row', r.source_row, 'source_raw', r.source_raw,
        'source_row_hash', r.source_row_hash,
        'normalized', r.normalized, 'resolution', r.resolution,
        'staged_mapping_status', r.mapping_status,
        'batch', jsonb_build_object(
          'stage', 'B-station',
          'import_run_id', p_import_run_id,
          'preview_fingerprint', v_preview))
      FROM cand c
      JOIN import_staging_rows r ON r.id = c.staging_row_id
    RETURNING id, staging_row_id, target_table, source_row_key,
              region_id, confirmed_station_id, reviewed_source_row_hash,
              previous_mapping_status, resulting_mapping_status
  ), aud AS (
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                            summary, before_data, after_data)
    SELECT 'mapping_changed', 'import_mapping_decisions', i.id, v_actor,
           (SELECT full_name FROM app_users WHERE id = v_actor),
           format('%s %s: %s -> %s (Stage B Station batch)', i.target_table,
                  i.source_row_key, i.previous_mapping_status, i.resulting_mapping_status),
           NULL,
           jsonb_build_object(
             'staging_row_id', i.staging_row_id, 'source_row_key', i.source_row_key,
             'reviewed_source_row_hash', i.reviewed_source_row_hash,
             'station_id', i.confirmed_station_id, 'unit_id', NULL,
             'mapping_status', i.resulting_mapping_status,
             'batch_preview_fingerprint', v_preview)
      FROM ins i
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_written FROM aud;

  SELECT count(*)::integer INTO v_groups
    FROM cng_stage_b_station_groups(p_import_run_id);

  RETURN QUERY SELECT p_import_run_id, v_written, v_written, v_groups, v_preview;
END $$;

COMMENT ON FUNCTION cng_stage_b_station_commit(uuid, text, text, text) IS
  'Stage B (Prompt 22A): records a reviewed batch of STATION-ONLY mapping '
  'decisions in ONE transaction. Fails closed on both fingerprints and on any '
  'already-decided row. Writes import_mapping_decisions and audit_logs ONLY, '
  'with confirmed_unit_id NULL so the derived status is needs_unit_mapping. The '
  'actor is derived from the verified Clerk subject and is never a parameter; no '
  'dynamic SQL; no alias, Unit, equipment or canonical asset is ever written.';

REVOKE ALL ON FUNCTION cng_stage_b_station_candidates(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_b_station_candidates(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION cng_stage_b_station_candidates(uuid) TO authenticated;

REVOKE ALL ON FUNCTION cng_stage_b_station_groups(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_b_station_groups(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION cng_stage_b_station_groups(uuid) TO authenticated;

REVOKE ALL ON FUNCTION cng_stage_b_station_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_b_station_preview(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION cng_stage_b_station_preview(uuid) TO authenticated;

REVOKE ALL ON FUNCTION cng_stage_b_station_commit(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_b_station_commit(uuid, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION cng_stage_b_station_commit(uuid, text, text, text) TO authenticated;
