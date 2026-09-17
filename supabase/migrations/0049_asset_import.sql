-- 0049_asset_import.sql
-- Canonical asset import for the Station-confirmed staged rows (Prompt 23A).
--
-- WHAT THIS IS. Stage B confirmed the canonical Station for 281 staged asset
-- rows. This turns those rows into canonical assets -- and NOTHING else. It
-- creates no Station, no Unit, no alias, no equipment parentage, and it never
-- touches the 823 rows whose Station is still unconfirmed.
--
-- ============================ UNIT STAYS NULL ===============================
-- A complete source-key census over the 281 rows proved there is NO Unit
-- evidence of any kind: `unit_id` is non-empty on 0 rows, and no unit name,
-- unit number, unit code or job number key exists anywhere in `normalized` or
-- `source_raw`. `Location` is an equipment KIND ("Recovery"/"Storage") which
-- CLAUDE.md section 4 states is not evidence of Unit membership, and a
-- compressor TYPE names no Unit instance.
--
-- So `unit_id` is not merely defaulted to NULL here -- it is STRUCTURALLY
-- unwritable: the four INSERT statements below name no `unit_id` column at all.
-- A caller cannot supply one, and no code path can infer one. "The Station has
-- exactly one Unit" is a fact about the HIERARCHY, not about the ASSET;
-- assigning 240 rows on that basis is the distribution rule section 4
-- permanently forbids.
--
-- The schema agrees, and is the reason no family is blocked:
--   *_needs_unit_ck  CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL)
-- `needs_unit_mapping` REQUIRES unit_id NULL. Station-level existence with an
-- unknown Unit is the shape the schema was built for, not a workaround.
--
-- ======================= NO IDENTITY IS INVENTED ============================
-- NONE of the four tables carries a UNIQUE constraint on `serial_number`, by
-- deliberate decision (Prompt 14): duplicates are REPORTED, never enforced
-- away, because six identical vessels at one Station may be six real devices
-- (data principle 16). This import therefore does NOT deduplicate. One staged
-- source row becomes exactly one canonical asset, and rows sharing a serial are
-- flagged as duplicate CANDIDATES for a human, never merged.
--
-- Replay is instead guarded per SOURCE ROW, using lineage that already exists:
-- `import_staging_rows.committed_entity_id` / `committed_at` /
-- `committed_entity_kind`, whose CHECK allowlist ALREADY contains
-- 'storage_vessel', 'recovery_tank', 'gas_detector' and 'hose'. No new table,
-- no new column, and no invented identity.
--
-- ================== RECORDED ABSENCE IS NOT A DEVICE ========================
-- 2 of the 64 detector rows carry `presence = 'not_installed'` with the
-- pipeline's own `creates_detector_record = false`: they are EVIDENCE THAT AN
-- AREA HAS NO DETECTOR. Creating a `gas_detectors` row for them would
-- manufacture a device the source explicitly says is absent. They are excluded
-- as `not_installed_evidence` and stay staging-only; they belong to
-- `gas_detector_presence`, a different table with a different contract, and
-- forcing them through this one is exactly what this exclusion prevents.
--
-- ============================ FOUR CONTRACTS ================================
-- The families do NOT share a schema and are not forced through one mapping:
--   storage_vessels / recovery_tanks : manufacturer, compressor_type_raw,
--                                      last_/next_inspection_*
--   gas_detectors                    : last_/next_calibration_*, no compressor
--   hoses                            : description, working/test pressure,
--                                      last_/next_test_*, dispenser_id
-- `area_type` is NOT written: it lives on `gas_detector_presence` and
-- classifies the AREA, never the detector (Prompt 13).
--
-- Date precision is not re-interpreted. The CHECK
--   (precision = 'exact_date') = (date IS NOT NULL)
-- is satisfied by construction: only an `exact_date` value becomes a real date;
-- every other precision stores NULL and keeps its raw text. Measured on this
-- run, the only precisions present are `exact_date` and `unknown`.
--
-- SECURITY. `service_role` only, matching Stage A: a canonical asset carries no
-- `created_by` column, so there is no actor to attribute and no reason to open
-- a browser path (the same reasoning as STAGEBSEC-14). The region-scoped
-- INSERT policies on these tables are the OPERATIONAL path for an engineer
-- creating one asset by hand; they are not the import path and are untouched.

