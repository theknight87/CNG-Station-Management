-- 0051_installed_srv_import.sql
-- Canonical import for the staged INSTALLED relief valves (Prompt 25D).
--
-- ADDS NO TABLE, NO COLUMN, NO ENUM, NO CONSTRAINT AND NO INDEX. Everything
-- needed already exists: `installed_relief_valves` carries every technical
-- column plus `source_raw`/`source_file`/`source_sheet`/`source_row` for
-- provenance, and `import_staging_rows.committed_entity_kind` ALREADY allows
-- `installed_relief_valve`. Only the WRITER was missing.
--
-- ============================ THE CONSERVATIVE RULE ==========================
--
-- ALL 2,662 staged installed SRVs are created with:
--
--     station_id = NULL · unit_id = NULL · compressor_id = NULL
--     storage_vessel_id = NULL · dispenser_id = NULL
--     mapping_status = 'needs_station_mapping'
--
-- regardless of the historical staged status, and THAT IS THE POINT.
--
-- WHY THE STAGED STATUS IS NOT CANONICAL TRUTH (Prompt 25C, owner-ruled):
--
--   * The staged `station_id`/`unit_id` values on 1,063 rows are 32-character
--     hex SYNTHETIC keys minted by the dry run BEFORE Stage A existed. NONE of
--     them is a canonical id: 0 of 1,063 exist in `stations`, 0 of 801 in
--     `units`. They are not foreign keys and are never treated as ones here.
--
--   * The 801 `needs_equipment_mapping` rows state their own reason:
--     "station has exactly one unit, so the unit is proven". That is the
--     inference CLAUDE.md section 4 permanently forbids and that Prompts 21D,
--     22C and 22D each refused -- the Station's Unit count is a fact about the
--     HIERARCHY, never about the valve. It is not adopted here.
--
--   * The 262 `needs_unit_mapping` rows rest on pipeline-era name resolution
--     with NO human decision, and 224 of them name a Station that is not in the
--     canonical hierarchy at all.
--
-- `irv_status_shape_ck` independently agrees: it REJECTS `needs_unit_mapping`
-- without a Station and `needs_equipment_mapping` without a Station and Unit,
-- proved by attempted insert. So the conservative status is not merely the
-- careful choice -- for 1,063 rows it is the only expressible one.
--
-- NOTHING IS DISCARDED. The historical staged status, the pipeline's own
-- resolution reason, the synthetic identifiers, `source_row_key`,
-- `source_row_hash` and the untouched raw cells all travel into `source_raw` as
-- TEXT/JSON provenance, so the ruling is auditable and reversible by evidence.
-- They are PROVENANCE, never FKs.
--
-- STATION/UNIT/EQUIPMENT CONFIRMATION IS A SEPARATE, EXISTING ADMIN ACTION:
-- `cng_admin_map_srv` (Prompt 19), admin-gated, row-version guarded, audited.
-- This import deliberately creates none of it.
--
-- SECURITY follows 0049 exactly: `service_role` ONLY, because a canonical SRV
-- carries no `created_by` contract and there is no human actor to attribute.
-- The commit is SECURITY DEFINER with a pinned search_path; the two read paths
-- are deliberately NOT definer. No dynamic SQL. ONE literal INSERT target.

