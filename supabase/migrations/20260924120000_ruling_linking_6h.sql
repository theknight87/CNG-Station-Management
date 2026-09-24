-- Phase 6h: link staged assets and Station-less installed SRVs to the Stations (and Units) the owner ruled in 6g.
--
-- Owner 2026-09-24: "yes prepare the linking batch and approve automatically".
--
-- A record is linked only when its OWN source Station name, folded by cng_normalize_name, equals a ruled
-- source spelling (or its recorded other spelling) in the SAME Region, and every ruling for that name agrees on
-- one Station and at most one Unit. The ruling is the owner's decision for that exact spelling (owner_station_rulings,
-- with workbook-row evidence); nothing is matched by similarity, suffix or count. The Unit is set only when the
-- ruling names one, i.e. the record's own name carries the Unit number (D2, owner-accepted); otherwise the Unit
-- stays NULL. Equipment parents are never set (§4).
--
--   * Staged storage vessels, recovery tanks, gas detectors and hoses become canonical assets (the 0049 field
--     contract, unchanged), 'resolved' when the ruling names a Unit, else 'needs_unit_mapping', with lineage on
--     the staging row. Recorded detector ABSENCE never becomes a device. Rows that already carry a Station
--     decision or lineage are not touched.
--   * Installed SRVs with no Station get station_id (+ unit_id), status needs_unit_mapping /
--     needs_equipment_mapping, and a mapping_note naming the ruling.
--
-- service_role only, content-bound (prefix 6H), re-derived at commit, one audit row listing every linked id.
-- This migration executes no DML.

CREATE OR REPLACE FUNCTION cng_6h_ruling_targets()
RETURNS TABLE (region_id uuid, name_norm text, station_id uuid, unit_id uuid, ruling_ids uuid[])
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH names AS (
    SELECT r.id, r.region_id, cng_normalize_name(r.source_name_raw) AS n, r.station_name, r.unit_name FROM owner_station_rulings r
    UNION
    SELECT r.id, r.region_id, cng_normalize_name(r.other_spelling_raw), r.station_name, r.unit_name
      FROM owner_station_rulings r WHERE r.other_spelling_raw IS NOT NULL
  ),
  resolved AS (
    SELECT n.id, n.region_id, n.n, s.id AS station_id, u.id AS unit_id, n.unit_name
      FROM names n
      JOIN stations s ON s.region_id = n.region_id AND s.normalized_name = cng_normalize_name(n.station_name)
                     AND s.archived_at IS NULL
      LEFT JOIN units u ON u.station_id = s.id AND u.archived_at IS NULL
                       AND u.normalized_name = cng_normalize_name(n.unit_name)
  )
  -- One answer per (Region, spelling): every ruling for it must name the same Station and the same Unit (or none),
  -- and a named Unit must exist. Anything else is not a target.
  SELECT region_id, n, min(station_id::text)::uuid, min(unit_id::text)::uuid, array_agg(DISTINCT id ORDER BY id)
    FROM resolved
   GROUP BY region_id, n
  HAVING count(DISTINCT station_id) = 1
     AND count(DISTINCT coalesce(unit_id::text, '-')) = 1
     AND bool_and(unit_name IS NULL OR unit_id IS NOT NULL);
$$;

CREATE OR REPLACE FUNCTION cng_6h_asset_proposal()
RETURNS TABLE (staging_row_id uuid, source_row_key text, source_row_hash text, target_table text,
               station_id uuid, unit_id uuid, region_id uuid, import_batch_id uuid, eligibility text, payload jsonb)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH t AS MATERIALIZED (SELECT * FROM cng_6h_ruling_targets()),
  base AS MATERIALIZED (
    SELECT r.*, g.id AS g_region_id
      FROM import_staging_rows r
      JOIN regions g ON g.name = r.normalized->>'region'
     WHERE r.target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
       AND r.mapping_status = 'needs_station_mapping'
       AND r.committed_entity_id IS NULL
       AND r.outcome NOT IN ('rejected','excluded','replayed')
       AND NOT EXISTS (SELECT 1 FROM import_mapping_decisions d
                        WHERE d.source_row_key = r.source_row_key AND d.superseded_at IS NULL)
  )
  SELECT b.id, b.source_row_key, b.source_row_hash, b.target_table, t.station_id, t.unit_id, b.g_region_id, b.import_batch_id,
         CASE WHEN b.target_table = 'gas_detectors' AND coalesce(b.normalized->>'creates_detector_record', 'true') <> 'true'
              THEN 'E_ABSENCE_NOT_A_DEVICE' ELSE 'READY' END,
         jsonb_strip_nulls(jsonb_build_object(
           'source_row_key',    b.source_row_key,
           'serial_number',     nullif(trim(b.normalized ->> 'serial_number'), ''),
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
           'station_ruling_ids', to_jsonb(t.ruling_ids),
           'source_file',  b.source_file,
           'source_sheet', b.source_sheet,
           'source_row',   b.source_row
         ))
    FROM base b
    JOIN t ON t.region_id = b.g_region_id AND t.name_norm = cng_normalize_name(b.normalized->>'source_station_name_raw')
   ORDER BY b.id;
