-- ---------------------------------------------------------------------------
-- 0039 — Pre-import human mapping decisions (Prompt 19A).
--
-- THE PROBLEM THIS SOLVES, STATED EXACTLY:
--
--   Prompt 6's dry run staged 1,104 rows in `needs_station_mapping` — 433
--   Storage Vessels, 403 Recovery Tanks, 219 Gas Detectors, 49 Hoses. Their
--   canonical tables all declare `station_id NOT NULL`, so those rows cannot be
--   committed at all until a human confirms a Station. That is not a schema
--   defect: a vessel with no proven Station is exactly the record principle #8
--   says must never be guessed.
--
--   WHAT IS NOT DONE HERE: `station_id` is NOT made nullable on any canonical
--   asset table, no constraint is relaxed, and no staged row is dropped. The
--   canonical tables keep saying what they have always said — a stored asset
--   belongs to a Station.
--
--   WHAT IS DONE HERE: the resolution is moved EARLIER, to before the import,
--   where the evidence still lives. An admin works the staged rows and records a
--   decision. Prompt 21 then commits rows whose Station is proven by that
--   decision, and leaves the rest staged.
--
-- FIVE KINDS OF THING, KEPT APART. Conflating any two of these is how a guess
-- becomes a fact:
--
--   1. RAW SOURCE EVIDENCE      `import_staging_rows.source_raw` — verbatim,
--                               never written by anything in this migration.
--   2. AUTOMATED CANDIDATE      `import_staging_rows.resolution.proposals` — a
--                               similarity proposal. Attaches nothing, ever.
--   3. OWNER-CONFIRMED RULE     `owner_confirmed_station_aliases` — a GLOBAL
--                               ruling by the system owner that applies to every
--                               row carrying that exact value.
--   4. HUMAN ROW-LEVEL DECISION `import_mapping_decisions` — THIS TABLE. It
--                               binds ONE source row to a Station and possibly a
--                               Unit. It is deliberately NOT a rule: it says
--                               nothing about any other row, even an identical
--                               one.
--   5. CANONICAL RECORD         the asset table, written only by Prompt 21.
--
--   A decision here therefore NEVER becomes an alias. Promoting a row-level
--   decision into a global rule is exactly the "silent guess" CLAUDE.md §8
--   forbids, and there is no code path in this migration that could do it.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- 1. The decision record
-- ===========================================================================