-- ---------------------------------------------------------------------------
-- The single derivation. Preview, fingerprint and commit all read THIS, so
-- what is approved and what is written cannot be two code paths.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_asset_import_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id   uuid,
  source_row_key   text,
  source_row_hash  text,
  target_table     text,
  station_id       uuid,
  region_id        uuid,
  import_batch_id  uuid,
  eligibility      text,
  exclusion_reason text,
  identity_evidence text,
  warnings         text,
  payload          jsonb
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH dec AS MATERIALIZED (
    SELECT d.staging_row_id, d.confirmed_station_id, d.confirmed_unit_id,
           d.reviewed_source_row_hash
      FROM import_mapping_decisions d
     WHERE d.superseded_at IS NULL
  ),
  stn AS MATERIALIZED (
    SELECT s.id AS station_id, s.region_id FROM stations s
  ),
  base AS MATERIALIZED (
    SELECT r.id, r.source_row_key, r.source_row_hash, r.target_table,
           r.import_batch_id, r.normalized, r.source_raw, r.source_file,
           r.source_sheet, r.source_row, r.committed_entity_id,
           d.confirmed_station_id, d.confirmed_unit_id, d.reviewed_source_row_hash,
           st.region_id,
           nullif(trim(r.normalized ->> 'serial_number'), '') AS sn
      FROM import_staging_rows r
      JOIN dec d ON d.staging_row_id = r.id
      LEFT JOIN stn st ON st.station_id = d.confirmed_station_id
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
       AND r.outcome NOT IN ('rejected','excluded','replayed')
  ),
  dup AS (
    SELECT b.id,
           (SELECT count(*) FROM base b2
             WHERE b2.sn IS NOT NULL AND b2.sn = b.sn
               AND b2.target_table = b.target_table) AS n_same_serial
      FROM base b
  )
  SELECT
    b.id, b.source_row_key, b.source_row_hash, b.target_table,
    b.confirmed_station_id, b.region_id, b.import_batch_id,
    -- ELIGIBILITY. Every exclusion is a stated reason, never a silent drop.
    CASE
      WHEN b.committed_entity_id IS NOT NULL                       THEN 'D_ALREADY_IMPORTED'
      WHEN b.confirmed_station_id IS NULL OR b.region_id IS NULL   THEN 'C_NEEDS_REVIEW'
      WHEN b.confirmed_unit_id IS NOT NULL                         THEN 'C_NEEDS_REVIEW'
      WHEN b.reviewed_source_row_hash IS DISTINCT FROM b.source_row_hash THEN 'C_NEEDS_REVIEW'
      WHEN b.target_table = 'gas_detectors'
       AND coalesce(b.normalized ->> 'creates_detector_record','true') <> 'true'
                                                                    THEN 'E_BLOCKED_BY_TARGET'
      ELSE 'B_READY_NULL_UNIT'
    END,
    CASE
      WHEN b.committed_entity_id IS NOT NULL                       THEN 'staging row already carries canonical lineage'
      WHEN b.confirmed_station_id IS NULL OR b.region_id IS NULL   THEN 'no resolvable confirmed Station/Region'
      WHEN b.confirmed_unit_id IS NOT NULL                         THEN 'decision carries a Unit; this import writes no Unit'
      WHEN b.reviewed_source_row_hash IS DISTINCT FROM b.source_row_hash THEN 'source evidence changed since the Station decision'
      WHEN b.target_table = 'gas_detectors'
       AND coalesce(b.normalized ->> 'creates_detector_record','true') <> 'true'
                                                                    THEN 'not_installed_evidence: recorded ABSENCE of a detector, not a device'
      ELSE NULL
    END,
    CASE WHEN b.sn IS NOT NULL THEN 'serial_present' ELSE 'no_serial' END,
    CASE WHEN d.n_same_serial > 1
         THEN 'duplicate_serial_candidate: ' || d.n_same_serial::text ||
              ' rows in this family share this serial - REPORTED, not merged'
         ELSE NULL END,
    -- PAYLOAD. Built once, per family contract. Absent source value => NULL.
    jsonb_strip_nulls(jsonb_build_object(
      -- the STABLE (file, sheet, row) identity. It is real provenance, and it
      -- makes lineage exact: two rows sharing a serial AND every other value
      -- still differ here, so an asset can never be linked to the wrong row.
      'source_row_key',    b.source_row_key,
      'serial_number',     b.sn,
      'serial_number_raw', nullif(trim(b.normalized ->> 'serial_number_raw'), ''),
      'serial_status',     coalesce(nullif(trim(b.normalized ->> 'serial_status'), ''), 'unknown'),
      'manufacturer',      nullif(trim(b.normalized ->> 'manufacturer'), ''),
      'compressor_type_raw', nullif(trim(b.normalized ->> 'compressor_context_raw'), ''),
      'description',       nullif(trim(b.normalized ->> 'description'), ''),
      'source_status_raw', nullif(trim(b.normalized ->> 'source_status_raw'), ''),
      'notes',             nullif(trim(b.normalized ->> 'notes'), ''),
      'last_raw',          b.normalized -> 'last_calibration' ->> 'raw',
      'last_test_raw',     b.normalized -> 'last_test' ->> 'raw',
      'last_date', CASE WHEN b.normalized -> 'last_calibration' ->> 'precision' = 'exact_date'
                        THEN b.normalized -> 'last_calibration' ->> 'value' END,
      'last_test_date', CASE WHEN b.normalized -> 'last_test' ->> 'precision' = 'exact_date'
                        THEN b.normalized -> 'last_test' ->> 'value' END,
      'last_precision',  coalesce(b.normalized -> 'last_calibration' ->> 'precision', 'unknown'),
      'last_test_precision', coalesce(b.normalized -> 'last_test' ->> 'precision', 'unknown'),
      'next_raw',        b.normalized -> 'next_due_date' ->> 'raw',
      'next_date', CASE WHEN b.normalized -> 'next_due_date' ->> 'precision' = 'exact_date'
                        THEN b.normalized -> 'next_due_date' ->> 'value' END,
      'next_precision',  coalesce(b.normalized -> 'next_due_date' ->> 'precision', 'unknown'),
      'wp_raw',   b.normalized -> 'working_pressure' ->> 'raw',
      'wp_value', b.normalized -> 'working_pressure' ->> 'min',
      'wp_unit',  b.normalized -> 'working_pressure' ->> 'unit',
      'tp_raw',   b.normalized -> 'test_pressure' ->> 'raw',
      'tp_value', b.normalized -> 'test_pressure' ->> 'min',
      'tp_unit',  b.normalized -> 'test_pressure' ->> 'unit',
      'source_file',  b.source_file,
      'source_sheet', b.source_sheet,
      'source_row',   b.source_row
    ))
  FROM base b JOIN dup d ON d.id = b.id
  ORDER BY b.id;
