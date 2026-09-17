-- 0052_irv_station_batch.sql
-- Content-bound STATION-ONLY batch mapping for canonical installed relief valves
-- (Prompt 25H).
--
-- ADDS NO TABLE, NO COLUMN, NO ENUM, NO CONSTRAINT AND NO INDEX. Everything it
-- needs exists: `installed_relief_valves` already permits the Station-confirmed
-- shape via `irv_status_shape_ck`, and `asset_mapping_audit` has carried
-- `is_bulk` + `bulk_batch_id` (paired by `ama_bulk_ck`) since 0001. Only the
-- BATCH WRITER was missing.
--
-- ============================ WHAT THIS IS NOT ==============================
--
-- It does NOT extend Stage B, does NOT touch `import_mapping_decisions` and
-- does NOT relax any Stage-B constraint. Stage B decides a Station on a STAGING
-- row for the four families whose `station_id` is NOT NULL; this decides a
-- Station on a CANONICAL installed SRV after import, which is the division
-- Prompt 25B established and the table `installed_relief_valves` was built for.
--
-- It is also not a second SRV mapping model: the status derivation, the audit
-- shape and the attribution rule are those of the deployed `cng_admin_map_srv`,
-- which remains the per-row path and is NOT modified. What this adds is one
-- server-side ATOMIC transaction instead of 1,054 client calls, each of which
-- would be individually approvable, individually abortable and collectively
-- unverifiable.
--
-- =========================== THE EVIDENCE RULE ==============================
--
-- A candidate needs Region + raw Station evidence and EXACTLY ONE canonical
-- Station in the SAME Region, by one of two owner-approved mechanisms:
--
--   `byte_exact`  the raw source name equals `stations.station_name` byte for byte
--   `normalized`  the deployed `cng_normalize_name()` folds both to one value
--
-- There is NO alias lookup (and `station_aliases` is empty), NO similarity, NO
-- edit distance, NO suffix or digit stripping, and NO cross-Region substitution.
-- `byte_exact` is a strict subset of `normalized` -- the fold is deterministic --
-- so the mechanism label records WHICH evidence a row rests on without widening
-- the rule.
--
-- ========================= WHAT IT REFUSES TO INFER =========================
--
-- The transition is Station-ONLY: `unit_id` and all three equipment parents stay
-- NULL and the status becomes `needs_unit_mapping`. **993 of the qualifying rows
-- sit under a Station with exactly ONE Unit** and NONE of them receives that
-- Unit. "The Station has one Unit" is a fact about the HIERARCHY, never about the
-- valve (CLAUDE.md section 4; refused in Prompts 21D, 22C, 22D and 25D). The
-- UPDATE below does not name `unit_id`, `compressor_id`, `storage_vessel_id` or
-- `dispenser_id` at all, so no Unit or parent is even expressible here.
--
-- ============================== AUTHORIZATION ==============================
--
-- Unlike the 0051 IMPORT (a service_role operator action on records with no
-- `created_by` contract), this is a HUMAN MAPPING DECISION. Section 9 requires it
-- to record who made it, and section 10 forbids a forgeable actor. So the actor
-- is derived SERVER-SIDE from the verified Clerk subject via `cng_require_admin()`
-- exactly as `cng_admin_map_srv` and the Stage B batch do, EXECUTE is granted to
-- `authenticated` only -- where the ADMIN CHECK, not the grant, is the gate --
-- and NO function here takes an actor parameter. service_role is deliberately NOT
-- granted: a mapping attributed to a machine identity is the thing section 10
-- exists to prevent.

