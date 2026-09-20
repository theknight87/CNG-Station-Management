-- 0055_warehouse_srv_import.sql
-- Canonical import for the staged WAREHOUSE relief valves (Prompt 27).
--
-- ADDS NO TABLE, COLUMN, ENUM, CONSTRAINT OR INDEX. `warehouse_relief_valves`
-- has carried every column this needs since 0001. Only the WRITER was missing,
-- exactly as it was for installed SRVs before 0051 -- and this deliberately
-- mirrors 0051 rather than inventing a second import architecture.
--
-- ========================= WAREHOUSE STOCK IS NOT INSTALLED =================
--
-- A warehouse valve is stock. It sits in no Station and on no Unit, so there is
-- NO mapping lifecycle here: the table has no `mapping_status`, no `unit_id` and
-- no equipment parent, and this import creates no mapping requirement of any
-- kind. `target_region_id` / `target_station_id` record where stock is ALLOCATED,
-- which is not the same thing as where it is installed.
--
-- TARGET REGION IS RESOLVED; TARGET STATION IS NOT. The source's
-- `assigned_region` is one of the six canonical Region names on all 1,775 rows
-- that carry it (0 non-canonical, verified), so resolving it is a lookup against
-- a closed set, not an inference. `assigned_station_raw` is different: matching
-- a Station name is the SAME evidence question the installed-SRV batches answer,
-- and that is an owner-approved, content-bound, audited decision -- not something
-- an import may do silently. So `target_station_id` is left NULL for every row.
--
-- ONE FIELD HAS NO CANONICAL DESTINATION, AND IT IS REPORTED RATHER THAN DROPPED:
-- `assigned_station_raw` (1,774 rows, 303 distinct names) has no
-- `target_station_name_raw` column to live in. It is NOT lost -- the whole staged
-- payload is preserved verbatim in `source_raw` -- but it is not queryable as a
-- field. Adding that column is a follow-up decision, deliberately NOT taken here.
--
-- DATES map only at `exact_date` precision. `wrv_last_prec_ck`,
-- `wrv_next_prec_ck` and `wrv_issue_prec_ck` each require the date to be NOT NULL
-- if and only if the precision says `exact_date`, so a year_only or unknown date
-- keeps its raw text and stores NULL. Nothing is fabricated to satisfy a column.
--
-- SECURITY follows 0051: `service_role` ONLY, because a warehouse valve carries
-- no `created_by` contract and there is no human actor to attribute. The commit
-- is SECURITY DEFINER with a pinned search_path; the two read paths are
-- deliberately NOT definer. No dynamic SQL. ONE literal INSERT target.

