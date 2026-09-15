-- 0026_import_pipeline_tables.sql
-- Staging infrastructure for the import pipeline.
--
-- WHAT ALREADY EXISTED AND IS REUSED, NOT DUPLICATED (0004):
--   * `import_batches` -- one file+sheet processed by one run
--   * `import_issues`  -- why a row needs attention, with full provenance
-- Alias proposal/confirmation/rejection already exists too, in
-- `station_aliases`/`unit_aliases` with `alias_status`, so no parallel
-- "proposed mapping" table is introduced here.
--
-- WHAT WAS GENUINELY MISSING, and is added:
--   1. a RUN -- one execution spanning several files, so a dry-run report is a
--      single object rather than six unrelated batches
--   2. a STAGING ROW -- the normalized, resolved, not-yet-committed form of one
--      source row. This is what makes dry-run real: identical parsing,
--      normalization, matching and validation, landing here instead of in a
--      canonical table
--   3. a SOURCE CONFLICT -- two sources disagreeing on one FIELD of one entity,
--      with BOTH raw values kept and neither chosen
--
-- Nothing here writes to a canonical asset table. Committing is a separate,
-- explicit operation (Prompt 21) that reads staging.

-- ---------------------------------------------------------------------------
-- 1. Runs
-- ---------------------------------------------------------------------------

CREATE TABLE import_runs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  mode            import_run_mode NOT NULL DEFAULT 'dry_run',
  label           text NULL,
  started_at      timestamptz NOT NULL DEFAULT now(),
  completed_at    timestamptz NULL,
  started_by      uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  -- Free-form counts for the report. Never a source of truth: every figure is
  -- recomputable from import_staging_rows and import_issues.
  summary         jsonb NULL,
  notes           text NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE import_runs IS
  'One execution of the import pipeline over one or more workbooks. A dry run '
  'writes only to staging; it can never modify a canonical asset table.';

ALTER TABLE import_batches ADD COLUMN import_run_id uuid NULL
  REFERENCES import_runs(id) ON DELETE RESTRICT;

CREATE INDEX import_batches_run_idx ON import_batches (import_run_id);

-- ---------------------------------------------------------------------------
-- 2. Staging rows
-- ---------------------------------------------------------------------------

CREATE TABLE import_staging_rows (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_run_id     uuid NOT NULL REFERENCES import_runs(id)   ON DELETE RESTRICT,
  import_batch_id   uuid NOT NULL REFERENCES import_batches(id) ON DELETE RESTRICT,

  -- Provenance: enough to reconstruct exactly where this came from (§4).
  source_file       text    NOT NULL,
  source_sheet      text    NOT NULL,
  source_row        integer NOT NULL,          -- 1-based, as the workbook numbers it
  source_raw        jsonb   NOT NULL,          -- the ENTIRE row, verbatim, never overwritten

  -- Identity for replay detection (§21). `source_row_key` is stable across
  -- runs of the same file+sheet+row; `source_row_hash` changes if the row's
  -- CONTENT changed, which is what separates a retry from a new file version.
  source_row_key    text    NOT NULL,
  source_row_hash   text    NOT NULL,

  target_table      text    NOT NULL,          -- canonical table a commit would touch
  outcome           staging_outcome NOT NULL,
  -- TEXT, not an enum: the lifecycle exists as TWO canonical enums
  -- (`srv_mapping_status` and `asset_mapping_status`) and a staging row may be
  -- destined for either. The CHECK keeps the vocabulary exact; the canonical
  -- tables keep their own enums and their own status-shape constraints, which
  -- remain authoritative at commit time.
  mapping_status    text NULL CHECK (mapping_status IN (
                      'needs_station_mapping', 'needs_unit_mapping',
                      'needs_equipment_mapping', 'resolved', 'conflict')),

  -- The normalized candidate record. Kept SEPARATE from source_raw so raw and
  -- normalized never become indistinguishable (§4).
  normalized        jsonb NULL,
  -- How each resolution was reached: matched alias, owner-confirmed rule,
  -- proposal with score and method, or nothing. Makes a value explainable.
  resolution        jsonb NULL,

  region_id         uuid NULL REFERENCES regions(id)  ON DELETE RESTRICT,
  station_id        uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,
  unit_id           uuid NULL REFERENCES units(id)    ON DELETE RESTRICT,

  -- Set only by a commit (Prompt 21). NULL for every dry-run row, which is the
  -- simplest possible proof that a dry run created nothing.
  committed_entity_id uuid NULL,
  committed_at        timestamptz NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  -- One row per source row per run. A re-run is a NEW run, so history is kept.
  CONSTRAINT import_staging_rows_uq UNIQUE (import_run_id, source_row_key),

  -- A dry-run row can never claim to have committed anything.
  CONSTRAINT staging_commit_shape_ck CHECK (
    (committed_entity_id IS NULL) = (committed_at IS NULL)
  )
);

CREATE INDEX import_staging_rows_run_idx      ON import_staging_rows (import_run_id);
CREATE INDEX import_staging_rows_batch_idx    ON import_staging_rows (import_batch_id);
CREATE INDEX import_staging_rows_outcome_idx  ON import_staging_rows (import_run_id, outcome);
CREATE INDEX import_staging_rows_mapping_idx  ON import_staging_rows (import_run_id, mapping_status);
CREATE INDEX import_staging_rows_key_idx      ON import_staging_rows (source_row_key);
CREATE INDEX import_staging_rows_hash_idx     ON import_staging_rows (source_row_hash);

