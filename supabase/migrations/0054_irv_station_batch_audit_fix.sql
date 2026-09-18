-- 0054_irv_station_batch_audit_fix.sql
-- Capture the batch-level audit summary BEFORE the UPDATE (Prompt 25K).
--
-- ADDS NO TABLE, COLUMN, ENUM, CONSTRAINT, INDEX, POLICY, GRANT OR VIEW, and
-- creates no new function. It replaces exactly ONE function body --
-- `cng_irv_station_batch_commit` -- and touches nothing else. Migrations 0052
-- and 0053 are NOT modified; this supersedes 0052's body the way every
-- CREATE OR REPLACE in this project does, leaving 0052 as the historical record
-- of what was deployed at the time.
--
-- ============================== THE DEFECT ==================================
--
-- The Prompt 25J batch mapped 1,054 SRVs correctly, but its `audit_logs` row
-- recorded `byte_exact_rows: 0` when the truth was 839 (with 215 by
-- normalization). Found during 25J verification by comparing the audit payload
-- against the canonical rows.
--
-- ROOT CAUSE, confirmed in the deployed body: it called
-- `cng_irv_station_batch_preview()` TWICE -- once at Gate 2, correctly, before
-- any mutation; and once more INLINE in the audit payload, to fetch
-- `byte_exact_rows`. That second call runs AFTER the UPDATE inside the same
-- transaction, by which point the mapped rows are no longer
-- `needs_station_mapping`, so the eligible set is EMPTY and every
-- eligibility-derived count reads 0.
--
-- It was a REPORTING defect only. The mapping, the row and identity counts, the
-- fingerprint, the per-row `asset_mapping_audit` and every guard were correct,
-- because all of those already came from the PRE-UPDATE preview. Only the one
-- informational field re-read the world after changing it.
--
-- ================================ THE FIX ==================================
--
-- Gate 2 now captures EVERY preview-derived value the audit payload needs, from
-- the SAME single preview whose fingerprint is compared against the approval.
-- Nothing is recomputed after the UPDATE, so the audit necessarily describes the
-- set that was approved and mapped rather than the world left behind.
--
-- The body therefore calls `cng_irv_station_batch_preview()` EXACTLY ONCE, and
-- that is a machine-checkable property (IRVAUD-2 re-derives the call count from
-- `pg_proc.prosrc`), not a promise in a comment.
--
-- NOTHING ELSE CHANGES. Candidate eligibility, the same-Region requirement, both
-- evidence mechanisms, fingerprint construction, the row-count, identity-count,
-- stale-state, lineage and hash guards, Admin-only authorization with a
-- server-derived actor, atomicity, the Station-only UPDATE, the
-- needs_station_mapping -> needs_unit_mapping transition, per-row audit,
-- bulk_batch_id semantics, replay refusal, RLS and permissions are all carried
-- over verbatim. The UPDATE still names `station_id` and `mapping_status` ONLY,
-- so `unit_id` and every equipment parent remain inexpressible here.
--
-- THE HISTORICAL AUDIT ROW IS NOT TOUCHED. Migration-time DML would be the wrong
-- instrument even if it were authorized: `audit_logs` is append-only evidence,
-- and a batch that really did record 0 is part of the record. The discrepancy is
-- documented in docs/srv-management.md instead. This migration executes no DML.
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
  -- Every value the batch-level audit payload reports, captured from the
  -- PRE-UPDATE preview. Re-reading any of these after the UPDATE is what
  -- produced `byte_exact_rows: 0` on the Prompt 25J batch.
  v_byte_exact       integer;
  v_normalized       integer;
  v_byte_exact_ident integer;
  v_normalized_ident integer;
  v_targets          integer;
  v_delta            integer;
  v_east             integer;
  v_west             integer;
  v_upper            integer;
  v_canal            integer;
  v_alex             integer;
  v_one_unit         integer;
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
  --
  -- This is also the ONLY preview call in the function. Everything the audit
  -- later reports is taken from THIS row, so the record describes the approved
  -- set and not the post-UPDATE world.
  SELECT pv.preview_fingerprint, pv.eligible_rows, pv.eligible_identities,
         pv.rows_that_would_get_a_unit,
         pv.byte_exact_rows, pv.normalized_rows,
         pv.byte_exact_identities, pv.normalized_identities,
         pv.distinct_target_stations,
         pv.rows_delta, pv.rows_east, pv.rows_west,
         pv.rows_upper, pv.rows_canal, pv.rows_alex,
         pv.rows_under_one_unit_station
    INTO v_fp, v_rows, v_idents, v_unit_bad,
         v_byte_exact, v_normalized,
         v_byte_exact_ident, v_normalized_ident,
         v_targets,
         v_delta, v_east, v_west, v_upper, v_canal, v_alex,
         v_one_unit
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

  -- Every figure below is a CAPTURED variable from the pre-UPDATE preview. No
  -- subquery re-reads the eligible set here, which is the whole fix.
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
                             'byte_exact_rows', v_byte_exact,
                             'normalization_only_rows', v_normalized,
                             'byte_exact_identities', v_byte_exact_ident,
                             'normalization_only_identities', v_normalized_ident,
                             'distinct_target_stations', v_targets,
                             'rows_by_region', jsonb_build_object(
                               'Delta', v_delta, 'East', v_east, 'West', v_west,
                               'Upper', v_upper, 'Canal', v_canal, 'Alex', v_alex),
                             -- Recorded so the refusal stays legible in the
                             -- history: this many rows sat under a one-Unit
                             -- Station and NONE received that Unit.
                             'rows_under_one_unit_station', v_one_unit,
                             'units_assigned', 0,
                             'equipment_assigned', 0,
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
  'subject; it takes no actor parameter and is never attributed to service_role. The batch-level '
  'audit summary is captured from the PRE-UPDATE preview, so it describes the approved set rather '
  'than the empty set the UPDATE leaves behind (Prompt 25K).';