CREATE TABLE import_mapping_decisions (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- WHICH staged row this decision is about. The FK proves the row existed;
  -- `source_row_key` is carried alongside it deliberately, because a later dry
  -- run creates NEW staging rows for the same source cells and the decision
  -- must survive that. Identity is (file, sheet, row), never a display name.
  staging_row_id     uuid NOT NULL REFERENCES import_staging_rows(id) ON DELETE RESTRICT,
  source_row_key     text NOT NULL,
  target_table       text NOT NULL,
  asset_type         asset_type NOT NULL,

  -- WHAT was confirmed. `region_id` is DERIVED from the Station inside the
  -- function, never accepted from the caller.
  region_id          uuid NOT NULL REFERENCES regions(id)  ON DELETE RESTRICT,
  confirmed_station_id uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  confirmed_unit_id  uuid NULL,

  -- WHERE it came from and where it went.
  previous_mapping_status text NOT NULL,
  resulting_mapping_status text NOT NULL,

  -- WHO and WHEN. `decided_by` is written from `cng_require_admin()`; it is not
  -- a parameter of any function and the INSERT policy pins it to the caller.
  decided_by         uuid NOT NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  decided_at         timestamptz NOT NULL DEFAULT now(),
  reason             text NULL,

  -- A CORRECTION SUPERSEDES; IT NEVER OVERWRITES. History is the point.
  superseded_at      timestamptz NULL,
  -- DEFERRABLE because a correction names its replacement in the same statement
  -- that mints it: the supersede runs before the INSERT (the partial unique
  -- index below forbids two active rows), so the referenced row does not exist
  -- yet mid-transaction. It must exist by COMMIT, and that is what is enforced.
  superseded_by      uuid NULL REFERENCES import_mapping_decisions(id) ON DELETE RESTRICT
                       DEFERRABLE INITIALLY DEFERRED,

  -- The evidence the decision was made FROM, captured at decision time. If the
  -- source file is later re-read, what the human actually saw is still here.
  source_evidence    jsonb NOT NULL,

  created_at         timestamptz NOT NULL DEFAULT now(),

  -- Only the four pre-import asset types. Installed SRVs are NOT here: their
  -- canonical `station_id` is nullable, so they import unresolved and are mapped
  -- in the canonical table by `cng_admin_map_srv`. Two mapping paths for one
  -- asset type would be two places for the truth to live.
  CONSTRAINT imd_target_ck CHECK (
    target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
  ),
  CONSTRAINT imd_asset_type_ck CHECK (
    (target_table, asset_type) IN (
      ('storage_vessels', 'storage_vessel'), ('recovery_tanks', 'recovery_tank'),
      ('gas_detectors',  'gas_detector'),    ('hoses',          'hose'))
  ),

  -- The resulting status is DERIVED, and this constraint is what makes that
  -- claim checkable rather than a comment. None of these asset types has an
  -- equipment parent, so there is no `needs_equipment_mapping` here and a
  -- confirmed Station alone is a legitimate end state for a hose whose Unit the
  -- source genuinely does not prove.
  CONSTRAINT imd_status_shape_ck CHECK (
    CASE resulting_mapping_status
      WHEN 'resolved'           THEN confirmed_unit_id IS NOT NULL
      WHEN 'needs_unit_mapping' THEN confirmed_unit_id IS NULL
      ELSE false
    END
  ),

  CONSTRAINT imd_superseded_shape_ck CHECK (
    (superseded_at IS NULL) = (superseded_by IS NULL)
  ),

  -- THE HIERARCHY, ENFORCED THE SAME WAY IT IS EVERYWHERE ELSE: a composite
  -- foreign key, not a trigger and not application code. Under MATCH SIMPLE it
  -- is dormant while `confirmed_unit_id` is NULL and enforced the moment a Unit
  -- is named — so a Unit from another Station is impossible to record.
  CONSTRAINT imd_unit_station_fk FOREIGN KEY (confirmed_unit_id, confirmed_station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT imd_station_region_fk FOREIGN KEY (confirmed_station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT
);

-- EXACTLY ONE ACTIVE DECISION PER SOURCE ROW. A second decision must supersede
-- the first; it can never sit beside it. This is what makes "what did we decide
-- about this row" answerable with a single SELECT, and what Prompt 21 reads.
CREATE UNIQUE INDEX imd_one_active_per_source_row
  ON import_mapping_decisions (source_row_key) WHERE superseded_at IS NULL;

CREATE INDEX imd_staging_row_idx ON import_mapping_decisions (staging_row_id);
CREATE INDEX imd_active_idx      ON import_mapping_decisions (target_table)
  WHERE superseded_at IS NULL;

COMMENT ON TABLE import_mapping_decisions IS
  'Human row-level pre-import mapping decisions. NOT an alias rule: a decision binds ONE source row (file, sheet, row) and says nothing about any other row carrying the same text. Append-only — a correction supersedes, never overwrites. Prompt 21 reads the ACTIVE decision (superseded_at IS NULL) and commits with its confirmed ids.';
COMMENT ON COLUMN import_mapping_decisions.source_row_key IS
  'Stable (file, sheet, row) identity. Carried so a decision survives a later dry run that re-stages the same source cells as new rows.';
COMMENT ON COLUMN import_mapping_decisions.source_evidence IS
  'What the human actually saw when deciding, captured at decision time. Raw source is never modified; this is a copy, not a replacement.';

ALTER TABLE import_mapping_decisions ENABLE ROW LEVEL SECURITY;
ALTER TABLE import_mapping_decisions FORCE ROW LEVEL SECURITY;

-- Read: admin and manager, matching `import_staging_rows_select`. Staging holds
-- unresolved raw source text and raw source text is never an authorization
-- boundary, so engineers and viewers get nothing here either.
CREATE POLICY imd_select ON import_mapping_decisions FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());

-- No INSERT, UPDATE or DELETE policy and no such grant: the SECURITY DEFINER
-- function below is the only writer. A decision cannot be forged, corrected in
-- place, or deleted through the API by anyone, admin included.
GRANT SELECT ON import_mapping_decisions TO authenticated;

-- ===========================================================================
-- 2. The decision function
-- ===========================================================================

/**
 * Record an admin's confirmed pre-import mapping for ONE staged row.
 *
 *   p_expected_decision_at  the `decided_at` of the ACTIVE decision the caller
 *                           believes exists, or NULL for "I believe there is
 *                           none". Either way a mismatch is refused, which is
 *                           both the stale-write guard and the duplicate guard:
 *                           two admins deciding the same row concurrently cannot
 *                           both succeed.
 *
 * The resulting status is DERIVED from what was actually confirmed. It is not a
 * parameter, so a caller cannot declare a row resolved by asserting it.
 */
CREATE FUNCTION cng_admin_decide_staged_mapping(
  p_staging_row_id uuid,
  p_station_id     uuid,
  p_unit_id        uuid DEFAULT NULL,
  p_expected_decision_at timestamptz DEFAULT NULL,
  p_reason         text DEFAULT NULL
)
RETURNS TABLE (decision_id uuid, resulting_mapping_status text, decided_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor    uuid := cng_require_admin();
  v_row      import_staging_rows%ROWTYPE;
  v_active   import_mapping_decisions%ROWTYPE;
  v_region   uuid;
  v_status   text;
  v_asset    asset_type;
  v_id       uuid;
  v_at       timestamptz;
BEGIN
  SELECT * INTO v_row FROM import_staging_rows WHERE id = p_staging_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'staging row not found' USING ERRCODE = '42704';
  END IF;

  v_asset := CASE v_row.target_table
    WHEN 'storage_vessels' THEN 'storage_vessel'::asset_type
    WHEN 'recovery_tanks'  THEN 'recovery_tank'
    WHEN 'gas_detectors'   THEN 'gas_detector'
    WHEN 'hoses'           THEN 'hose'
  END;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'this staged row is not a pre-import mappable asset (%)', v_row.target_table
      USING ERRCODE = '22023';
  END IF;

  -- A row that is already fully mapped, or that the pipeline rejected as
  -- structurally unusable, is not a mapping decision to make.
  IF v_row.mapping_status IS NULL OR v_row.mapping_status = 'resolved' THEN
    RAISE EXCEPTION 'this staged row needs no mapping decision' USING ERRCODE = '22023';
  END IF;
  IF v_row.outcome IN ('rejected', 'excluded', 'replayed') THEN
    RAISE EXCEPTION 'a % staging row is not committable and takes no mapping decision', v_row.outcome
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_active FROM import_mapping_decisions
   WHERE source_row_key = v_row.source_row_key AND superseded_at IS NULL;

  -- The concurrency and duplicate guard, in one comparison.
  PERFORM cng_check_precondition(v_active.decided_at, p_expected_decision_at);
  IF v_active.id IS NOT NULL AND p_expected_decision_at IS NULL THEN
    RAISE EXCEPTION 'stale_write: a decision already exists for this source row'
      USING ERRCODE = '40001';
  END IF;

  IF p_station_id IS NULL THEN
    RAISE EXCEPTION 'a Station must be confirmed' USING ERRCODE = '23514';
  END IF;
  SELECT region_id INTO v_region FROM stations WHERE id = p_station_id;
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'station not found' USING ERRCODE = '42704';
  END IF;

  v_status := CASE WHEN p_unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END;

  -- The new id is minted FIRST so the supersede can name its replacement in one
  -- statement. Writing `superseded_by = NULL` first would leave a row that says
  -- "superseded by nothing", which imd_superseded_shape_ck correctly refuses —
  -- and the partial unique index forbids simply inserting beside the old row.
  -- Both statements are in this function, so a failed insert rolls the supersede
  -- back and the previous decision stays active.
  v_id := gen_random_uuid();
  IF v_active.id IS NOT NULL THEN
    UPDATE import_mapping_decisions
       SET superseded_at = now(), superseded_by = v_id
     WHERE id = v_active.id;
  END IF;

  INSERT INTO import_mapping_decisions (
    id, staging_row_id, source_row_key, target_table, asset_type,
    region_id, confirmed_station_id, confirmed_unit_id,
    previous_mapping_status, resulting_mapping_status,
    decided_by, reason, source_evidence)
  VALUES (
    v_id, p_staging_row_id, v_row.source_row_key, v_row.target_table, v_asset,
    v_region, p_station_id, p_unit_id,
    v_row.mapping_status, v_status,
    v_actor, p_reason,
    -- A COPY of the evidence, taken now. The staging row is not touched.
    jsonb_build_object(
      'source_file', v_row.source_file, 'source_sheet', v_row.source_sheet,
      'source_row', v_row.source_row, 'source_raw', v_row.source_raw,
      'normalized', v_row.normalized, 'resolution', v_row.resolution,
      'staged_mapping_status', v_row.mapping_status))
  RETURNING import_mapping_decisions.decided_at INTO v_at;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('mapping_changed', 'import_mapping_decisions', v_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('%s %s: %s -> %s', v_row.target_table, v_row.source_row_key,
                 v_row.mapping_status, v_status),
          CASE WHEN v_active.id IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'superseded_decision_id', v_active.id,
                 'station_id', v_active.confirmed_station_id,
                 'unit_id', v_active.confirmed_unit_id,
                 'mapping_status', v_active.resulting_mapping_status) END,
          jsonb_build_object(
            'staging_row_id', p_staging_row_id, 'source_row_key', v_row.source_row_key,
            'asset_type', v_asset, 'station_id', p_station_id, 'unit_id', p_unit_id,
            'mapping_status', v_status));

  RETURN QUERY SELECT v_id, v_status, v_at;
END $$;

COMMENT ON FUNCTION cng_admin_decide_staged_mapping(uuid, uuid, uuid, timestamptz, text) IS
  'Admin-only. Records ONE confirmed pre-import mapping decision for one staged row. Status is DERIVED, the actor is server-derived, the hierarchy is enforced by imd_unit_station_fk, and raw source evidence is never written. A repeat decision supersedes; a stale or duplicate attempt raises 40001 and writes nothing.';

REVOKE ALL ON FUNCTION cng_admin_decide_staged_mapping(uuid, uuid, uuid, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_decide_staged_mapping(uuid, uuid, uuid, timestamptz, text) TO authenticated;

-- ===========================================================================
-- 3. The admin read surfaces
-- ===========================================================================

/**
 * The pre-import mapping queue: one row per unresolved staged asset, with the
 * source evidence a human needs, and the ACTIVE decision if one has been made.
 *
 * RAW, CANDIDATE and CONFIRMED are three separate column groups on purpose. A
 * UI that blurs them turns a similarity score into a fact.
 */
CREATE VIEW v_admin_staged_mapping_queue WITH (security_invoker = true) AS
SELECT
  s.id                AS staging_row_id,
  s.source_row_key,
  s.import_run_id,
  s.target_table,
  s.outcome,
  s.mapping_status    AS staged_mapping_status,
  s.updated_at,

  -- ---- RAW SOURCE (verbatim, never normalized) ----
  s.source_file, s.source_sheet, s.source_row,
  s.source_raw,
  s.normalized ->> 'region_raw'               AS raw_region,
  s.normalized ->> 'source_station_name_raw'  AS raw_station,
  s.normalized ->> 'location_raw'             AS raw_location,
  s.normalized ->> 'serial_number_raw'        AS raw_serial,
  s.normalized ->> 'manufacturer_raw'         AS raw_manufacturer,
  s.normalized ->> 'model_raw'                AS raw_model,

  -- ---- NORMALIZED (deterministic transformation of the above) ----
  s.normalized ->> 'region'         AS normalized_region,
  s.normalized ->> 'serial_number'  AS serial_number,
  s.normalized ->> 'manufacturer'   AS manufacturer,
  s.normalized ->> 'model'          AS model,

  -- ---- AUTOMATED CANDIDATE (a proposal; attaches nothing) ----
  s.resolution -> 'station' -> 'proposals'    AS candidate_proposals,
  s.resolution -> 'station' ->> 'kind'        AS candidate_kind,

  -- ---- CONFIRMED HUMAN DECISION (NULL until an admin makes one) ----
  d.id                    AS decision_id,
  d.confirmed_station_id,
  st.station_name         AS confirmed_station_name,
  d.confirmed_unit_id,
  un.unit_name            AS confirmed_unit_name,
  d.resulting_mapping_status AS confirmed_mapping_status,
  d.decided_by,
  au.full_name            AS decided_by_name,
  d.decided_at,
  d.reason                AS decision_reason
FROM import_staging_rows s
LEFT JOIN import_mapping_decisions d
       ON d.source_row_key = s.source_row_key AND d.superseded_at IS NULL
LEFT JOIN stations  st ON st.id = d.confirmed_station_id
LEFT JOIN units     un ON un.id = d.confirmed_unit_id
LEFT JOIN app_users au ON au.id = d.decided_by
WHERE s.target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
  AND s.mapping_status IS NOT NULL
  AND s.mapping_status <> 'resolved'
  AND s.outcome NOT IN ('rejected', 'excluded', 'replayed');

COMMENT ON VIEW v_admin_staged_mapping_queue IS
  'Pre-import mapping queue. RAW, CANDIDATE and CONFIRMED are separate column groups: a candidate proposal is never presented as a mapping. security_invoker, so import_staging_rows_select (admin/manager) decides visibility.';

GRANT SELECT ON v_admin_staged_mapping_queue TO authenticated;

/**
 * The data-quality summary, extended with the PRE-IMPORT queues.
 *
 * Replaced rather than added to, so one screen reads one source. Column names
 * and types are unchanged. Every count is still a live count — no figure from
 * the dry-run report is stored or displayed anywhere.
 */
CREATE OR REPLACE VIEW v_admin_data_quality AS
SELECT 'installed_relief_valve'::text AS asset, 'needs_station_mapping'::text AS queue,
       count(*)::bigint AS open_count
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_station_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'needs_unit_mapping', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_unit_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'needs_equipment_mapping', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_equipment_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'conflict', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'conflict'
UNION ALL
SELECT 'storage_vessel', 'unresolved', count(*)
  FROM storage_vessels WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'recovery_tank', 'unresolved', count(*)
  FROM recovery_tanks WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'gas_detector', 'unresolved', count(*)
  FROM gas_detectors WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'hose', 'unresolved', count(*)
  FROM hoses WHERE archived_at IS NULL AND mapping_status <> 'resolved'
-- Pre-import queues. `awaiting_decision` is a staged row no human has ruled on;
-- `decided` is one that is ready for Prompt 21 to commit.
UNION ALL
SELECT q.target_table, 'staged_awaiting_decision', count(*)
  FROM v_admin_staged_mapping_queue q WHERE q.decision_id IS NULL
 GROUP BY q.target_table
UNION ALL
SELECT q.target_table, 'staged_decided', count(*)
  FROM v_admin_staged_mapping_queue q WHERE q.decision_id IS NOT NULL
 GROUP BY q.target_table;

/**
 * What Prompt 21 reads.
 *
 * One row per staged row that an admin has ruled on, carrying the ids to commit
 * with. Prompt 21 never re-derives a Station: it either finds a row here or
 * leaves the staged record alone.
 */
CREATE VIEW v_import_confirmed_mappings WITH (security_invoker = true) AS
SELECT d.source_row_key, d.staging_row_id, d.target_table, d.asset_type,
       d.region_id, d.confirmed_station_id, d.confirmed_unit_id,
       d.resulting_mapping_status, d.decided_by, d.decided_at
  FROM import_mapping_decisions d
 WHERE d.superseded_at IS NULL;

COMMENT ON VIEW v_import_confirmed_mappings IS
  'The ACTIVE pre-import decisions, keyed by source_row_key. Prompt 21 joins staging rows to this and commits with confirmed_station_id / confirmed_unit_id. A row absent here stays staged; the commit never invents a Station.';

GRANT SELECT ON v_import_confirmed_mappings TO authenticated;