COMMENT ON COLUMN import_staging_rows.source_raw IS
  'The entire source row, verbatim. Never overwritten by a normalized value.';
COMMENT ON COLUMN import_staging_rows.source_row_hash IS
  'Content hash. Same key + same hash on a later run = a replay. Same key + a '
  'different hash = the source file genuinely changed.';

-- ---------------------------------------------------------------------------
-- 3. Field-level source conflicts
-- ---------------------------------------------------------------------------
-- NO workbook wins globally (CLAUDE.md principle #18). Where two sources give
-- different values for the same field of the same entity and no field-level
-- precedence is declared, BOTH are kept here and NEITHER is chosen.

CREATE TABLE import_source_conflicts (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_run_id     uuid NOT NULL REFERENCES import_runs(id) ON DELETE RESTRICT,

  entity_kind       text NOT NULL,      -- 'station', 'unit', 'gas_detector', ...
  entity_key        text NOT NULL,      -- how the pipeline identified the entity
  field_name        text NOT NULL,

  -- Both sides, raw, with provenance. Neither is promoted.
  left_value_raw    text NULL,
  left_source       jsonb NOT NULL,     -- {file, sheet, row}
  right_value_raw   text NULL,
  right_source      jsonb NOT NULL,

  -- Populated ONLY where import-mapping.md §8 declares a precedence for this
  -- field. NULL means no rule exists and a human decides.
  precedence_rule   text NULL,
  selected_side     text NULL CHECK (selected_side IN ('left', 'right')),

  resolved_by       uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at       timestamptz NULL,
  resolution_note   text NULL,

  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  -- A selected side must name the rule that selected it: no silent winners.
  CONSTRAINT conflict_selection_ck CHECK (
    (selected_side IS NULL) OR (precedence_rule IS NOT NULL) OR (resolved_by IS NOT NULL)
  )
);

CREATE INDEX import_source_conflicts_run_idx    ON import_source_conflicts (import_run_id);
CREATE INDEX import_source_conflicts_entity_idx ON import_source_conflicts (entity_kind, entity_key);
CREATE INDEX import_source_conflicts_open_idx   ON import_source_conflicts (import_run_id)
  WHERE resolved_at IS NULL;

COMMENT ON TABLE import_source_conflicts IS
  'Two sources disagreeing about ONE field of one entity. Both raw values are '
  'kept with provenance. A value is selected only by a declared field-level '
  'precedence rule or by a human -- never by workbook seniority.';

-- ---------------------------------------------------------------------------
-- 4. updated_at triggers, matching every other table
-- ---------------------------------------------------------------------------

CREATE TRIGGER import_runs_set_updated_at BEFORE UPDATE ON import_runs
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER import_staging_rows_set_updated_at BEFORE UPDATE ON import_staging_rows
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER import_source_conflicts_set_updated_at BEFORE UPDATE ON import_source_conflicts
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. RLS -- no table ships without it (CLAUDE.md §7)
-- ---------------------------------------------------------------------------
-- Import is a privileged administrative operation (prompt §29). Viewers and
-- engineers get NOTHING here, not even read: staging holds unresolved raw
-- source text, and raw source text is never an authorization boundary.

ALTER TABLE import_runs             ENABLE ROW LEVEL SECURITY;
ALTER TABLE import_staging_rows     ENABLE ROW LEVEL SECURITY;
ALTER TABLE import_source_conflicts ENABLE ROW LEVEL SECURITY;

ALTER TABLE import_runs             FORCE ROW LEVEL SECURITY;
ALTER TABLE import_staging_rows     FORCE ROW LEVEL SECURITY;
ALTER TABLE import_source_conflicts FORCE ROW LEVEL SECURITY;

CREATE POLICY import_runs_select ON import_runs FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());
CREATE POLICY import_staging_rows_select ON import_staging_rows FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());
CREATE POLICY import_source_conflicts_select ON import_source_conflicts FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());

-- Resolving a conflict is the one write the UI needs, and only an admin may do
-- it. USING and WITH CHECK both present, as every UPDATE policy must be.
CREATE POLICY import_source_conflicts_update ON import_source_conflicts FOR UPDATE TO authenticated
  USING (cng_is_admin())
  WITH CHECK (cng_is_admin());

-- ---------------------------------------------------------------------------
-- 6. Grants -- closed by default
-- ---------------------------------------------------------------------------
-- No INSERT anywhere: staging is written by the pipeline running server-side
-- with database credentials, never through the API. No DELETE anywhere:
-- import history is retained. Column-level UPDATE keeps a conflict resolver
-- from rewriting the evidence it is resolving.

GRANT SELECT ON import_runs             TO authenticated;
GRANT SELECT ON import_staging_rows     TO authenticated;
GRANT SELECT ON import_source_conflicts TO authenticated;

GRANT UPDATE (selected_side, resolved_by, resolved_at, resolution_note)
  ON import_source_conflicts TO authenticated;