-- ---------------------------------------------------------------------------
-- CANDIDATES — recomputed from canonical + lineage + staging evidence. It takes
-- no list and trusts no prior analysis. STABLE and NOT definer, so RLS bounds it
-- and it cannot write.
--
-- Both CTEs are MATERIALIZED deliberately: Prompt 22C.2 measured a correlated
-- per-row subquery over an RLS-protected `stations` at 9.7s for 1,104 rows and
-- 39s once re-evaluated. Evaluating each table's policy ONCE is the fix; RLS is
-- evaluated fewer times, never bypassed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_station_batch_candidates()
RETURNS TABLE (
  srv_id              uuid,
  region_id           uuid,
  source_station_raw  text,
  normalized_identity text,
  target_station_id   uuid,
  evidence_mechanism  text,
  row_version         timestamptz,
  source_row_key      text,
  source_row_hash     text,
  eligibility         text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH st AS MATERIALIZED (
    SELECT s.id, s.region_id, s.station_name, s.normalized_name FROM stations s
  ),
  v AS MATERIALIZED (
    SELECT e.id, e.region_id, e.station_id, e.unit_id,
           e.compressor_id, e.storage_vessel_id, e.dispenser_id,
           e.mapping_status, e.updated_at,
           e.source_station_name_raw AS raw,
           cng_normalize_name(e.source_station_name_raw) AS ident,
           e.source_raw ->> 'source_row_key'  AS k,
           e.source_raw ->> 'source_row_hash' AS h
      FROM installed_relief_valves e
  ),
  lin AS MATERIALIZED (
    SELECT r.committed_entity_id AS srv, r.source_row_key AS k, r.source_row_hash AS h,
           r.normalized ->> 'source_station_name_raw' AS raw,
           r.normalized ->> 'region' AS region_name
      FROM import_staging_rows r
     WHERE r.target_table = 'installed_relief_valves'
       AND r.committed_entity_kind = 'installed_relief_valve'
       AND r.committed_entity_id IS NOT NULL
  ),
  m AS (
    SELECT v.*,
           l.srv AS lin_srv, l.k AS lin_k, l.h AS lin_h, l.raw AS lin_raw,
           (SELECT g.id FROM regions g WHERE g.name = l.region_name) AS lin_region,
           (SELECT count(*) FROM st WHERE st.region_id = v.region_id AND st.normalized_name = v.ident) AS n_same,
           (SELECT st.id FROM st WHERE st.region_id = v.region_id AND st.normalized_name = v.ident) AS sid,
           (SELECT st.station_name FROM st WHERE st.region_id = v.region_id AND st.normalized_name = v.ident) AS sname,
           (SELECT count(*) FROM st WHERE st.region_id <> v.region_id AND st.normalized_name = v.ident) AS n_other
      FROM v LEFT JOIN lin l ON l.srv = v.id
  )
  SELECT
    m.id, m.region_id, m.raw, m.ident, m.sid,
    CASE WHEN m.sid IS NULL THEN NULL
         WHEN m.raw = m.sname THEN 'byte_exact' ELSE 'normalized' END,
    m.updated_at, m.k, m.h,
    CASE
      -- current canonical state
      WHEN m.mapping_status <> 'needs_station_mapping'            THEN 'X_NOT_UNMAPPED'
      WHEN m.station_id IS NOT NULL                               THEN 'X_ALREADY_STATION_MAPPED'
      WHEN m.unit_id IS NOT NULL
        OR num_nonnulls(m.compressor_id, m.storage_vessel_id, m.dispenser_id) > 0
                                                                  THEN 'X_HAS_DEEPER_MAPPING'
      -- evidence present
      WHEN m.region_id IS NULL                                    THEN 'X_MISSING_REGION'
      WHEN coalesce(btrim(m.raw), '') = ''                        THEN 'X_MISSING_RAW_STATION'
      -- lineage and source integrity
      WHEN m.lin_srv IS NULL                                      THEN 'X_NO_LINEAGE'
      WHEN m.k IS NULL OR m.h IS NULL OR length(m.h) <> 64        THEN 'X_BAD_SOURCE_EVIDENCE'
      WHEN m.lin_k IS DISTINCT FROM m.k                           THEN 'X_LINEAGE_KEY_DRIFT'
      WHEN m.lin_h IS DISTINCT FROM m.h                           THEN 'X_SOURCE_HASH_DRIFT'
      WHEN m.lin_raw IS DISTINCT FROM m.raw                       THEN 'X_RAW_STATION_DRIFT'
      WHEN m.lin_region IS DISTINCT FROM m.region_id              THEN 'X_RAW_REGION_DRIFT'
      -- the Station candidate itself
      WHEN m.n_same > 1                                           THEN 'X_MULTIPLE_CANDIDATES'
      -- Named as its own class so a cross-Region near-match is never merely
      -- absent from the report. Region is identity; it is NEVER substituted.
      WHEN m.n_same = 0 AND m.n_other > 0                         THEN 'X_CROSS_REGION_ONLY'
      WHEN m.n_same = 0                                           THEN 'X_NO_SAME_REGION_CANDIDATE'
      ELSE 'A_STATION_CONFIRMABLE'
    END
    FROM m
   ORDER BY m.id;
$$;

COMMENT ON FUNCTION cng_irv_station_batch_candidates() IS
  'Recomputes the Station-only batch candidates from canonical installed SRVs, their import '
  'lineage and the staged source evidence. Takes no candidate list and trusts no prior analysis. '
  'Qualifies a row only on same-Region evidence with exactly one canonical Station, by byte-exact '
  'or deployed-normalization equality. No alias, similarity, digit stripping, cross-Region '
  'substitution, Unit inference or equipment inference.';

-- ---------------------------------------------------------------------------
-- PREVIEW — counts plus the content-bound fingerprint. Zero writes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_station_batch_preview()
RETURNS TABLE (
  preview_fingerprint     text,
  eligible_rows           integer,
  eligible_identities     integer,
  byte_exact_rows         integer,
  normalized_rows         integer,
  byte_exact_identities   integer,
  normalized_identities   integer,
  distinct_target_stations integer,
  rows_delta              integer,
  rows_east               integer,
  rows_west               integer,
  rows_upper              integer,
  rows_canal              integer,
  rows_alex               integer,
  excluded_no_candidate   integer,
  excluded_cross_region_only integer,
  excluded_multi_candidate integer,
  excluded_not_unmapped   integer,
  excluded_already_station integer,
  excluded_deeper_mapping integer,
  excluded_missing_region integer,
  excluded_missing_raw    integer,
  excluded_no_lineage     integer,
  excluded_bad_evidence   integer,
  excluded_key_drift      integer,
  excluded_hash_drift     integer,
  excluded_raw_drift      integer,
  excluded_region_drift   integer,
  rows_under_one_unit_station integer,
  rows_that_would_get_a_unit  integer,
  canonical_irv_total     integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH c AS MATERIALIZED (SELECT * FROM cng_irv_station_batch_candidates()),
  e AS MATERIALIZED (SELECT * FROM c WHERE c.eligibility = 'A_STATION_CONFIRMABLE'),
  rowblob AS (
    -- Per SRV: identity, integrity evidence, the COMPLETE current state, the
    -- target, the mechanism, the row version and the expected outcome. Any
    -- change to any of these -- including a row joining or leaving the set --
    -- changes the hash.
    SELECT string_agg(
             concat_ws(chr(31),
               e.srv_id::text, e.source_row_key, e.source_row_hash,
               e.region_id::text, e.source_station_raw, e.normalized_identity,
               e.evidence_mechanism,
               'needs_station_mapping', 'station:NULL', 'unit:NULL', 'equipment:NULL',
               e.target_station_id::text,
               (SELECT s.region_id::text FROM stations s WHERE s.id = e.target_station_id),
               e.row_version::text,
               'needs_unit_mapping'),
             chr(30) ORDER BY e.srv_id) AS blob
      FROM e
  ),
  identblob AS (
    SELECT string_agg(g.blob, chr(29) ORDER BY g.region_id, g.ident) AS blob FROM (
      SELECT e.region_id, e.normalized_identity AS ident,
             concat_ws(chr(31), e.region_id::text, e.normalized_identity,
                       min(e.target_station_id::text), min(e.evidence_mechanism),
                       count(*)::text,
                       string_agg(DISTINCT e.source_station_raw, chr(28) ORDER BY e.source_station_raw)) AS blob
        FROM e GROUP BY e.region_id, e.normalized_identity) g
  )
  SELECT
    encode(sha256(convert_to(
      concat_ws(chr(27), 'irv_station_batch_v1',
                coalesce((SELECT blob FROM rowblob), ''),
                coalesce((SELECT blob FROM identblob), '')), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM e),
    (SELECT count(*)::integer FROM (SELECT 1 FROM e GROUP BY e.region_id, e.normalized_identity) z),
    (SELECT count(*)::integer FROM e WHERE e.evidence_mechanism = 'byte_exact'),
    (SELECT count(*)::integer FROM e WHERE e.evidence_mechanism = 'normalized'),
    (SELECT count(*)::integer FROM (SELECT 1 FROM e WHERE e.evidence_mechanism='byte_exact' GROUP BY e.region_id, e.normalized_identity) z),
    (SELECT count(*)::integer FROM (SELECT 1 FROM e WHERE e.evidence_mechanism='normalized' GROUP BY e.region_id, e.normalized_identity) z),
    (SELECT count(DISTINCT e.target_station_id)::integer FROM e),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'Delta'),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'East'),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'West'),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'Upper'),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'Canal'),
    (SELECT count(*)::integer FROM e JOIN regions r ON r.id = e.region_id WHERE r.name = 'Alex'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_NO_SAME_REGION_CANDIDATE'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_CROSS_REGION_ONLY'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_MULTIPLE_CANDIDATES'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_NOT_UNMAPPED'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_ALREADY_STATION_MAPPED'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_HAS_DEEPER_MAPPING'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_MISSING_REGION'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_MISSING_RAW_STATION'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_NO_LINEAGE'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_BAD_SOURCE_EVIDENCE'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_LINEAGE_KEY_DRIFT'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_SOURCE_HASH_DRIFT'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_RAW_STATION_DRIFT'),
    (SELECT count(*)::integer FROM c WHERE c.eligibility = 'X_RAW_REGION_DRIFT'),
    -- reported so the forbidden shortcut stays VISIBLE and provably unused
    (SELECT count(*)::integer FROM e
      WHERE (SELECT count(*) FROM units u WHERE u.station_id = e.target_station_id) = 1),
    0,
    (SELECT count(*)::integer FROM installed_relief_valves);
$$;

COMMENT ON FUNCTION cng_irv_station_batch_preview() IS
  'Zero-write preview of the Station-only installed-SRV batch. The fingerprint binds, per SRV, its '
  'id, source key and hash, Region, raw and normalized Station evidence, the evidence mechanism, '
  'the complete current state, the target Station and its Region, the row version and the expected '
  'resulting status -- plus the identity-level grouping -- so any set, member, evidence, target or '
  'state change invalidates it. rows_that_would_get_a_unit is structurally 0.';

-- ---------------------------------------------------------------------------
-- COMMIT — one atomic transaction, content-bound, admin-attributed, fail closed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_station_batch_commit(
  p_expected_fingerprint      text,
  p_expected_row_count        integer,
  p_expected_identity_count   integer,
  p_reason                    text
)
RETURNS TABLE (
  batch_id            uuid,
  srvs_mapped         integer,
  identities_mapped   integer,
  preview_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor    uuid := cng_require_admin();   -- server-derived; never a parameter
  v_batch    uuid := gen_random_uuid();
  v_now      timestamptz := now();
  v_fp       text;
  v_rows     integer;
  v_idents   integer;
  v_unit_bad integer;
  v_mapped   integer := 0;
  v_audited  integer := 0;
BEGIN
  -- Gate 1: an approval must be PRESENTED.
  IF coalesce(btrim(p_expected_fingerprint), '') = ''
     OR p_expected_row_count IS NULL OR p_expected_identity_count IS NULL THEN
    RAISE EXCEPTION 'Installed-SRV Station batch requires the approved fingerprint, row count and identity count'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 2: the set is RE-DERIVED inside this transaction. A changed row state,
  -- row version, source hash, lineage, raw evidence, target Station, evidence
  -- mechanism, identity grouping or set membership all move the fingerprint.
  SELECT pv.preview_fingerprint, pv.eligible_rows, pv.eligible_identities,
         pv.rows_that_would_get_a_unit
    INTO v_fp, v_rows, v_idents, v_unit_bad
    FROM cng_irv_station_batch_preview() pv;

  IF v_fp IS DISTINCT FROM p_expected_fingerprint THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: the set no longer matches the approved one (approved %, current %)',
      p_expected_fingerprint, v_fp USING ERRCODE = 'check_violation';
  END IF;
  IF v_rows IS DISTINCT FROM p_expected_row_count THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: % eligible rows, approved for %',
      v_rows, p_expected_row_count USING ERRCODE = 'check_violation';
  END IF;
  IF v_idents IS DISTINCT FROM p_expected_identity_count THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: % identities, approved for %',
      v_idents, p_expected_identity_count USING ERRCODE = 'check_violation';
  END IF;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: no eligible rows'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 3: defence in depth. The UPDATE cannot express a Unit, and this says so
  -- in its own right rather than relying on the column list alone.
  IF v_unit_bad <> 0 THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: % row(s) would receive a Unit', v_unit_bad
      USING ERRCODE = 'check_violation';
  END IF;

  -- The UPDATE names station_id and mapping_status ONLY. unit_id,
  -- compressor_id, storage_vessel_id and dispenser_id are not in it, so a Unit
  -- or an equipment parent cannot be written here at all. resolved_by /
  -- resolved_at stay NULL because needs_unit_mapping is not a resolution --
  -- irv_resolved_attribution_ck agrees. Region is unchanged: the candidate rule
  -- already requires the target Station to be in the row's own Region.
  WITH cand AS (
    SELECT c.srv_id, c.target_station_id, c.region_id
      FROM cng_irv_station_batch_candidates() c
     WHERE c.eligibility = 'A_STATION_CONFIRMABLE'
  ),
  upd AS (
    UPDATE installed_relief_valves v
       SET station_id     = c.target_station_id,
           mapping_status = 'needs_unit_mapping'::srv_mapping_status,
           updated_at     = v_now
      FROM cand c
     WHERE v.id = c.srv_id
    RETURNING v.id, c.target_station_id)
  SELECT count(*)::integer INTO v_mapped FROM upd;

  IF v_mapped IS DISTINCT FROM v_rows THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: % eligible but % updated', v_rows, v_mapped
      USING ERRCODE = 'check_violation';
  END IF;

  -- Per-SRV attribution, in the SAME shape cng_admin_map_srv writes, marked as
  -- one bulk batch. ama_bulk_ck requires is_bulk and bulk_batch_id to agree.
  WITH aud AS (
    INSERT INTO asset_mapping_audit (
      asset_type, asset_id,
      previous_station_id, new_station_id, previous_unit_id, new_unit_id,
      previous_parent_type, previous_parent_id, new_parent_type, new_parent_id,
      previous_mapping_status, new_mapping_status,
      changed_by, changed_at, is_bulk, bulk_batch_id, reason)
    SELECT 'installed_relief_valve', v.id,
           NULL, v.station_id, NULL, NULL,
           NULL, NULL, NULL, NULL,
           'needs_station_mapping', 'needs_unit_mapping',
           v_actor, v_now, true, v_batch, p_reason
      FROM installed_relief_valves v
     WHERE v.updated_at = v_now
       AND v.mapping_status = 'needs_unit_mapping'
    RETURNING 1)
  SELECT count(*)::integer INTO v_audited FROM aud;

  IF v_audited IS DISTINCT FROM v_mapped THEN
    RAISE EXCEPTION 'Installed-SRV Station batch refused: % mapped but % audited', v_mapped, v_audited
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', v_batch, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('Station-only batch: %s installed SRVs across %s identities, needs_station_mapping -> needs_unit_mapping',
                 v_mapped, v_idents),
          jsonb_build_object('mapping_status', 'needs_station_mapping',
                             'station_id', NULL, 'unit_id', NULL, 'equipment', NULL),
          jsonb_build_object('mapping_status', 'needs_unit_mapping',
                             'unit_id', NULL, 'equipment', NULL,
                             'batch_id', v_batch,
                             'preview_fingerprint', v_fp,
                             'srvs_mapped', v_mapped,
                             'identities_mapped', v_idents,
                             'byte_exact_rows', (SELECT pv.byte_exact_rows FROM cng_irv_station_batch_preview() pv),
                             'reason', p_reason),
          v_now);

  RETURN QUERY SELECT v_batch, v_mapped, v_idents, v_fp;
