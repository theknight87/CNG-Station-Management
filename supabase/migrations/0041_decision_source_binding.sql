-- ---------------------------------------------------------------------------
-- 0041 — Bind a mapping decision to the source CONTENT it was made from
--        (Prompt 19B). Additive, and it corrects a real defect in 0039.
--
-- THE DEFECT.
--
--   0039 keyed a human decision on `source_row_key` alone — the stable
--   (file, sheet, row) identity. That identifies WHERE the row was, not WHAT
--   the administrator read. A workbook is a live document: rows get inserted,
--   deleted, re-ordered and overwritten. If `V.xlsx#Sheet1#11` later holds a
--   DIFFERENT vessel, the old decision would have matched by key and a later
--   dry run would have silently attached last month's Station to this month's
--   asset — a fabricated physical relationship, arrived at without anyone
--   guessing, which is exactly what data principle #8 exists to prevent.
--
--   `import_staging_rows.source_row_hash` already existed and already changes
--   when a row's CONTENT changes. It was simply never recorded on the decision.
--
-- THE FIX.
--
--   A decision now records `reviewed_source_row_hash`, captured SERVER-SIDE
--   from the staging row it was made against. Reuse requires BOTH halves to
--   match:
--
--       decision.source_row_key           = staged.source_row_key
--   AND decision.reviewed_source_row_hash = staged.source_row_hash
--
--   Key matches, hash differs => the decision is STALE-SOURCE. It is not
--   applied, it is not silently downgraded to "no decision", and its old
--   Station/Unit are never injected. It is surfaced as a distinct state so an
--   administrator can see WHY a previous ruling stopped counting, review the
--   new evidence, and supersede it through the ordinary audited path.
--
--   The browser cannot supply the hash. It is not a parameter of any function.
-- ---------------------------------------------------------------------------

-- Added nullable, backfilled from the staging row, then made NOT NULL. The
-- table is empty everywhere today, but a migration that silently succeeds on an
-- empty table and would fail on a populated one is not a migration anyone
-- should trust.
ALTER TABLE import_mapping_decisions
  ADD COLUMN reviewed_source_row_hash text NULL;

UPDATE import_mapping_decisions d
   SET reviewed_source_row_hash = s.source_row_hash
  FROM import_staging_rows s
 WHERE s.id = d.staging_row_id
   AND d.reviewed_source_row_hash IS NULL;

ALTER TABLE import_mapping_decisions
  ALTER COLUMN reviewed_source_row_hash SET NOT NULL;

COMMENT ON COLUMN import_mapping_decisions.reviewed_source_row_hash IS
  'The source_row_hash of the staging row this decision was made FROM, captured server-side. Reuse requires source_row_key AND this hash to match: the key says where the row was, the hash says what it said. A key match with a hash mismatch is a STALE-SOURCE decision and is never applied.';

