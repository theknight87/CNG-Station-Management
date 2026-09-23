-- 20260923150000_stage_b2_station_batch.sql
-- Stage B2: Station-only confirmation for four-family staged rows whose
-- PIPELINE-ERA status claims more than the evidence proves (Phase 6, 2026-09-23).
--
-- ADDS FOUR FUNCTIONS AND NOTHING ELSE: no table, column, constraint, policy,
-- grant on a table, or change to any existing function. The approved Stage B
-- family (0047/0048) is untouched and keeps its own fingerprint semantics.
--
-- ============================== THE SET ==================================
--
-- Stage B considered only rows staged `needs_station_mapping`, and exhausted
-- them (281 decided, 823 with no same-Region candidate). 308 further four-family
-- rows are staged `needs_unit_mapping` (40) or `resolved` (268). Every one of
-- them names a Station that matches EXACTLY ONE canonical Station in its own
-- Region by the approved normalized-name rule, yet none can reach a canonical
-- table: their staged `station_id` / `unit_id` are 32-hex SYNTHETIC dry-run keys
-- that exist in neither `stations` nor `units` (the Prompt 25C finding, here for
-- the four families).
--
-- THE `resolved` STATUS IS THE FORBIDDEN ONE-UNIT INFERENCE. Measured in
-- production: all 268 sit under a Station with exactly ONE Unit, the source has
-- no Unit column, and the resolution record states no Unit reason. CLAUDE.md §4
-- permanently forbids assigning a Unit because a Station has one. So these rows
-- are confirmed at STATION level only - exactly the 25C owner ruling for
-- installed SRVs - and the staged status is preserved as evidence, never honoured.
--
-- 28 of the 308 are gas-detector rows with `creates_detector_record = false`:
-- recorded ABSENCE. They receive a Station decision like any other row (as the
-- two did in the 281 batch) and the existing asset import classifies them
-- E_BLOCKED_BY_TARGET, so no detector is ever manufactured from absence.
--
-- ============================== THE RULES ================================
--
-- Identical to Stage B and not re-derived: exactly one same-Region canonical
-- Station by `cng_normalize_name`; the decision binds the `source_row_hash` read
-- server-side; `confirmed_unit_id` NULL so the derived status is
-- `needs_unit_mapping`; admin only, actor from `cng_require_admin()`, never a
-- parameter; content-bound to manifest + preview fingerprints re-derived in the
-- commit's own transaction; refuses if any candidate already has an active
-- decision (`imd_one_active_per_source_row` is the database backstop). No
-- dynamic SQL; two literal INSERT targets (`import_mapping_decisions`,
-- `audit_logs`). Nothing canonical is written here - the canonical import is the
-- separate, service_role-only `cng_asset_import_commit` (0049), which already
-- reads active Station-only decisions and needs no change.