CREATE OR REPLACE FUNCTION cng_wrv_import_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id  uuid,
  source_row_key  text,
  source_row_hash text,
  eligibility     text,
  payload         jsonb
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH staged AS MATERIALIZED (
    SELECT r.id, r.source_row_key, r.source_row_hash, r.source_file, r.source_sheet,
           r.source_row, r.source_raw, r.normalized AS n, r.committed_entity_id
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table = 'warehouse_relief_valves'
       AND r.outcome NOT IN ('rejected', 'excluded', 'replayed')
  )
  SELECT
    s.id, s.source_row_key, s.source_row_hash,
    CASE
      WHEN s.committed_entity_id IS NOT NULL                 THEN 'D_ALREADY_IMPORTED'
      WHEN s.source_row_hash IS NULL
        OR length(s.source_row_hash) <> 64                   THEN 'C_INVALID_EVIDENCE'
      WHEN coalesce(btrim(s.n ->> 'availability_status_raw'), '') = ''
                                                             THEN 'C_INVALID_EVIDENCE'
      ELSE 'A_READY'
    END,
    jsonb_strip_nulls(jsonb_build_object(
      'source_row_key',  s.source_row_key,
      'source_row_hash', s.source_row_hash,
      'import_run_id',   p_import_run_id::text,
      'source_file',     s.source_file,
      'source_sheet',    s.source_sheet,
      'source_row',      s.source_row,
      'source_raw',      s.source_raw,
      -- identity and stock attributes
      'warehouse_code',     s.n ->> 'warehouse_code',
      'serial_number',      s.n ->> 'serial_number',
      'serial_number_raw',  s.n ->> 'serial_number_raw',
      'serial_status',      s.n ->> 'serial_status',
      'part_number',        s.n ->> 'part_number',
      'manufacturer',       s.n ->> 'manufacturer',
      'size_type',          s.n ->> 'size_type',
      'inlet_size',         s.n ->> 'port_in',
      'outlet_size',        s.n ->> 'port_out',
      'set_pressure_raw',   s.n -> 'set_pressure' ->> 'raw',
      'pressure_min',       s.n -> 'set_pressure' ->> 'min',
      'pressure_max',       s.n -> 'set_pressure' ->> 'max',
      'pressure_unit',      s.n -> 'set_pressure' ->> 'unit',
      'calibration_location', s.n ->> 'calibration_location',
      'availability_raw',   s.n ->> 'availability_status_raw',
      'notes',              s.n ->> 'notes',
      -- ALLOCATION. Region resolves against the closed canonical set; the Station
      -- NAME is carried for provenance only and never becomes a foreign key here.
      'assigned_region',      s.n ->> 'assigned_region',
      'assigned_station_raw', s.n ->> 'assigned_station_raw',
      'target_region_id',   (SELECT g.id::text FROM regions g
                              WHERE g.name = s.n ->> 'assigned_region'),
      'target_station_id',  NULL::text,
      -- DATES: a value exists ONLY at exact_date precision.
      'issue_raw',       s.n -> 'issue_date' ->> 'raw',
      'issue_precision', coalesce(s.n -> 'issue_date' ->> 'precision', 'unknown'),
      'issue_date',      CASE WHEN s.n -> 'issue_date' ->> 'precision' = 'exact_date'
                              THEN s.n -> 'issue_date' ->> 'value' END,
      'last_raw',        s.n -> 'last_calibration' ->> 'raw',
      'last_precision',  coalesce(s.n -> 'last_calibration' ->> 'precision', 'unknown'),
      'last_date',       CASE WHEN s.n -> 'last_calibration' ->> 'precision' = 'exact_date'
                              THEN s.n -> 'last_calibration' ->> 'value' END,
      'next_raw',        s.n -> 'next_due_date' ->> 'raw',
      'next_precision',  coalesce(s.n -> 'next_due_date' ->> 'precision', 'unknown'),
      'next_date',       CASE WHEN s.n -> 'next_due_date' ->> 'precision' = 'exact_date'
                              THEN s.n -> 'next_due_date' ->> 'value' END,
      'source_status_raw', coalesce(s.n -> 'next_due_date' ->> 'sourceStatusRaw',
                                    s.n -> 'last_calibration' ->> 'sourceStatusRaw')
    ))
    FROM staged s
   ORDER BY s.source_row_key;
$$;

COMMENT ON FUNCTION cng_wrv_import_proposal(uuid) IS
  'Per-row canonical proposal for staged warehouse relief valves. Warehouse stock has no mapping '
  'lifecycle: no Station, Unit or equipment parent is proposed. target_region_id resolves against '
  'the closed canonical Region set; target_station_id is always NULL because matching a Station '
  'name is an owner-approved mapping decision, not an import step.';

CREATE OR REPLACE FUNCTION cng_wrv_import_preview(p_import_run_id uuid)
RETURNS TABLE (
  import_run_id          uuid,
  manifest_fingerprint   text,
  preview_fingerprint    text,
  eligible_rows          integer,
  excluded_rows          integer,
  already_imported       integer,
  invalid_evidence       integer,
  distinct_source_keys   integer,
  distinct_source_hashes integer,
  duplicate_source_keys  integer,
  invalid_hashes         integer,
  rows_with_serial       integer,
  rows_with_warehouse_code integer,
  rows_with_part_number  integer,
  duplicate_serial_groups integer,
  rows_with_target_region integer,
  rows_with_target_station integer,
  rows_with_assigned_station_name integer,
  rows_with_exact_next_date integer,
  rows_with_exact_last_date integer,
  rows_with_exact_issue_date integer,
  canonical_wrv_now      integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_wrv_import_proposal(p_import_run_id)),
  e AS MATERIALIZED (SELECT * FROM p WHERE p.eligibility = 'A_READY'),
  canon AS (
    SELECT string_agg(
             concat_ws(chr(31),
               p_import_run_id::text,
               coalesce((SELECT run.summary ->> 'manifest_fingerprint'
                           FROM import_runs run WHERE run.id = p_import_run_id), ''),
               e.source_row_key, e.source_row_hash,
               'station:NULL', e.payload::text),
             chr(30) ORDER BY e.source_row_key) AS blob
      FROM e
  )
  SELECT
    p_import_run_id,
    (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = p_import_run_id),
    encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM e),
    (SELECT count(*)::integer FROM p WHERE p.eligibility <> 'A_READY'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility = 'D_ALREADY_IMPORTED'),
    (SELECT count(*)::integer FROM p WHERE p.eligibility = 'C_INVALID_EVIDENCE'),
    (SELECT count(DISTINCT e.source_row_key)::integer FROM e),
    (SELECT count(DISTINCT e.source_row_hash)::integer FROM e),
    (SELECT (count(*) - count(DISTINCT e.source_row_key))::integer FROM e),
    (SELECT count(*)::integer FROM p WHERE p.source_row_hash IS NULL OR length(p.source_row_hash) <> 64),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'serial_number'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'warehouse_code'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'part_number'),
    (SELECT count(*)::integer FROM (SELECT 1 FROM e WHERE e.payload ? 'serial_number'
        GROUP BY e.payload ->> 'serial_number' HAVING count(*) > 1) z),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'target_region_id'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'target_station_id'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'assigned_station_raw'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'next_date'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'last_date'),
    (SELECT count(*)::integer FROM e WHERE e.payload ? 'issue_date'),
    (SELECT count(*)::integer FROM warehouse_relief_valves);