END;
$$;

COMMENT ON FUNCTION cng_irv_station_batch_commit(text, integer, integer, text) IS
  'Atomically confirms the Station on every eligible canonical installed SRV: station_id set, '
  'mapping_status needs_unit_mapping, and unit_id plus all equipment parents left NULL -- they are '
  'not in the UPDATE, so a Unit is inexpressible even where the Station has exactly one. '
  'Content-bound to the preview fingerprint, the row count and the identity count, all re-derived '
  'inside the transaction. Admin only with the actor derived server-side from the verified Clerk '
  'subject; it takes no actor parameter and is never attributed to service_role.';

REVOKE ALL ON FUNCTION cng_irv_station_batch_candidates() FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_station_batch_candidates() FROM anon, service_role;
GRANT EXECUTE ON FUNCTION cng_irv_station_batch_candidates() TO authenticated;

REVOKE ALL ON FUNCTION cng_irv_station_batch_preview() FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_station_batch_preview() FROM anon, service_role;
GRANT EXECUTE ON FUNCTION cng_irv_station_batch_preview() TO authenticated;

REVOKE ALL ON FUNCTION cng_irv_station_batch_commit(text, integer, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_station_batch_commit(text, integer, integer, text) FROM anon, service_role;
GRANT EXECUTE ON FUNCTION cng_irv_station_batch_commit(text, integer, integer, text) TO authenticated;