$$;

CREATE OR REPLACE FUNCTION cng_6h_srv_proposal()
RETURNS TABLE (installed_valve_id uuid, station_id uuid, unit_id uuid, region_id uuid, ruling_ids uuid[], updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH t AS MATERIALIZED (SELECT * FROM cng_6h_ruling_targets())
  SELECT i.id, t.station_id, t.unit_id, i.region_id, t.ruling_ids, i.updated_at
    FROM installed_relief_valves i
    JOIN t ON t.region_id = i.region_id AND t.name_norm = cng_normalize_name(i.source_station_name_raw)
   WHERE i.archived_at IS NULL AND i.station_id IS NULL AND i.mapping_status = 'needs_station_mapping'
   ORDER BY i.id;
$$;

CREATE OR REPLACE FUNCTION cng_6h_preview()
RETURNS TABLE (preview_fingerprint text, assets_to_create int, assets_with_unit int, storage_vessels int, recovery_tanks int,
               gas_detectors int, hoses int, absence_rows_skipped int, srvs_to_link int, srvs_with_unit int,
               staged_unmatched int, srvs_unmatched int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH a AS MATERIALIZED (SELECT * FROM cng_6h_asset_proposal()),
  s AS MATERIALIZED (SELECT * FROM cng_6h_srv_proposal()),
  ready AS (SELECT * FROM a WHERE eligibility = 'READY')
  SELECT encode(sha256(convert_to('6H|' ||
           coalesce((SELECT string_agg(concat_ws('|', staging_row_id, source_row_hash, station_id, unit_id, eligibility, payload::text),
                     E'\n' ORDER BY staging_row_id) FROM a), '') || '||' ||
           coalesce((SELECT string_agg(concat_ws('|', installed_valve_id, station_id, unit_id, updated_at), E'\n'
                     ORDER BY installed_valve_id) FROM s), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM ready)::int,
         (SELECT count(*) FROM ready WHERE unit_id IS NOT NULL)::int,
         (SELECT count(*) FROM ready WHERE target_table = 'storage_vessels')::int,
         (SELECT count(*) FROM ready WHERE target_table = 'recovery_tanks')::int,
         (SELECT count(*) FROM ready WHERE target_table = 'gas_detectors')::int,
         (SELECT count(*) FROM ready WHERE target_table = 'hoses')::int,
         (SELECT count(*) FROM a WHERE eligibility <> 'READY')::int,
         (SELECT count(*) FROM s)::int,
         (SELECT count(*) FROM s WHERE unit_id IS NOT NULL)::int,
         (SELECT count(*) FROM import_staging_rows r
           WHERE r.target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
             AND r.mapping_status = 'needs_station_mapping' AND r.committed_entity_id IS NULL
             AND r.outcome NOT IN ('rejected','excluded','replayed')
             AND NOT EXISTS (SELECT 1 FROM import_mapping_decisions d WHERE d.source_row_key = r.source_row_key AND d.superseded_at IS NULL)
             AND NOT EXISTS (SELECT 1 FROM a WHERE a.staging_row_id = r.id))::int,
         (SELECT count(*) FROM installed_relief_valves i WHERE i.archived_at IS NULL AND i.station_id IS NULL
             AND NOT EXISTS (SELECT 1 FROM s WHERE s.installed_valve_id = i.id))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6h_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (assets_created int, rows_linked int, srvs_linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e_assets int; e_srvs int; v_sv int; v_rt int; v_gd int; v_ho int; v_linked int; v_srv int;
        v_now timestamptz := now();
BEGIN
  IF nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6h commit requires the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.assets_to_create, pv.srvs_to_link INTO v_fp, e_assets, e_srvs FROM cng_6h_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6h commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e_assets = 0 AND e_srvs = 0 THEN
    RAISE EXCEPTION '6h commit refused: nothing to link' USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6h_a ON COMMIT DROP AS SELECT * FROM cng_6h_asset_proposal() WHERE eligibility = 'READY';
  CREATE TEMP TABLE _6h_s ON COMMIT DROP AS SELECT * FROM cng_6h_srv_proposal();

  WITH ins AS (
    INSERT INTO storage_vessels (station_id, region_id, unit_id, mapping_status, mapping_note, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status, compressor_type_raw,
      last_inspection_raw, last_inspection_date, last_inspection_precision,
      next_inspection_raw, next_inspection_date, next_inspection_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet, source_row, source_raw)
    SELECT c.station_id, c.region_id, c.unit_id,
           (CASE WHEN c.unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END)::asset_mapping_status,
           'Station' || CASE WHEN c.unit_id IS NULL THEN '' ELSE ' and Unit' END || ' from owner ruling (6g)',
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw', (c.payload->>'serial_status')::serial_status,
           c.payload->>'compressor_type_raw',
           c.payload->>'last_raw', (c.payload->>'last_date')::date, (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date, (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet', (c.payload->>'source_row')::int, c.payload
      FROM _6h_a c WHERE c.target_table = 'storage_vessels'
    RETURNING 1)
  SELECT count(*)::int INTO v_sv FROM ins;

  WITH ins AS (
    INSERT INTO recovery_tanks (station_id, region_id, unit_id, mapping_status, mapping_note, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status, compressor_type_raw,
      last_inspection_raw, last_inspection_date, last_inspection_precision,
      next_inspection_raw, next_inspection_date, next_inspection_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet, source_row, source_raw)
    SELECT c.station_id, c.region_id, c.unit_id,
           (CASE WHEN c.unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END)::asset_mapping_status,
           'Station' || CASE WHEN c.unit_id IS NULL THEN '' ELSE ' and Unit' END || ' from owner ruling (6g)',
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw', (c.payload->>'serial_status')::serial_status,
           c.payload->>'compressor_type_raw',
           c.payload->>'last_raw', (c.payload->>'last_date')::date, (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date, (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet', (c.payload->>'source_row')::int, c.payload
      FROM _6h_a c WHERE c.target_table = 'recovery_tanks'
    RETURNING 1)
  SELECT count(*)::int INTO v_rt FROM ins;

  WITH ins AS (
    INSERT INTO gas_detectors (station_id, region_id, unit_id, mapping_status, mapping_note, manufacturer, manufacturer_raw,
      serial_number, serial_number_raw, serial_status,
      last_calibration_raw, last_calibration_date, last_calibration_precision,
      next_calibration_raw, next_calibration_date, next_calibration_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet, source_row, source_raw)
    SELECT c.station_id, c.region_id, c.unit_id,
           (CASE WHEN c.unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END)::asset_mapping_status,
           'Station' || CASE WHEN c.unit_id IS NULL THEN '' ELSE ' and Unit' END || ' from owner ruling (6g)',
           c.payload->>'manufacturer', c.payload->>'manufacturer',
           c.payload->>'serial_number', c.payload->>'serial_number_raw', (c.payload->>'serial_status')::serial_status,
           c.payload->>'last_raw', (c.payload->>'last_date')::date, (c.payload->>'last_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date, (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet', (c.payload->>'source_row')::int, c.payload
      FROM _6h_a c WHERE c.target_table = 'gas_detectors'
    RETURNING 1)
  SELECT count(*)::int INTO v_gd FROM ins;

  WITH ins AS (
    INSERT INTO hoses (station_id, region_id, unit_id, mapping_status, mapping_note, description,
      serial_number, serial_number_raw, serial_status,
      working_pressure_raw, working_pressure_value, working_pressure_unit,
      test_pressure_raw, test_pressure_value, test_pressure_unit,
      last_test_raw, last_test_date, last_test_precision,
      next_test_raw, next_test_date, next_test_precision,
      source_status_raw, notes, import_batch_id, source_file, source_sheet, source_row, source_raw)
    SELECT c.station_id, c.region_id, c.unit_id,
           (CASE WHEN c.unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END)::asset_mapping_status,
           'Station' || CASE WHEN c.unit_id IS NULL THEN '' ELSE ' and Unit' END || ' from owner ruling (6g)',
           c.payload->>'description',
           c.payload->>'serial_number', c.payload->>'serial_number_raw', (c.payload->>'serial_status')::serial_status,
           c.payload->>'wp_raw', (c.payload->>'wp_value')::numeric, (c.payload->>'wp_unit')::pressure_unit,
           c.payload->>'tp_raw', (c.payload->>'tp_value')::numeric, (c.payload->>'tp_unit')::pressure_unit,
           c.payload->>'last_test_raw', (c.payload->>'last_test_date')::date, (c.payload->>'last_test_precision')::date_precision,
           c.payload->>'next_raw', (c.payload->>'next_date')::date, (c.payload->>'next_precision')::date_precision,
           c.payload->>'source_status_raw', c.payload->>'notes',
           c.import_batch_id, c.payload->>'source_file', c.payload->>'source_sheet', (c.payload->>'source_row')::int, c.payload
      FROM _6h_a c WHERE c.target_table = 'hoses'
    RETURNING 1)
  SELECT count(*)::int INTO v_ho FROM ins;

  WITH linked AS (
    UPDATE import_staging_rows r
       SET committed_entity_id = x.asset_id, committed_entity_kind = x.kind, committed_at = v_now, updated_at = v_now
      FROM (
        SELECT c.staging_row_id, a.asset_id, a.kind
          FROM _6h_a c
          JOIN LATERAL (
            SELECT sv.id AS asset_id, 'storage_vessel' AS kind FROM storage_vessels sv
             WHERE c.target_table = 'storage_vessels' AND sv.source_raw->>'source_row_key' = c.source_row_key
            UNION ALL SELECT rt.id, 'recovery_tank' FROM recovery_tanks rt
             WHERE c.target_table = 'recovery_tanks' AND rt.source_raw->>'source_row_key' = c.source_row_key
            UNION ALL SELECT gd.id, 'gas_detector' FROM gas_detectors gd
             WHERE c.target_table = 'gas_detectors' AND gd.source_raw->>'source_row_key' = c.source_row_key
            UNION ALL SELECT h.id, 'hose' FROM hoses h
             WHERE c.target_table = 'hoses' AND h.source_raw->>'source_row_key' = c.source_row_key
          ) a ON true
      ) x
     WHERE r.id = x.staging_row_id
    RETURNING 1)
  SELECT count(*)::int INTO v_linked FROM linked;

  UPDATE installed_relief_valves i
     SET station_id = s.station_id, unit_id = s.unit_id,
         mapping_status = (CASE WHEN s.unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'needs_equipment_mapping' END)::srv_mapping_status,
         mapping_note = 'Station' || CASE WHEN s.unit_id IS NULL THEN '' ELSE ' and Unit' END ||
                        ' from owner ruling (6g) for the source name; equipment parent not proven'
    FROM _6h_s s
   WHERE i.id = s.installed_valve_id AND i.station_id IS NULL AND i.updated_at = s.updated_at;
  GET DIAGNOSTICS v_srv = ROW_COUNT;

  IF v_sv + v_rt + v_gd + v_ho <> e_assets OR v_linked <> e_assets OR v_srv <> e_srvs THEN
    RAISE EXCEPTION '6h commit refused: % assets / % linked / % SRVs written, % / % / % expected',
      v_sv + v_rt + v_gd + v_ho, v_linked, v_srv, e_assets, e_assets, e_srvs USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, NULL, 'service_role:ruling_linking_6h',
          format('Phase 6h: %s staged assets imported (%s vessels, %s recovery tanks, %s detectors, %s hoses) and %s installed SRVs given their Station, from owner rulings. %s',
                 v_sv + v_rt + v_gd + v_ho, v_sv, v_rt, v_gd, v_ho, v_srv, coalesce(p_reason, '')),
          NULL,
          jsonb_build_object('preview_fingerprint', v_fp,
                             'staging_row_ids', (SELECT jsonb_agg(staging_row_id ORDER BY staging_row_id) FROM _6h_a),
                             'installed_valve_ids', (SELECT jsonb_agg(installed_valve_id ORDER BY installed_valve_id) FROM _6h_s)),
          v_now);
  RETURN QUERY SELECT v_sv + v_rt + v_gd + v_ho, v_linked, v_srv, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6h_ruling_targets(), cng_6h_asset_proposal(), cng_6h_srv_proposal(), cng_6h_preview(),
  cng_6h_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6h_ruling_targets(), cng_6h_asset_proposal(), cng_6h_srv_proposal(), cng_6h_preview(),
  cng_6h_commit(text, text) TO service_role;
