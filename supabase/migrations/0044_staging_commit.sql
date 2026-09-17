-- 0044_staging_commit.sql
-- The persisted staging write path (Prompt 20F).
--
-- THE GAP THIS CLOSES. Prompt 6 built a parser, a normalizer and a dry run that
-- returns staged rows, issues and conflicts IN MEMORY. `src/import/` contains no
-- database client at all, so no run has ever been persisted: production's
-- `import_staging_rows` is empty and the well-known 7,163 / 1,104 figures are a
-- dry-run COMPUTATION, not stored rows. Everything needed to store them already
-- existed — `import_runs`, `import_batches` (with `file_checksum`),
-- `import_staging_rows`, `import_issues`, `import_source_conflicts`. Only the
-- writer was missing, and this migration adds exactly that and nothing else.
--
-- NO NEW TABLE, NO NEW COLUMN, NO NEW ENUM. A second import architecture was not
-- invented because the first one was already complete but for its last step.
--
-- ============================ THE CANONICAL FIREWALL =========================
-- This function is STRUCTURALLY incapable of writing a canonical asset.
--
--   * Its body contains five INSERT statements and their target tables are
--     written as literals: import_runs, import_batches, import_staging_rows,
--     import_issues, import_source_conflicts. That list IS the allowlist.
--   * There is NO dynamic SQL — no EXECUTE, no format(), no quote_ident(). The
--     caller therefore cannot name a destination, and `target_table` arrives as
--     DATA stored in a column, never as an identifier.
--   * It writes no `import_mapping_decisions` row, so staging can never resolve
--     a mapping, and the 0039/0041 content-binding rules are untouched.
--   * It creates no Station, no Unit and no asset.
--
-- A schema assertion re-derives all of that from `pg_proc.prosrc` rather than
-- trusting this comment, so a later edit that reached for a canonical table
-- would fail verification.
--
-- =============================== AUTHORIZATION ===============================
-- EXECUTE is granted to `service_role` ONLY. `authenticated` — including an
-- admin in a browser — cannot call it. That is deliberate (Prompt 20F Phase 15):
-- the staging commit is an operator action run through a server-side controlled
-- runner that holds the service-role key, not a file upload through the
-- production frontend. No browser gains any new authority here, and every import
-- table keeps its existing `authenticated` SELECT-only grant.
--
-- ================================= ATOMICITY =================================
-- One call is one statement is one transaction. Either the whole batch lands or
-- none of it does, so a partially written batch cannot exist to be mistaken for
-- a ready one. The run is inserted as `running` and set to `completed` in the
-- same transaction; a run left at `running` is therefore a crash marker, never a
-- half-committed workload.

-- ---------------------------------------------------------------------------
-- REPLAY IDENTITY. The manifest fingerprint is a hash over every source file
-- and its SHA-256, so identical source content yields an identical value and a
-- changed workbook yields a different one. This partial unique index makes
-- "one completed run per source content" a DATABASE property rather than a
-- convention: a double-click, a retry after a dropped connection, or two
-- operators racing each other produce ONE run, and the loser is told so.
--
-- Deliberately partial on `completed`: a failed or rolled-back run must not
-- block a later corrected attempt at the same sources.
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS import_runs_manifest_fingerprint_uq
  ON import_runs ((summary ->> 'manifest_fingerprint'))
  WHERE completed_at IS NOT NULL AND (summary ->> 'manifest_fingerprint') IS NOT NULL;

COMMENT ON INDEX import_runs_manifest_fingerprint_uq IS
  'One COMPLETED staging run per distinct source content. Partial on completed_at so a failed run never blocks a corrected retry of the same sources.';