-- ---------------------------------------------------------------------------
-- PROPOSAL — one row per staged installed SRV, with its eligibility and the
-- exact canonical payload. Read-only and STABLE, so it cannot write.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_import_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id   uuid,
  source_row_key   text,
  source_row_hash  text,
  region_id        uuid,
  eligibility      text,
  payload          jsonb
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH staged AS MATERIALIZED (
    SELECT r.id, r.source_row_key, r.source_row_hash, r.import_batch_id,
           r.source_file, r.source_sheet, r.source_row, r.source_raw,
           r.normalized AS n, r.resolution AS res,
           r.mapping_status AS staged_status,
           r.committed_entity_id,
           (SELECT g.id FROM regions g WHERE g.name = r.normalized ->> 'region') AS rid
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table = 'installed_relief_valves'
       AND r.outcome NOT IN ('rejected', 'excluded', 'replayed')
  )
  SELECT
    s.id, s.source_row_key, s.source_row_hash, s.rid,
    CASE
      WHEN s.committed_entity_id IS NOT NULL             THEN 'D_ALREADY_IMPORTED'
      WHEN s.source_row_hash IS NULL
        OR length(s.source_row_hash) <> 64               THEN 'C_INVALID_EVIDENCE'
      WHEN s.rid IS NULL                                 THEN 'C_INVALID_EVIDENCE'
      WHEN coalesce(btrim(s.n ->> 'source_station_name_raw'), '') = ''
                                                         THEN 'C_INVALID_EVIDENCE'
      ELSE 'A_READY_UNRESOLVED'
    END,
    jsonb_strip_nulls(jsonb_build_object(
      -- provenance / lineage
      'source_row_key',  s.source_row_key,
      'source_row_hash', s.source_row_hash,
      'import_run_id',   p_import_run_id::text,
      'source_file',     s.source_file,
      'source_sheet',    s.source_sheet,
      'source_row',      s.source_row,
      'source_raw',      s.source_raw,
      -- HISTORICAL staging evidence, kept as TEXT/JSON and never as an FK
      'historical', jsonb_build_object(
        'staged_mapping_status', s.staged_status,
        'pipeline_reason',       CASE WHEN jsonb_typeof(s.res -> 'mapping') = 'string'
                                      THEN s.res ->> 'mapping' END,
        'synthetic_station_id',  s.n ->> 'station_id',
        'synthetic_unit_id',     s.n ->> 'unit_id',
        'note', 'Historical staging values only. The synthetic identifiers are '
             || 'dry-run internals that exist in no canonical table and are NEVER '
             || 'foreign keys. Canonical Station/Unit/equipment confirmation is a '
             || 'separate admin action (cng_admin_map_srv).'),
      -- Region is stated by the source and is NOT a Station.
      'region',                  s.n ->> 'region',
      'source_region_raw',       s.n ->> 'region_raw',
      'source_station_name_raw', s.n ->> 'source_station_name_raw',
      -- hints, preserved verbatim per section 4; they never select an FK
      'location_raw',            s.n ->> 'location_raw',
      'expected_parent_kind',    s.n ->> 'expected_parent_kind',
      -- direct technical evidence
      'manufacturer',       s.n ->> 'manufacturer',
      'serial_number',      s.n ->> 'serial_number',
      'serial_number_raw',  s.n ->> 'serial_number_raw',
      'serial_status',      s.n ->> 'serial_status',
      'part_number',        s.n ->> 'part_number',
      'size_type',          s.n ->> 'size_type',
      'inlet_size',         s.n ->> 'port_in',
      'outlet_size',        s.n ->> 'port_out',
      'set_pressure_raw',   s.n -> 'set_pressure' ->> 'raw',
      'pressure_min',       s.n -> 'set_pressure' ->> 'min',
      'pressure_max',       s.n -> 'set_pressure' ->> 'max',
      'pressure_unit',      s.n -> 'set_pressure' ->> 'unit',
      -- DATES: a date value EXISTS only at exact_date precision. Any other
      -- precision keeps its raw text and stores NULL, which irv_last_prec_ck /
      -- irv_next_prec_ck independently enforce.
      'last_raw',        s.n -> 'last_calibration' ->> 'raw',
      'last_precision',  coalesce(s.n -> 'last_calibration' ->> 'precision', 'unknown'),
      'last_date',       CASE WHEN s.n -> 'last_calibration' ->> 'precision' = 'exact_date'
                              THEN s.n -> 'last_calibration' ->> 'value' END,
      'next_raw',        s.n -> 'next_due_date' ->> 'raw',
      'next_precision',  coalesce(s.n -> 'next_due_date' ->> 'precision', 'unknown'),
      'next_date',       CASE WHEN s.n -> 'next_due_date' ->> 'precision' = 'exact_date'
                              THEN s.n -> 'next_due_date' ->> 'value' END,
      'source_status_raw', coalesce(s.n -> 'next_due_date' ->> 'sourceStatusRaw',
                                    s.n -> 'last_calibration' ->> 'sourceStatusRaw'),
      'notes',             s.n ->> 'notes',
      -- the canonical conclusion, stated explicitly so the fingerprint binds it
      'canonical_mapping_status', 'needs_station_mapping',
      'canonical_station_id',     NULL::text,
      'canonical_unit_id',        NULL::text,
      'canonical_equipment_id',   NULL::text
    ))
    FROM staged s
   ORDER BY s.source_row_key;