CREATE OR REPLACE FUNCTION cng_stage_b2_station_candidates(p_import_run_id uuid)
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
  -- MATERIALIZED for the same reason as 0048: RLS evaluated once per table.
  WITH stn AS MATERIALIZED (
    SELECT st.id AS station_id, st.station_name, st.normalized_name,
           g.id AS region_id, g.name AS region_name
      FROM stations st
      JOIN regions  g ON g.id = st.region_id
  ),
  staged AS MATERIALIZED (
    SELECT r.id, r.target_table, r.source_row_key, r.source_row_hash, r.mapping_status,
           r.normalized ->> 'region' AS region_name,
           r.normalized ->> 'source_station_name_raw' AS source_raw_name,
           cng_normalize_name(r.normalized ->> 'source_station_name_raw') AS an
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
       -- THE ONLY DIFFERENCE FROM STAGE B: pipeline-era statuses beyond Station.
       AND r.mapping_status IN ('needs_unit_mapping', 'resolved')
       AND r.outcome NOT IN ('rejected', 'excluded', 'replayed')
       AND r.committed_entity_id IS NULL
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

COMMENT ON FUNCTION cng_stage_b2_station_candidates(uuid) IS
  'Stage B2: four-family staged rows with a pipeline-era status of needs_unit_mapping or resolved '
  'whose raw Station name matches EXACTLY ONE canonical Station in its own Region. Pure SELECT. '
  'The staged Unit is NOT carried: it is a synthetic key from the forbidden one-Unit inference.';

CREATE OR REPLACE FUNCTION cng_stage_b2_station_groups(p_import_run_id uuid)
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
    -- Mixed staged statuses are EXPECTED here (both collapse to Station-only),
    -- so only an existing decision marks a group for review.
    CASE WHEN count(*) FILTER (WHERE c.has_active_decision) > 0
         THEN 'OWNER REVIEW' ELSE 'DETERMINISTIC STATION CANDIDATE' END,
    CASE WHEN count(*) FILTER (WHERE c.has_active_decision) > 0
         THEN 'Some rows already carry an active mapping decision; the batch commit refuses.'
         ELSE '' END
  FROM cng_stage_b2_station_candidates(p_import_run_id) c
  GROUP BY c.region_name, c.region_id, c.station_id, c.station_name, c.station_norm
  ORDER BY c.region_name, c.station_norm;
$$;

COMMENT ON FUNCTION cng_stage_b2_station_groups(uuid) IS
  'Stage B2: candidates grouped by Region-aware Station identity for owner review. Read-only.';

CREATE OR REPLACE FUNCTION cng_stage_b2_station_preview(p_import_run_id uuid)
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
  staged_resolved      integer,
  staged_needs_unit    integer,
  detector_absence_rows integer,
  canonical_stations   integer,
  canonical_units      integer,
  existing_decisions   integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH c AS MATERIALIZED (SELECT * FROM cng_stage_b2_station_candidates(p_import_run_id)),
  grp AS MATERIALIZED (SELECT * FROM cng_stage_b2_station_groups(p_import_run_id)),
  -- Same per-row fields and separators as Stage B, prefixed with a batch tag so
  -- a B2 fingerprint can never equal a Stage B one over the same rows.
  canon AS (
    SELECT string_agg(
             concat_ws(chr(31), 'B2',
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
    (SELECT count(*)::integer FROM c WHERE c.mapping_status = 'resolved'),
    (SELECT count(*)::integer FROM c WHERE c.mapping_status = 'needs_unit_mapping'),
    (SELECT count(*)::integer FROM c JOIN import_staging_rows r ON r.id = c.staging_row_id
      WHERE c.target_table = 'gas_detectors'
        AND coalesce(r.normalized ->> 'creates_detector_record', 'true') <> 'true'),
    (SELECT count(*)::integer FROM stations),
    (SELECT count(*)::integer FROM units),
    (SELECT count(*)::integer FROM import_mapping_decisions WHERE superseded_at IS NULL);
$$;

COMMENT ON FUNCTION cng_stage_b2_station_preview(uuid) IS
  'Stage B2: content fingerprint and counts an owner approval is bound to. Read-only.';

CREATE OR REPLACE FUNCTION cng_stage_b2_station_commit(
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
  v_actor    uuid := cng_require_admin();   -- server-derived; never a parameter
  v_manifest text;
  v_preview  text;
  v_rows     integer;
  v_completed timestamptz;
  v_blocked  integer;
  v_written  integer := 0;
  v_groups   integer := 0;
BEGIN
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint), '') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint), '')  = '' THEN
    RAISE EXCEPTION 'Stage B2 commit requires an explicit import run and both approval fingerprints'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT run.completed_at, run.summary ->> 'manifest_fingerprint'
    INTO v_completed, v_manifest
    FROM import_runs run WHERE run.id = p_import_run_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stage B2 commit: import run % does not exist', p_import_run_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF v_completed IS NULL THEN
    RAISE EXCEPTION 'Stage B2 commit: import run % is not completed', p_import_run_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Stage B2 commit refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- Captured ONCE, before any write (the 25K lesson).
  SELECT pv.preview_fingerprint, pv.candidate_rows, pv.candidate_groups
    INTO v_preview, v_rows, v_groups
    FROM cng_stage_b2_station_preview(p_import_run_id) pv;

  IF v_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Stage B2 commit refused: the candidate set no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_preview
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Stage B2 commit refused: no candidate rows'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  SELECT count(*)::integer INTO v_blocked
    FROM cng_stage_b2_station_candidates(p_import_run_id) c
   WHERE c.has_active_decision;
  IF v_blocked > 0 THEN
    RAISE EXCEPTION 'Stage B2 commit refused: % candidate rows already carry an active mapping decision', v_blocked
      USING ERRCODE = 'unique_violation';
  END IF;

  WITH cand AS (
    SELECT * FROM cng_stage_b2_station_candidates(p_import_run_id)
  ), ins AS (
    INSERT INTO import_mapping_decisions (
      staging_row_id, source_row_key, reviewed_source_row_hash,
      target_table, asset_type,
      region_id, confirmed_station_id, confirmed_unit_id,
      previous_mapping_status, resulting_mapping_status,
      decided_by, reason, source_evidence)
    SELECT
      c.staging_row_id, c.source_row_key,
      r.source_row_hash,
      c.target_table,
      CASE c.target_table
        WHEN 'storage_vessels' THEN 'storage_vessel'::asset_type
        WHEN 'recovery_tanks'  THEN 'recovery_tank'
        WHEN 'gas_detectors'   THEN 'gas_detector'
        WHEN 'hoses'           THEN 'hose'
      END,
      c.region_id, c.station_id, NULL,          -- Unit is NEVER written
      c.mapping_status, 'needs_unit_mapping',
      v_actor, p_reason,
      jsonb_build_object(
        'source_file', r.source_file, 'source_sheet', r.source_sheet,
        'source_row', r.source_row, 'source_raw', r.source_raw,
        'source_row_hash', r.source_row_hash,
        'normalized', r.normalized, 'resolution', r.resolution,
        'staged_mapping_status', r.mapping_status,
        -- Kept as evidence and explicitly NOT honoured (CLAUDE.md §4).
        'staged_unit_discarded', CASE WHEN r.normalized ? 'unit_id'
          THEN 'pipeline-era synthetic unit_id from the one-Unit inference; not evidence of Unit membership'
          ELSE NULL END,
        'batch', jsonb_build_object(
          'stage', 'B2-station',
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
           format('%s %s: staged %s -> %s (Stage B2 Station batch; staged Unit discarded)',
                  i.target_table, i.source_row_key, i.previous_mapping_status, i.resulting_mapping_status),
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

  IF v_written IS DISTINCT FROM v_rows THEN
    RAISE EXCEPTION 'Stage B2 commit refused: % candidates but % decisions written', v_rows, v_written
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN QUERY SELECT p_import_run_id, v_written, v_written, v_groups, v_preview;
END $$;

COMMENT ON FUNCTION cng_stage_b2_station_commit(uuid, text, text, text) IS
  'Stage B2: records a reviewed batch of STATION-ONLY decisions for pipeline-status rows in ONE '
  'transaction, content-bound to both fingerprints, refusing any already-decided row. Writes '
  'import_mapping_decisions and audit_logs only; confirmed_unit_id NULL; the staged synthetic Unit '
  'is recorded as discarded evidence. Admin only, actor server-derived, no dynamic SQL.';

REVOKE ALL ON FUNCTION cng_stage_b2_station_candidates(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_stage_b2_station_candidates(uuid) TO authenticated;
REVOKE ALL ON FUNCTION cng_stage_b2_station_groups(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_stage_b2_station_groups(uuid) TO authenticated;
REVOKE ALL ON FUNCTION cng_stage_b2_station_preview(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_stage_b2_station_preview(uuid) TO authenticated;
REVOKE ALL ON FUNCTION cng_stage_b2_station_commit(uuid, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_stage_b2_station_commit(uuid, text, text, text) TO authenticated;