$$;

COMMENT ON FUNCTION cng_asset_import_proposal(uuid) IS
  'Prompt 23A: the canonical asset proposal for Station-confirmed staged rows. '
  'Pure SELECT. Writes nothing, decides nothing, and carries NO unit column - '
  'Unit membership is unproven for every one of these rows. Recorded detector '
  'ABSENCE is excluded, and rows sharing a serial are flagged as duplicate '
  'candidates rather than merged.';

-- ---------------------------------------------------------------------------
-- Preview: the fingerprint an owner approval is bound to.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_asset_import_preview(p_import_run_id uuid)
RETURNS TABLE (
  import_run_id        uuid,
  manifest_fingerprint text,
  preview_fingerprint  text,
  eligible_rows        integer,
  excluded_rows        integer,
  storage_vessels      integer,
  recovery_tanks       integer,
  gas_detectors        integer,
  hoses                integer,
  already_imported     integer,
  needs_review         integer,
  blocked_by_target    integer,
  duplicate_serial_rows integer,
  distinct_stations    integer,
  rows_with_unit       integer,
  canonical_assets_now integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_asset_import_proposal(p_import_run_id)),
  e AS MATERIALIZED (SELECT * FROM p WHERE p.eligibility = 'B_READY_NULL_UNIT'),
  canon AS (
    SELECT string_agg(
             concat_ws(chr(31),
               e.staging_row_id::text, e.source_row_key, e.source_row_hash,
               e.target_table, e.station_id::text, e.region_id::text,
               'unit:NULL', e.eligibility, e.payload::text),
             chr(30) ORDER BY e.staging_row_id) AS blob
      FROM e
  )
  SELECT
    p_import_run_id,
    (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = p_import_run_id),
    encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM e),
    (SELECT count(*)::integer FROM p WHERE p.eligibility <> 'B_READY_NULL_UNIT'),
    (SELECT count(*)::integer FROM e WHERE e.target_table='storage_vessels'),
    (SELECT count(*)::integer FROM e WHERE e.target_table='recovery_tanks'),
    (SELECT count(*)::integer FROM e WHERE e.target_table='gas_detectors'),
    (SELECT count(*)::integer FROM e WHERE e.target_table='hoses'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility='D_ALREADY_IMPORTED'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility='C_NEEDS_REVIEW'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility='E_BLOCKED_BY_TARGET'),
    (SELECT count(*)::integer FROM e WHERE e.warnings IS NOT NULL),
    (SELECT count(DISTINCT e.station_id)::integer FROM e),
    (SELECT count(*)::integer FROM import_mapping_decisions
      WHERE superseded_at IS NULL AND confirmed_unit_id IS NOT NULL),
    (SELECT (SELECT count(*) FROM storage_vessels)+(SELECT count(*) FROM recovery_tanks)
          + (SELECT count(*) FROM gas_detectors)+(SELECT count(*) FROM hoses))::integer;