$$;

COMMENT ON FUNCTION cng_irv_import_proposal(uuid) IS
  'Per-row canonical proposal for staged installed SRVs. Every eligible row is proposed as '
  'needs_station_mapping with Station, Unit and all equipment parents NULL, whatever the '
  'historical staged status said. The historical status, the pipeline reason and the dry-run '
  'synthetic identifiers travel into source_raw as provenance TEXT/JSON and are never foreign '
  'keys. No Station-name match, no one-Unit inference, no Location/expected_parent_kind use.';

-- ---------------------------------------------------------------------------
-- PREVIEW — counts plus the deterministic fingerprint. Zero writes.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_import_preview(p_import_run_id uuid)
RETURNS TABLE (
  import_run_id         uuid,
  manifest_fingerprint  text,
  preview_fingerprint   text,
  eligible_rows         integer,
  excluded_rows         integer,
  already_imported      integer,
  invalid_evidence      integer,
  proposed_needs_station integer,
  proposed_needs_unit   integer,
  proposed_needs_equipment integer,
  proposed_resolved     integer,
  rows_with_station_fk  integer,
  rows_with_unit_fk     integer,
  rows_with_equipment_fk integer,
  distinct_source_keys  integer,
  distinct_source_hashes integer,
  repeated_hash_groups  integer,
  duplicate_source_keys integer,
  invalid_hashes        integer,
  hist_needs_station    integer,
  hist_needs_unit       integer,
  hist_needs_equipment  integer,
  rows_with_serial      integer,
  rows_with_exact_next_date integer,
  distinct_regions      integer,
  canonical_irv_now     integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_irv_import_proposal(p_import_run_id)),
  e AS MATERIALIZED (SELECT * FROM p WHERE p.eligibility = 'A_READY_UNRESOLVED'),
  canon AS (
    -- Binds the COMPLETE proposed set: identity, integrity evidence, the
    -- canonical conclusion (status and three explicit NULL FKs) and every
    -- technical value, because `payload` carries them all.
    SELECT string_agg(
             concat_ws(chr(31),
               p_import_run_id::text,
               coalesce((SELECT run.summary ->> 'manifest_fingerprint'
                           FROM import_runs run WHERE run.id = p_import_run_id), ''),
               e.source_row_key, e.source_row_hash,
               'needs_station_mapping', 'station:NULL', 'unit:NULL', 'equipment:NULL',
               e.payload::text),
             chr(30) ORDER BY e.source_row_key) AS blob
      FROM e
  )
  SELECT
    p_import_run_id,
    (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = p_import_run_id),
    encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM e),
    (SELECT count(*)::integer FROM p WHERE p.eligibility <> 'A_READY_UNRESOLVED'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility = 'D_ALREADY_IMPORTED'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility = 'C_INVALID_EVIDENCE'),
    (SELECT count(*)::integer FROM e WHERE e.payload ->> 'canonical_mapping_status' = 'needs_station_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload ->> 'canonical_mapping_status' = 'needs_unit_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload ->> 'canonical_mapping_status' = 'needs_equipment_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload ->> 'canonical_mapping_status' = 'resolved'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'canonical_station_id'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'canonical_unit_id'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'canonical_equipment_id'),
    (SELECT count(DISTINCT e.source_row_key)::integer FROM e),
    (SELECT count(DISTINCT e.source_row_hash)::integer FROM e),
    (SELECT count(*)::integer FROM (SELECT 1 FROM e GROUP BY e.source_row_hash HAVING count(*) > 1) x),
    (SELECT (count(*) - count(DISTINCT e.source_row_key))::integer FROM e),
    (SELECT count(*)::integer FROM p WHERE p.source_row_hash IS NULL OR length(p.source_row_hash) <> 64),
    (SELECT count(*)::integer FROM e WHERE e.payload -> 'historical' ->> 'staged_mapping_status' = 'needs_station_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload -> 'historical' ->> 'staged_mapping_status' = 'needs_unit_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload -> 'historical' ->> 'staged_mapping_status' = 'needs_equipment_mapping'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'serial_number'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'next_date'),
    (SELECT count(DISTINCT e.region_id)::integer FROM e),
    (SELECT count(*)::integer FROM installed_relief_valves);
$$;

COMMENT ON FUNCTION cng_irv_import_preview(uuid) IS
  'Zero-write preview of the conservative installed-SRV import. The fingerprint binds the import '
  'run, the manifest, and per row the source key, source hash, the canonical status and all three '
  'NULL FKs plus every technical value and the historical provenance, sorted by source_row_key '
  'because source_row_hash is integrity evidence and is NOT unique.';

-- ---------------------------------------------------------------------------
-- COMMIT — one atomic transaction, content-bound, fail closed.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cng_irv_import_commit(
  p_import_run_id                 uuid,
  p_expected_manifest_fingerprint text,
  p_expected_preview_fingerprint  text,
  p_expected_row_count            integer,
  p_reason                        text
)
RETURNS TABLE (
  import_run_id       uuid,
  srvs_created        integer,
  rows_linked         integer,
  preview_fingerprint text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_manifest text;
  v_preview  text;
  v_eligible integer;
  v_now      timestamptz := now();
  v_created  integer := 0;
  v_linked   integer := 0;
  v_bad      integer;
BEGIN
  -- Gate 1: an approval must be PRESENTED. No "approve whatever is current".
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint), '') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint), '')  = ''
     OR p_expected_row_count IS NULL THEN
    RAISE EXCEPTION 'Installed-SRV import requires an explicit run, both fingerprints and the expected row count'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 2: the run must exist and be completed.
  IF NOT EXISTS (SELECT 1 FROM import_runs WHERE id = p_import_run_id AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Installed-SRV import: run % does not exist or is not completed', p_import_run_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 3+4: both fingerprints RE-DERIVED inside this transaction, so a change
  -- to the source, the technical values, the provenance or the conclusion
  -- between approval and execution lapses the approval.
  SELECT pv.manifest_fingerprint, pv.preview_fingerprint, pv.eligible_rows
    INTO v_manifest, v_preview, v_eligible
    FROM cng_irv_import_preview(p_import_run_id) pv;

  IF v_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Installed-SRV import refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Installed-SRV import refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_preview USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 5: the eligible count must be EXACTLY what was approved.
  IF v_eligible IS DISTINCT FROM p_expected_row_count THEN
    RAISE EXCEPTION 'Installed-SRV import refused: % eligible rows, approved for %',
      v_eligible, p_expected_row_count USING ERRCODE = 'check_violation';
  END IF;
  IF v_eligible = 0 THEN
    RAISE EXCEPTION 'Installed-SRV import refused: run % has no eligible rows', p_import_run_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Gate 6: defence in depth. Not one eligible row may propose a Station, a
  -- Unit, an equipment parent or any status but needs_station_mapping. The
  -- fingerprint already binds these; this says so in its own right.
  SELECT count(*) INTO v_bad FROM cng_irv_import_proposal(p_import_run_id) pr
   WHERE pr.eligibility = 'A_READY_UNRESOLVED'
     AND (pr.payload ->> 'canonical_mapping_status' IS DISTINCT FROM 'needs_station_mapping'
          OR pr.payload ? 'canonical_station_id'
          OR pr.payload ? 'canonical_unit_id'
          OR pr.payload ? 'canonical_equipment_id');
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'Installed-SRV import refused: % row(s) propose a Station, Unit, equipment parent or non-conservative status', v_bad
      USING ERRCODE = 'check_violation';
  END IF;

  -- ONE literal target. No dynamic SQL. Station, Unit and every equipment
  -- parent column are simply NOT NAMED, so they cannot be written at all.
  WITH cand AS (
    SELECT pr.staging_row_id, pr.source_row_key, pr.region_id, pr.payload
      FROM cng_irv_import_proposal(p_import_run_id) pr
     WHERE pr.eligibility = 'A_READY_UNRESOLVED'
  ),
  ins AS (
    INSERT INTO installed_relief_valves (
      region_id, mapping_status,
      source_station_name_raw, source_region_raw,
      location_raw, expected_parent_kind,
      manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status, part_number,
      size_type, inlet_size, outlet_size,
      set_pressure_raw, pressure_min, pressure_max, pressure_unit,
      last_calibration_raw, last_calibration_date, last_calibration_precision,
      next_calibration_raw, next_calibration_date, next_calibration_precision,
      source_status_raw, notes,
      source_file, source_sheet, source_row, source_raw)
    SELECT
      c.region_id, 'needs_station_mapping'::srv_mapping_status,
      c.payload ->> 'source_station_name_raw', c.payload ->> 'source_region_raw',
      c.payload ->> 'location_raw', (c.payload ->> 'expected_parent_kind')::srv_parent_kind,
      c.payload ->> 'manufacturer', c.payload ->> 'manufacturer',
      c.payload ->> 'serial_number', c.payload ->> 'serial_number_raw',
      coalesce((c.payload ->> 'serial_status')::serial_status, 'unknown'),
      c.payload ->> 'part_number',
      c.payload ->> 'size_type', c.payload ->> 'inlet_size', c.payload ->> 'outlet_size',
      c.payload ->> 'set_pressure_raw',
      (c.payload ->> 'pressure_min')::numeric, (c.payload ->> 'pressure_max')::numeric,
      (c.payload ->> 'pressure_unit')::pressure_unit,
      c.payload ->> 'last_raw', (c.payload ->> 'last_date')::date,
      (c.payload ->> 'last_precision')::date_precision,
      c.payload ->> 'next_raw', (c.payload ->> 'next_date')::date,
      (c.payload ->> 'next_precision')::date_precision,
      c.payload ->> 'source_status_raw', c.payload ->> 'notes',
      c.payload ->> 'source_file', c.payload ->> 'source_sheet',
      (c.payload ->> 'source_row')::integer, c.payload
      FROM cand c
    RETURNING id, (source_raw ->> 'source_row_key') AS k)
  SELECT count(*)::integer INTO v_created FROM ins;

  -- Lineage: one source row -> one canonical SRV, matched on source_row_key,
  -- which is unique. source_row_hash is integrity evidence and is NOT unique
  -- (173 rows legitimately repeat a payload), so it is never the join key.
  WITH lk AS (
    UPDATE import_staging_rows r
       SET committed_entity_id   = v.id,
           committed_entity_kind = 'installed_relief_valve',
           committed_at          = v_now,
           updated_at            = v_now
      FROM installed_relief_valves v
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table = 'installed_relief_valves'
       AND r.committed_entity_id IS NULL
       AND v.source_raw ->> 'source_row_key' = r.source_row_key
       AND v.source_raw ->> 'import_run_id'  = p_import_run_id::text
    RETURNING 1)
  SELECT count(*)::integer INTO v_linked FROM lk;

  IF v_linked <> v_created THEN
    RAISE EXCEPTION 'Installed-SRV import refused: % created but % linked', v_created, v_linked
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'installed_relief_valves', p_import_run_id,
          NULL, 'service_role:installed_srv_import',
          format('Installed SRV canonical import: %s created, %s linked (all needs_station_mapping)',
                 v_created, v_linked),
          NULL,
          jsonb_build_object('import_run_id', p_import_run_id,
                             'preview_fingerprint', v_preview,
                             'manifest_fingerprint', v_manifest,
                             'srvs_created', v_created, 'rows_linked', v_linked,
                             'canonical_mapping_status', 'needs_station_mapping',
                             'reason', p_reason),
          v_now);

  RETURN QUERY SELECT p_import_run_id, v_created, v_linked, v_preview;
END;
$$;

COMMENT ON FUNCTION cng_irv_import_commit(uuid, text, text, integer, text) IS
  'Atomically imports the staged installed SRVs as canonical records, every one with Station, Unit '
  'and equipment NULL and mapping_status needs_station_mapping. Content-bound to both fingerprints '
  'and the exact approved row count, all re-derived inside the transaction. Creates no Station, '
  'Unit, equipment, alias or mapping decision and calls no mapping function. service_role only, '
  'because a canonical SRV carries no created_by contract and there is no human actor to attribute.';

REVOKE ALL ON FUNCTION cng_irv_import_proposal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_import_proposal(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_irv_import_proposal(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_irv_import_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_import_preview(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_irv_import_preview(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_irv_import_commit(uuid, text, text, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_irv_import_commit(uuid, text, text, integer, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_irv_import_commit(uuid, text, text, integer, text) TO service_role;