$$;

COMMENT ON FUNCTION cng_wrv_import_preview(uuid) IS
  'Zero-write preview of the warehouse relief valve import. The fingerprint binds the run, the '
  'manifest, and per row the source key, source hash, the explicit NULL target Station and the '
  'full payload, sorted by source_row_key.';

CREATE OR REPLACE FUNCTION cng_wrv_import_commit(
  p_import_run_id                 uuid,
  p_expected_manifest_fingerprint text,
  p_expected_preview_fingerprint  text,
  p_expected_row_count            integer,
  p_reason                        text
)
RETURNS TABLE (
  import_run_id       uuid,
  valves_created      integer,
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
  v_serial   integer;
  v_region   integer;
  v_now      timestamptz := now();
  v_created  integer := 0;
  v_linked   integer := 0;
  v_bad      integer;
BEGIN
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint), '') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint), '')  = ''
     OR p_expected_row_count IS NULL THEN
    RAISE EXCEPTION 'Warehouse SRV import requires an explicit run, both fingerprints and the expected row count'
      USING ERRCODE = 'check_violation';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM import_runs WHERE id = p_import_run_id AND completed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'Warehouse SRV import: run % does not exist or is not completed', p_import_run_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Captured BEFORE the INSERT, so the audit describes the approved set rather
  -- than the empty set left behind (the Prompt 25K lesson, applied at birth).
  SELECT pv.manifest_fingerprint, pv.preview_fingerprint, pv.eligible_rows,
         pv.rows_with_serial, pv.rows_with_target_region
    INTO v_manifest, v_preview, v_eligible, v_serial, v_region
    FROM cng_wrv_import_preview(p_import_run_id) pv;

  IF v_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'check_violation';
  END IF;
  IF v_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_preview USING ERRCODE = 'check_violation';
  END IF;
  IF v_eligible IS DISTINCT FROM p_expected_row_count THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: % eligible rows, approved for %',
      v_eligible, p_expected_row_count USING ERRCODE = 'check_violation';
  END IF;
  IF v_eligible = 0 THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: run % has no eligible rows', p_import_run_id
      USING ERRCODE = 'check_violation';
  END IF;

  -- Defence in depth: warehouse stock is never installed, so no row may propose
  -- a target Station. (There is no Unit or equipment column on this table at all.)
  SELECT count(*) INTO v_bad FROM cng_wrv_import_proposal(p_import_run_id) pr
   WHERE pr.eligibility = 'A_READY' AND pr.payload ? 'target_station_id';
  IF v_bad > 0 THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: % row(s) propose a target Station', v_bad
      USING ERRCODE = 'check_violation';
  END IF;

  WITH cand AS (
    SELECT pr.source_row_key, pr.payload
      FROM cng_wrv_import_proposal(p_import_run_id) pr
     WHERE pr.eligibility = 'A_READY'
  ),
  ins AS (
    INSERT INTO warehouse_relief_valves (
      warehouse_code, serial_number, serial_number_raw, serial_status, part_number,
      manufacturer, manufacturer_raw, size_type, inlet_size, outlet_size,
      set_pressure_raw, pressure_min, pressure_max, pressure_unit,
      calibration_location, availability_status, availability_raw,
      target_region_id,
      warehouse_issue_raw, warehouse_issue_date, warehouse_issue_precision,
      last_calibration_raw, last_calibration_date, last_calibration_precision,
      next_calibration_raw, next_calibration_date, next_calibration_precision,
      source_status_raw, notes,
      source_file, source_sheet, source_row, source_raw)
    SELECT
      c.payload ->> 'warehouse_code',
      c.payload ->> 'serial_number', c.payload ->> 'serial_number_raw',
      coalesce((c.payload ->> 'serial_status')::serial_status, 'unknown'),
      c.payload ->> 'part_number',
      c.payload ->> 'manufacturer', c.payload ->> 'manufacturer',
      c.payload ->> 'size_type', c.payload ->> 'inlet_size', c.payload ->> 'outlet_size',
      c.payload ->> 'set_pressure_raw',
      (c.payload ->> 'pressure_min')::numeric, (c.payload ->> 'pressure_max')::numeric,
      (c.payload ->> 'pressure_unit')::pressure_unit,
      c.payload ->> 'calibration_location',
      -- The five source phrasings map 1:1 onto the five enum labels. Anything
      -- else is NOT guessed: it fails the cast and aborts the whole transaction.
      (CASE c.payload ->> 'availability_raw'
         WHEN 'Available New'                   THEN 'available_new'
         WHEN 'Available Calibrated'            THEN 'available_calibrated'
         WHEN 'Available in Store UC'           THEN 'available_in_store_uc'
         WHEN 'Sent to Station - Received'      THEN 'sent_to_station_received'
         WHEN 'Sent to Station - Not Received'  THEN 'sent_to_station_not_received'
       END)::warehouse_availability,
      c.payload ->> 'availability_raw',
      (c.payload ->> 'target_region_id')::uuid,
      c.payload ->> 'issue_raw', (c.payload ->> 'issue_date')::date,
      (c.payload ->> 'issue_precision')::date_precision,
      c.payload ->> 'last_raw', (c.payload ->> 'last_date')::date,
      (c.payload ->> 'last_precision')::date_precision,
      c.payload ->> 'next_raw', (c.payload ->> 'next_date')::date,
      (c.payload ->> 'next_precision')::date_precision,
      c.payload ->> 'source_status_raw', c.payload ->> 'notes',
      c.payload ->> 'source_file', c.payload ->> 'source_sheet',
      (c.payload ->> 'source_row')::integer, c.payload
      FROM cand c
    RETURNING id)
  SELECT count(*)::integer INTO v_created FROM ins;

  WITH lk AS (
    UPDATE import_staging_rows r
       SET committed_entity_id   = v.id,
           committed_entity_kind = 'warehouse_relief_valve',
           committed_at          = v_now,
           updated_at            = v_now
      FROM warehouse_relief_valves v
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table = 'warehouse_relief_valves'
       AND r.committed_entity_id IS NULL
       AND v.source_raw ->> 'source_row_key' = r.source_row_key
       AND v.source_raw ->> 'import_run_id'  = p_import_run_id::text
    RETURNING 1)
  SELECT count(*)::integer INTO v_linked FROM lk;

  IF v_linked <> v_created THEN
    RAISE EXCEPTION 'Warehouse SRV import refused: % created but % linked', v_created, v_linked
      USING ERRCODE = 'check_violation';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'warehouse_relief_valves', p_import_run_id, NULL,
          'service_role:warehouse_srv_import',
          format('Warehouse SRV import: %s created, %s linked (stock, no Station or Unit)',
                 v_created, v_linked),
          NULL,
          jsonb_build_object('import_run_id', p_import_run_id,
                             'preview_fingerprint', v_preview,
                             'manifest_fingerprint', v_manifest,
                             'valves_created', v_created, 'rows_linked', v_linked,
                             'rows_with_serial', v_serial,
                             'rows_with_target_region', v_region,
                             'target_stations_assigned', 0,
                             'reason', p_reason),
          v_now);

  RETURN QUERY SELECT p_import_run_id, v_created, v_linked, v_preview;
END;
$$;

COMMENT ON FUNCTION cng_wrv_import_commit(uuid, text, text, integer, text) IS
  'Atomically imports the staged warehouse relief valves as canonical stock records. Content-bound '
  'to both fingerprints and the exact approved row count, all re-derived inside the transaction. '
  'Assigns no Station and no Unit; target_region_id comes from the closed canonical Region set. '
  'service_role only, because warehouse stock carries no created_by contract.';

REVOKE ALL ON FUNCTION cng_wrv_import_proposal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_wrv_import_proposal(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_wrv_import_proposal(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_wrv_import_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_wrv_import_preview(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_wrv_import_preview(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_wrv_import_commit(uuid, text, text, integer, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_wrv_import_commit(uuid, text, text, integer, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_wrv_import_commit(uuid, text, text, integer, text) TO service_role;