$$;

COMMENT ON FUNCTION cng_asset_import_preview(uuid) IS
  'Prompt 23A: the content fingerprint and counts an owner approval is bound '
  'to. Read-only. The fingerprint covers, per eligible row, the staging row id, '
  'source key and hash, family, Station, Region, the literal NULL Unit state '
  'and the full proposed payload - so the approval lapses if any of them moves.';

-- ---------------------------------------------------------------------------
-- Commit. One transaction, four literal targets, no dynamic SQL, no unit.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_asset_import_commit(
  p_import_run_id                uuid,
  p_expected_manifest_fingerprint text,
  p_expected_preview_fingerprint  text,
  p_reason                        text
)
RETURNS TABLE (
  import_run_id      uuid,
  assets_created     integer,
  storage_vessels    integer,
  recovery_tanks     integer,
  gas_detectors      integer,
  hoses              integer,
  rows_linked        integer,
  preview_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_manifest text;
  v_preview  text;
  v_now      timestamptz := now();
  v_sv int := 0; v_rt int := 0; v_gd int := 0; v_ho int := 0; v_linked int := 0;
  v_bad int;
BEGIN
  -- Gate 1: an approval must be PRESENTED. There is no "approve whatever is
  -- current" path that could drift between preview and commit.
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint),'') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint),'')  = '' THEN
    RAISE EXCEPTION 'Asset import requires an explicit import run and both approval fingerprints'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 2: the run must exist and be completed.
  IF NOT EXISTS (SELECT 1 FROM import_runs WHERE id = p_import_run_id) THEN
    RAISE EXCEPTION 'Asset import: import run % does not exist', p_import_run_id
      USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM import_runs WHERE id = p_import_run_id AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Asset import: import run % is not completed', p_import_run_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 3+4: both fingerprints RE-DERIVED inside this transaction.
  SELECT pv.manifest_fingerprint, pv.preview_fingerprint
    INTO v_manifest, v_preview
    FROM cng_asset_import_preview(p_import_run_id) pv;

  IF v_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Asset import refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Asset import refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_preview
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 5: nothing to do is a REFUSAL, not a silent success.
  IF NOT EXISTS (SELECT 1 FROM cng_asset_import_proposal(p_import_run_id)
                  WHERE eligibility = 'B_READY_NULL_UNIT') THEN
    RAISE EXCEPTION 'Asset import refused: run % has no eligible rows (already imported, or none qualify)',
      p_import_run_id USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 6: defence in depth. No eligible row may carry a Unit, and every one
  -- must still be backed by an active decision whose reviewed hash matches.
  SELECT count(*) INTO v_bad
    FROM cng_asset_import_proposal(p_import_run_id) pr
    JOIN import_staging_rows r ON r.id = pr.staging_row_id
   WHERE pr.eligibility = 'B_READY_NULL_UNIT'
     AND NOT EXISTS (
       SELECT 1 FROM import_mapping_decisions d
        WHERE d.staging_row_id = r.id
          AND d.superseded_at IS NULL
          AND d.confirmed_unit_id IS NULL
          AND d.confirmed_station_id = pr.station_id
          AND d.reviewed_source_row_hash = r.source_row_hash);
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'Asset import refused: % eligible rows lack a matching active Station decision', v_bad
      USING ERRCODE = 'check_violation';
  END IF;

  CREATE TEMP TABLE _cng_asset_commit ON COMMIT DROP AS
    SELECT * FROM cng_asset_import_proposal(p_import_run_id)
     WHERE eligibility = 'B_READY_NULL_UNIT';

  -- THE CANONICAL FIREWALL IS THE BODY. Four INSERTs, four literal targets, no
  -- dynamic SQL -- `target_table` is DATA in a column and can never name a
  -- destination. NONE of the four names `unit_id`, so a Unit is not writable.
  WITH ins AS (
    INSERT INTO storage_vessels (
      station_id, region_id, mapping_status, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status, compressor_type_raw,
      last_inspection_raw, last_inspection_date, last_inspection_precision,
      next_inspection_raw, next_inspection_date, next_inspection_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet,
      source_row, source_raw)
    SELECT c.station_id, c.region_id, 'needs_unit_mapping'::asset_mapping_status,
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw',
           (c.payload->>'serial_status')::serial_status,
           c.payload->>'compressor_type_raw',
           c.payload->>'last_raw', (c.payload->>'last_date')::date,
           (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date,
           (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet',
           (c.payload->>'source_row')::int, c.payload
      FROM _cng_asset_commit c WHERE c.target_table = 'storage_vessels'
    RETURNING 1)
  SELECT count(*)::int INTO v_sv FROM ins;

  WITH ins AS (
    INSERT INTO recovery_tanks (
      station_id, region_id, mapping_status, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status, compressor_type_raw,
      last_inspection_raw, last_inspection_date, last_inspection_precision,
      next_inspection_raw, next_inspection_date, next_inspection_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet,
      source_row, source_raw)
    SELECT c.station_id, c.region_id, 'needs_unit_mapping'::asset_mapping_status,
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw',
           (c.payload->>'serial_status')::serial_status,
           c.payload->>'compressor_type_raw',
           c.payload->>'last_raw', (c.payload->>'last_date')::date,
           (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date,
           (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet',
           (c.payload->>'source_row')::int, c.payload
      FROM _cng_asset_commit c WHERE c.target_table = 'recovery_tanks'
    RETURNING 1)
  SELECT count(*)::int INTO v_rt FROM ins;

  WITH ins AS (
    INSERT INTO gas_detectors (
      station_id, region_id, mapping_status, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status,
      last_calibration_raw, last_calibration_date, last_calibration_precision,
      next_calibration_raw, next_calibration_date, next_calibration_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet,
      source_row, source_raw)
    SELECT c.station_id, c.region_id, 'needs_unit_mapping'::asset_mapping_status,
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw',
           (c.payload->>'serial_status')::serial_status,
           c.payload->>'last_raw', (c.payload->>'last_date')::date,
           (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date,
           (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet',
           (c.payload->>'source_row')::int, c.payload
      FROM _cng_asset_commit c WHERE c.target_table = 'gas_detectors'
    RETURNING 1)
  SELECT count(*)::int INTO v_gd FROM ins;

  WITH ins AS (
    INSERT INTO hoses (
      station_id, region_id, mapping_status, description,
      serial_number, serial_number_raw, serial_status,
      working_pressure_raw, working_pressure_value, working_pressure_unit,
      test_pressure_raw, test_pressure_value, test_pressure_unit,
      last_test_raw, last_test_date, last_test_precision,
      next_test_raw, next_test_date, next_test_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet,
      source_row, source_raw)
    SELECT c.station_id, c.region_id, 'needs_unit_mapping'::asset_mapping_status,
           c.payload->>'description',
           c.payload->>'serial_number', c.payload->>'serial_number_raw',
           (c.payload->>'serial_status')::serial_status,
           c.payload->>'wp_raw', (c.payload->>'wp_value')::numeric,
           (c.payload->>'wp_unit')::pressure_unit,
           c.payload->>'tp_raw', (c.payload->>'tp_value')::numeric,
           (c.payload->>'tp_unit')::pressure_unit,
           c.payload->>'last_test_raw', (c.payload->>'last_test_date')::date,
           (c.payload->>'last_test_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date,
           (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet',
           (c.payload->>'source_row')::int, c.payload
      FROM _cng_asset_commit c WHERE c.target_table = 'hoses'
    RETURNING 1)
  SELECT count(*)::int INTO v_ho FROM ins;

  -- LINEAGE. Each staged row points at the asset it became. Stage A's own
  -- lineage is untouched: those 402 structural rows are a disjoint set and
  -- keep their 'station'/'unit' kinds.
  WITH linked AS (
    UPDATE import_staging_rows r
       SET committed_entity_id = a.asset_id,
           committed_entity_kind = a.kind,
           committed_at = v_now,
           updated_at = v_now
      FROM (
        SELECT c.staging_row_id, x.asset_id, x.kind
          FROM _cng_asset_commit c
          JOIN LATERAL (
            SELECT sv.id AS asset_id, 'storage_vessel' AS kind FROM storage_vessels sv
             WHERE sv.source_raw->>'source_row_key' = c.source_row_key
               AND c.target_table='storage_vessels'
            UNION ALL
            SELECT rt.id, 'recovery_tank' FROM recovery_tanks rt
             WHERE rt.source_raw->>'source_row_key' = c.source_row_key
               AND c.target_table='recovery_tanks'
            UNION ALL
            SELECT gd.id, 'gas_detector' FROM gas_detectors gd
             WHERE gd.source_raw->>'source_row_key' = c.source_row_key
               AND c.target_table='gas_detectors'
            UNION ALL
            SELECT h.id, 'hose' FROM hoses h
             WHERE h.source_raw->>'source_row_key' = c.source_row_key
               AND c.target_table='hoses'
          ) x ON true
      ) a
     WHERE r.id = a.staging_row_id
    RETURNING 1)
  SELECT count(*)::int INTO v_linked FROM linked;

  IF v_linked <> (v_sv + v_rt + v_gd + v_ho) THEN
    RAISE EXCEPTION 'Asset import refused: lineage does not reconcile (% assets, % rows linked)',
      v_sv + v_rt + v_gd + v_ho, v_linked USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'import_runs', p_import_run_id, NULL, 'service_role:asset_import',
          format('Canonical asset import: %s assets (%s storage vessels, %s recovery tanks, %s gas detectors, %s hoses), Unit NULL on all. %s',
                 v_sv+v_rt+v_gd+v_ho, v_sv, v_rt, v_gd, v_ho, coalesce(p_reason,'')),
          NULL, jsonb_build_object('preview_fingerprint', v_preview,
                                   'assets_created', v_sv+v_rt+v_gd+v_ho),
          v_now);

  RETURN QUERY SELECT p_import_run_id, (v_sv+v_rt+v_gd+v_ho)::int,
                      v_sv, v_rt, v_gd, v_ho, v_linked, v_preview;
END;
$$;

COMMENT ON FUNCTION cng_asset_import_commit(uuid, text, text, text) IS
  'Prompt 23A: commits Station-confirmed staged rows into canonical assets in '
  'ONE transaction. Four literal INSERT targets, no dynamic SQL, and NO unit_id '
  'column in any of them - Unit is structurally unwritable. Refuses on a missing '
  'or drifted approval, an uncommitted run, a lapsed Station decision, a changed '
  'source hash, replay, or lineage that does not reconcile.';

REVOKE ALL ON FUNCTION cng_asset_import_proposal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_asset_import_proposal(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_asset_import_proposal(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_asset_import_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_asset_import_preview(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_asset_import_preview(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_asset_import_commit(uuid, text, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_asset_import_commit(uuid, text, text, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_asset_import_commit(uuid, text, text, text) TO service_role;