-- ---------------------------------------------------------------------------
-- The decision function now captures the hash it reviewed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_admin_decide_staged_mapping(
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

  IF v_row.mapping_status IS NULL OR v_row.mapping_status = 'resolved' THEN
    RAISE EXCEPTION 'this staged row needs no mapping decision' USING ERRCODE = '22023';
  END IF;
  IF v_row.outcome IN ('rejected', 'excluded', 'replayed') THEN
    RAISE EXCEPTION 'a % staging row is not committable and takes no mapping decision', v_row.outcome
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_active FROM import_mapping_decisions
   WHERE source_row_key = v_row.source_row_key AND superseded_at IS NULL;

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

  v_id := gen_random_uuid();
  IF v_active.id IS NOT NULL THEN
    UPDATE import_mapping_decisions
       SET superseded_at = now(), superseded_by = v_id
     WHERE id = v_active.id;
  END IF;

  INSERT INTO import_mapping_decisions (
    id, staging_row_id, source_row_key, reviewed_source_row_hash,
    target_table, asset_type,
    region_id, confirmed_station_id, confirmed_unit_id,
    previous_mapping_status, resulting_mapping_status,
    decided_by, reason, source_evidence)
  VALUES (
    v_id, p_staging_row_id, v_row.source_row_key,
    -- SERVER-SIDE, from the row the admin actually had in front of them. There
    -- is no parameter for this and there must never be one: a caller that could
    -- name the hash could claim to have reviewed evidence it never saw.
    v_row.source_row_hash,
    v_row.target_table, v_asset,
    v_region, p_station_id, p_unit_id,
    v_row.mapping_status, v_status,
    v_actor, p_reason,
    jsonb_build_object(
      'source_file', v_row.source_file, 'source_sheet', v_row.source_sheet,
      'source_row', v_row.source_row, 'source_raw', v_row.source_raw,
      'source_row_hash', v_row.source_row_hash,
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
                 'reviewed_source_row_hash', v_active.reviewed_source_row_hash,
                 'mapping_status', v_active.resulting_mapping_status) END,
          jsonb_build_object(
            'staging_row_id', p_staging_row_id, 'source_row_key', v_row.source_row_key,
            'reviewed_source_row_hash', v_row.source_row_hash,
            'asset_type', v_asset, 'station_id', p_station_id, 'unit_id', p_unit_id,
            'mapping_status', v_status));

  RETURN QUERY SELECT v_id, v_status, v_at;
END $$;

COMMENT ON FUNCTION cng_admin_decide_staged_mapping(uuid, uuid, uuid, timestamptz, text) IS
  'Admin-only. Records ONE confirmed pre-import mapping decision for one staged row, binding it to BOTH the source row key and the source_row_hash it was reviewed against — both captured server-side. Status is DERIVED, the hierarchy is enforced by imd_unit_station_fk, and raw source evidence is never written. A repeat decision supersedes; a stale or duplicate attempt raises 40001 and writes nothing.';

-- ---------------------------------------------------------------------------
-- The queue view: a stale-source decision is SHOWN, and shown as stale.
--
-- The join is still on `source_row_key` alone, deliberately. Joining on the
-- hash too would make a stale decision vanish, and the administrator would be
-- asked to decide a row they have already ruled on with no idea why their
-- ruling stopped counting. It is surfaced instead, with the reason.
-- ---------------------------------------------------------------------------
-- `WITH (security_invoker = true)` is repeated deliberately. CREATE OR REPLACE
-- VIEW does NOT preserve reloptions: replacing a view without restating the
-- option silently resets it to false, and the view then runs as its OWNER,
-- bypassing every RLS policy that was meant to bound it. Migration 0039 lost
-- the option on v_admin_data_quality exactly this way; see the repair below.
CREATE OR REPLACE VIEW v_admin_staged_mapping_queue
WITH (security_invoker = true) AS
SELECT
  s.id                AS staging_row_id,
  s.source_row_key,
  s.import_run_id,
  s.target_table,
  s.outcome,
  s.mapping_status    AS staged_mapping_status,
  s.updated_at,

  s.source_file, s.source_sheet, s.source_row,
  s.source_raw,
  s.normalized ->> 'region_raw'               AS raw_region,
  s.normalized ->> 'source_station_name_raw'  AS raw_station,
  s.normalized ->> 'location_raw'             AS raw_location,
  s.normalized ->> 'serial_number_raw'        AS raw_serial,
  s.normalized ->> 'manufacturer_raw'         AS raw_manufacturer,
  s.normalized ->> 'model_raw'                AS raw_model,

  s.normalized ->> 'region'         AS normalized_region,
  s.normalized ->> 'serial_number'  AS serial_number,
  s.normalized ->> 'manufacturer'   AS manufacturer,
  s.normalized ->> 'model'          AS model,

  s.resolution -> 'station' -> 'proposals'    AS candidate_proposals,
  s.resolution -> 'station' ->> 'kind'        AS candidate_kind,

  d.id                    AS decision_id,
  d.confirmed_station_id,
  st.station_name         AS confirmed_station_name,
  d.confirmed_unit_id,
  un.unit_name            AS confirmed_unit_name,
  d.resulting_mapping_status AS confirmed_mapping_status,
  d.decided_by,
  au.full_name            AS decided_by_name,
  d.decided_at,
  d.reason                AS decision_reason,

  -- Appended in 0041. CREATE OR REPLACE requires the existing columns to keep
  -- their names, types and order, so the new ones go at the end.
  s.source_row_hash,
  d.reviewed_source_row_hash,
  -- TRUE when a decision exists but was made against DIFFERENT source content.
  -- Never NULL-versus-false confusion: no decision means no staleness question.
  (d.id IS NOT NULL AND d.reviewed_source_row_hash IS DISTINCT FROM s.source_row_hash)
                          AS decision_is_stale_source
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
  'Pre-import mapping queue. RAW, CANDIDATE and CONFIRMED are separate column groups, and `decision_is_stale_source` marks a previous ruling made against source content that has since changed — shown, never silently applied and never silently dropped. security_invoker.';

-- ---------------------------------------------------------------------------
-- What Prompt 21 reads.
--
-- The hash is exposed so the planner can verify it. The view does NOT pre-join
-- to staging: it is a list of decisions, and whether one APPLIES to a given
-- staged row is a question the planner answers per row, against the run it is
-- actually planning.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_import_confirmed_mappings
WITH (security_invoker = true) AS
SELECT d.source_row_key, d.staging_row_id, d.target_table, d.asset_type,
       d.region_id, d.confirmed_station_id, d.confirmed_unit_id,
       d.resulting_mapping_status, d.decided_by, d.decided_at,
       d.reviewed_source_row_hash
  FROM import_mapping_decisions d
 WHERE d.superseded_at IS NULL;

COMMENT ON VIEW v_import_confirmed_mappings IS
  'The ACTIVE pre-import decisions. Prompt 21 matches a staged row on source_row_key AND source_row_hash = reviewed_source_row_hash; a key-only match is a STALE-SOURCE decision and is held for human re-review, never applied.';

-- ---------------------------------------------------------------------------
-- Data-quality counts: a stale-source decision is its own queue, because it is
-- neither "awaiting a decision" nor "decided". Rolling it into either would
-- hide the reason a previous ruling stopped counting.
-- ---------------------------------------------------------------------------
-- REPAIR. 0038 created this view `security_invoker`; 0039 replaced it WITHOUT
-- restating the option, so it has been running as its owner ever since —
-- meaning an engineer or viewer could read Region-wide counts that RLS was
-- supposed to bound. The grant was never the protection; the invoker setting
-- was. Restated here, and asserted in the suite so it cannot lapse again.
CREATE OR REPLACE VIEW v_admin_data_quality
WITH (security_invoker = true) AS
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
UNION ALL
SELECT q.target_table, 'staged_awaiting_decision', count(*)
  FROM v_admin_staged_mapping_queue q WHERE q.decision_id IS NULL
 GROUP BY q.target_table
UNION ALL
SELECT q.target_table, 'staged_decided', count(*)
  FROM v_admin_staged_mapping_queue q
 WHERE q.decision_id IS NOT NULL AND NOT q.decision_is_stale_source
 GROUP BY q.target_table
UNION ALL
SELECT q.target_table, 'staged_stale_source_decision', count(*)
  FROM v_admin_staged_mapping_queue q WHERE q.decision_is_stale_source
 GROUP BY q.target_table;