-- ---------------------------------------------------------------------------
-- THE WRITER.
--
-- Everything arrives as jsonb DATA. `p_manifest` carries the run label, the
-- fingerprint and the per-file SHA-256 values; `p_batches` one entry per
-- file/sheet; `p_rows` the staged rows; `p_issues` the data-quality issues;
-- `p_conflicts` the source conflicts. The runner has already computed all of it
-- with the same parser the dry run uses.
--
-- The function re-derives NOTHING about the data and guesses NOTHING. It does
-- not normalize, does not match a Station, does not resolve a mapping and does
-- not fill a missing value. A NULL stays NULL, and Arabic source text is stored
-- exactly as supplied because it travels as a jsonb string.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_stage_import_batch(
  p_manifest  jsonb,
  p_batches   jsonb,
  p_rows      jsonb,
  p_issues    jsonb DEFAULT '[]'::jsonb,
  p_conflicts jsonb DEFAULT '[]'::jsonb
)
RETURNS TABLE (
  import_run_id uuid,
  batches_written integer,
  rows_written integer,
  issues_written integer,
  conflicts_written integer
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_run         uuid := gen_random_uuid();
  v_fingerprint text := p_manifest ->> 'manifest_fingerprint';
  v_batch_ids   jsonb := '{}'::jsonb;
  v_b           jsonb;
  v_bid         uuid;
  v_nb          integer := 0;
  v_nr          integer := 0;
  v_ni          integer := 0;
  v_nc          integer := 0;
BEGIN
  IF v_fingerprint IS NULL OR length(v_fingerprint) = 0 THEN
    RAISE EXCEPTION 'manifest_fingerprint is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_batches) <> 'array' OR jsonb_array_length(p_batches) = 0 THEN
    RAISE EXCEPTION 'at least one batch is required' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be an array' USING ERRCODE = '22023';
  END IF;

  -- The run. `completed_at` is set here, in the same transaction that writes
  -- every row, so the unique index above rejects a duplicate of identical
  -- source content at COMMIT time rather than leaving a race open.
  INSERT INTO import_runs (id, mode, label, started_at, completed_at, started_by, summary, notes)
  VALUES (
    v_run,
    'dry_run'::import_run_mode,
    p_manifest ->> 'label',
    coalesce((p_manifest ->> 'started_at')::timestamptz, now()),
    now(),
    NULL,
    p_manifest,
    'Persisted staging run. No canonical asset was written and no mapping was decided.'
  );

  -- One batch per source file/sheet, each carrying its own SHA-256.
  FOR v_b IN SELECT * FROM jsonb_array_elements(p_batches)
  LOOP
    v_bid := gen_random_uuid();
    INSERT INTO import_batches (
      id, import_run_id, source_file, source_sheet, file_checksum, header_row,
      status, started_at, completed_at,
      rows_read, rows_imported, rows_flagged, rows_failed, metadata
    ) VALUES (
      v_bid, v_run,
      v_b ->> 'source_file',
      v_b ->> 'source_sheet',
      v_b ->> 'file_checksum',
      (v_b ->> 'header_row')::integer,
      'completed'::import_status,
      now(), now(),
      coalesce((v_b ->> 'rows_read')::integer, 0),
      0,  -- rows_imported is CANONICAL insertion. Staging imports nothing.
      coalesce((v_b ->> 'rows_flagged')::integer, 0),
      coalesce((v_b ->> 'rows_failed')::integer, 0),
      v_b -> 'metadata'
    );
    v_batch_ids := v_batch_ids || jsonb_build_object(v_b ->> 'batch_key', v_bid::text);
    v_nb := v_nb + 1;
  END LOOP;

  -- The staged rows. `source_raw` and `normalized` are stored verbatim.
  INSERT INTO import_staging_rows (
    import_run_id, import_batch_id, source_file, source_sheet, source_row,
    source_raw, source_row_key, source_row_hash, target_table,
    outcome, mapping_status, normalized, resolution
  )
  SELECT
    v_run,
    (v_batch_ids ->> (e ->> 'batch_key'))::uuid,
    e ->> 'source_file',
    e ->> 'source_sheet',
    (e ->> 'source_row')::integer,
    e -> 'source_raw',
    e ->> 'source_row_key',
    e ->> 'source_row_hash',
    e ->> 'target_table',
    (e ->> 'outcome')::staging_outcome,
    e ->> 'mapping_status',
    e -> 'normalized',
    e -> 'resolution'
  FROM jsonb_array_elements(p_rows) AS e;
  GET DIAGNOSTICS v_nr = ROW_COUNT;

  IF jsonb_typeof(p_issues) = 'array' AND jsonb_array_length(p_issues) > 0 THEN
    INSERT INTO import_issues (
      import_batch_id, source_file, source_sheet, source_row, source_raw,
      source_value, issue_type, severity, status, detail
    )
    SELECT
      (v_batch_ids ->> (e ->> 'batch_key'))::uuid,
      e ->> 'source_file',
      e ->> 'source_sheet',
      (e ->> 'source_row')::integer,
      e -> 'source_raw',
      e ->> 'source_value',
      (e ->> 'issue_type')::import_issue_type,
      (e ->> 'severity')::issue_severity,
      'open'::issue_status,
      e ->> 'detail'
    FROM jsonb_array_elements(p_issues) AS e;
    GET DIAGNOSTICS v_ni = ROW_COUNT;
  END IF;

  IF jsonb_typeof(p_conflicts) = 'array' AND jsonb_array_length(p_conflicts) > 0 THEN
    INSERT INTO import_source_conflicts (
      import_run_id, entity_kind, entity_key, field_name,
      left_value_raw, left_source, right_value_raw, right_source,
      precedence_rule, selected_side
    )
    SELECT
      v_run,
      e ->> 'entity_kind',
      e ->> 'entity_key',
      e ->> 'field_name',
      e ->> 'left_value_raw',
      e -> 'left_source',
      e ->> 'right_value_raw',
      e -> 'right_source',
      e ->> 'precedence_rule',
      e ->> 'selected_side'
    FROM jsonb_array_elements(p_conflicts) AS e;
    GET DIAGNOSTICS v_nc = ROW_COUNT;
  END IF;

  RETURN QUERY SELECT v_run, v_nb, v_nr, v_ni, v_nc;
END;
$$;

COMMENT ON FUNCTION cng_stage_import_batch(jsonb, jsonb, jsonb, jsonb, jsonb) IS
  'Persists one staging run: import_runs, import_batches, import_staging_rows, import_issues, import_source_conflicts and NOTHING else. No canonical table, no mapping decision, no dynamic SQL. service_role only.';

REVOKE ALL ON FUNCTION cng_stage_import_batch(jsonb, jsonb, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_import_batch(jsonb, jsonb, jsonb, jsonb, jsonb) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_stage_import_batch(jsonb, jsonb, jsonb, jsonb, jsonb) TO service_role;

-- ---------------------------------------------------------------------------
-- ABANDONING A BATCH (Phase 10).
--
-- No hard delete. The project forbids destroying import and audit records, and
-- a staging run is exactly such a record. Abandonment is therefore a STATE, and
-- it is batch-scoped by a required id — there is no statement here that could
-- degenerate into an unscoped DELETE.
--
-- It REFUSES to abandon a run any mapping decision references, so a ruling can
-- never be orphaned, and it refuses one whose rows were committed to canonical
-- tables.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_abandon_import_run(p_import_run_id uuid, p_reason text)
RETURNS TABLE (import_run_id uuid, batches_marked integer)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_n integer := 0;
  v_committed integer;
  v_decided integer;
BEGIN
  IF p_import_run_id IS NULL THEN
    RAISE EXCEPTION 'an import run id is required' USING ERRCODE = '22023';
  END IF;
  IF p_reason IS NULL OR length(btrim(p_reason)) = 0 THEN
    RAISE EXCEPTION 'a reason is required' USING ERRCODE = '22023';
  END IF;

  SELECT count(*) INTO v_committed
  FROM import_staging_rows
  WHERE import_run_id = p_import_run_id AND committed_entity_id IS NOT NULL;
  IF v_committed > 0 THEN
    RAISE EXCEPTION 'run % has % canonically committed row(s) and cannot be abandoned',
      p_import_run_id, v_committed USING ERRCODE = '23505';
  END IF;

  SELECT count(*) INTO v_decided
  FROM import_mapping_decisions d
  JOIN import_staging_rows r ON r.source_row_key = d.source_row_key
  WHERE r.import_run_id = p_import_run_id;
  IF v_decided > 0 THEN
    RAISE EXCEPTION 'run % is referenced by % mapping decision(s); abandoning it would orphan them',
      p_import_run_id, v_decided USING ERRCODE = '23503';
  END IF;

  UPDATE import_batches
     SET status = 'rolled_back'::import_status, updated_at = now()
   WHERE import_run_id = p_import_run_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  UPDATE import_runs
     SET notes = coalesce(notes || ' | ', '') || 'ABANDONED: ' || p_reason,
         summary = coalesce(summary, '{}'::jsonb) || jsonb_build_object('abandoned', true, 'abandoned_reason', p_reason),
         completed_at = completed_at,
         updated_at = now()
   WHERE id = p_import_run_id;

  RETURN QUERY SELECT p_import_run_id, v_n;
END;
$$;

COMMENT ON FUNCTION cng_abandon_import_run(uuid, text) IS
  'Marks one staging run abandoned. Batch-scoped by a required id, never a delete, refuses a run with canonically committed rows or referenced mapping decisions. service_role only.';

REVOKE ALL ON FUNCTION cng_abandon_import_run(uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_abandon_import_run(uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_abandon_import_run(uuid, text) TO service_role;
