-- Phase 6d / 6e (owner approved 2026-09-23: "yes import compressors and rename the units").
--
-- 6d  COMPRESSORS from `Station data base.xlsx`. One compressor per Unit that a
--     unit_attributes row was linked to in 6c-1/6c-2 (the row IS that Unit's line),
--     carrying the row's compressor model, total running hours, average hours per
--     day and average gas sales per day. Model is stored exactly as written
--     (`model` = `model_raw`; "GALLILEO" is not corrected). Numbers only when the
--     cell is a plain number; otherwise NULL with the raw text kept where a raw
--     column exists. No serial, manufacturer or job number is invented. A Unit that
--     already has a compressor gets none (0 exist today). mapping_status =
--     'resolved' because Station and Unit are both known.
--
-- 6e  UNIT NAMES follow the owner's rule: a Station with one Unit -> the Unit is
--     named exactly as the Station; with n Units -> "<Station> 1" … "<Station> n".
--     Renamed only where the target is unambiguous:
--       * one Unit: target = Station name;
--       * n Units where n-1 are already "<Station> 2..n" and the remaining one is
--         named exactly "<Station>": that one becomes "<Station> 1".
--     Anything else is reported, not renamed. Every rename writes one audit row
--     with the old and new name (source_raw is never altered).
--
-- Both are service_role only, content-bound (prefixes 6D / 6E), re-derived at commit.

-- ============================================================================ 6d
CREATE OR REPLACE FUNCTION cng_6d_compressor_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id uuid, source_row_hash text, unit_id uuid, station_id uuid, region_id uuid,
  model text, total_running_hours numeric, average_hours_per_day numeric,
  average_gas_sales_per_day numeric, average_gas_sales_raw text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT s.id, s.source_row_hash, u.id, u.station_id, u.region_id,
         nullif(btrim(s.normalized->>'compressor_model'), ''),
         CASE WHEN btrim(s.normalized->>'total_running_hours') ~ '^\d+(\.\d+)?$' THEN btrim(s.normalized->>'total_running_hours')::numeric END,
         CASE WHEN btrim(s.normalized->>'avg_hours_per_day') ~ '^\d+(\.\d+)?$' THEN btrim(s.normalized->>'avg_hours_per_day')::numeric END,
         CASE WHEN btrim(s.normalized->>'avg_gas_sales_per_day_raw') ~ '^\d+(\.\d+)?$' THEN btrim(s.normalized->>'avg_gas_sales_per_day_raw')::numeric END,
         nullif(s.normalized->>'avg_gas_sales_per_day_raw', '')
    FROM import_staging_rows s
    JOIN units u ON u.id = s.committed_entity_id
   WHERE s.import_run_id = p_import_run_id
     AND s.target_table = 'unit_attributes'
     AND s.committed_entity_kind = 'unit'
     AND u.archived_at IS NULL
     AND (nullif(btrim(s.normalized->>'compressor_model'), '') IS NOT NULL
          OR nullif(btrim(s.normalized->>'total_running_hours'), '') IS NOT NULL
          OR nullif(btrim(s.normalized->>'avg_hours_per_day'), '') IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM compressors c WHERE c.unit_id = u.id AND c.archived_at IS NULL)
   ORDER BY s.id;
$$;

CREATE OR REPLACE FUNCTION cng_6d_compressor_preview(p_import_run_id uuid)
RETURNS TABLE (preview_fingerprint text, compressors_to_create int, units int,
               with_model int, with_running_hours int, east int, west int, delta int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6d_compressor_proposal(p_import_run_id))
  SELECT encode(sha256(convert_to('6D|' || coalesce((SELECT string_agg(concat_ws('|', staging_row_id, source_row_hash,
           unit_id, model, total_running_hours, average_hours_per_day, average_gas_sales_per_day, average_gas_sales_raw),
           E'\n' ORDER BY staging_row_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int, (SELECT count(DISTINCT unit_id) FROM p)::int,
         (SELECT count(*) FROM p WHERE model IS NOT NULL)::int,
         (SELECT count(*) FROM p WHERE total_running_hours IS NOT NULL)::int,
         (SELECT count(*) FROM p JOIN regions r ON r.id = p.region_id WHERE r.name = 'East')::int,
         (SELECT count(*) FROM p JOIN regions r ON r.id = p.region_id WHERE r.name = 'West')::int,
         (SELECT count(*) FROM p JOIN regions r ON r.id = p.region_id WHERE r.name = 'Delta')::int;
$$;

CREATE OR REPLACE FUNCTION cng_6d_compressor_commit(p_import_run_id uuid, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (compressors_created int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; v_expected int; v_units int; v_created int; v_now timestamptz := clock_timestamp();
BEGIN
  IF p_import_run_id IS NULL OR nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6d commit requires an import run and the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.compressors_to_create, pv.units INTO v_fp, v_expected, v_units
    FROM cng_6d_compressor_preview(p_import_run_id) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6d commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF v_expected = 0 OR v_expected <> v_units THEN
    RAISE EXCEPTION '6d commit refused: % compressors for % Units', v_expected, v_units USING ERRCODE = '22023';
  END IF;

  INSERT INTO compressors (station_id, region_id, unit_id, mapping_status, model, model_raw,
                           total_running_hours, average_hours_per_day, average_gas_sales_per_day, average_gas_sales_raw,
                           import_batch_id, source_file, source_sheet, source_row, source_raw)
  SELECT p.station_id, p.region_id, p.unit_id, 'resolved', p.model, p.model,
         p.total_running_hours, p.average_hours_per_day, p.average_gas_sales_per_day, p.average_gas_sales_raw,
         s.import_batch_id, s.source_file, s.source_sheet, s.source_row, s.source_raw
    FROM cng_6d_compressor_proposal(p_import_run_id) p JOIN import_staging_rows s ON s.id = p.staging_row_id;
  GET DIAGNOSTICS v_created = ROW_COUNT;
  IF v_created <> v_expected THEN
    RAISE EXCEPTION '6d commit refused: % created, % expected', v_created, v_expected USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'import_runs', p_import_run_id, NULL, 'service_role:compressors_6d',
          format('Phase 6d compressors: %s created from Station data base.xlsx, one per Unit. %s', v_created, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'compressors_created', v_created), v_now);
  RETURN QUERY SELECT v_created, v_fp;
END;
$$;

-- ============================================================================ 6e
CREATE OR REPLACE FUNCTION cng_6e_unit_name_proposal()
RETURNS TABLE (unit_id uuid, station_id uuid, region text, station_name text,
               current_name text, new_name text, rule text)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH s AS MATERIALIZED (
    SELECT st.id, st.station_name, r.name AS region,
           (SELECT count(*) FROM units u WHERE u.station_id = st.id AND u.archived_at IS NULL) AS n
      FROM stations st JOIN regions r ON r.id = st.region_id WHERE st.archived_at IS NULL
  ),
  one AS (
    SELECT u.id, s.id AS sid, s.region, s.station_name, u.unit_name, s.station_name AS new_name, 'one_unit' AS rule
      FROM s JOIN units u ON u.station_id = s.id AND u.archived_at IS NULL
     WHERE s.n = 1 AND u.normalized_name <> cng_normalize_name(s.station_name)
  ),
  multi AS (
    SELECT u.id, s.id, s.region, s.station_name, u.unit_name, s.station_name || ' 1', 'first_of_numbered'
      FROM s JOIN units u ON u.station_id = s.id AND u.archived_at IS NULL
     WHERE s.n > 1
       AND u.normalized_name = cng_normalize_name(s.station_name)
       AND (SELECT count(*) FROM units u2 WHERE u2.station_id = s.id AND u2.archived_at IS NULL
              AND u2.normalized_name IN (SELECT cng_normalize_name(s.station_name || ' ' || g) FROM generate_series(2, s.n::int) g)) = s.n - 1
       AND NOT EXISTS (SELECT 1 FROM units u3 WHERE u3.station_id = s.id AND u3.normalized_name = cng_normalize_name(s.station_name || ' 1'))
  )
  SELECT * FROM one UNION ALL SELECT * FROM multi ORDER BY 3, 4, 5;
$$;

CREATE OR REPLACE FUNCTION cng_6e_unit_name_preview()
RETURNS TABLE (preview_fingerprint text, units_to_rename int, one_unit int, first_of_numbered int,
               stations_not_following_rule_left int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6e_unit_name_proposal()),
  s AS (
    SELECT st.id, st.station_name,
           array(SELECT u.normalized_name FROM units u WHERE u.station_id = st.id AND u.archived_at IS NULL ORDER BY 1) AS names,
           (SELECT count(*) FROM units u WHERE u.station_id = st.id AND u.archived_at IS NULL) AS n
      FROM stations st WHERE st.archived_at IS NULL
  )
  SELECT encode(sha256(convert_to('6E|' || coalesce((SELECT string_agg(concat_ws('|', unit_id, current_name, new_name), E'\n'
           ORDER BY unit_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE rule = 'one_unit')::int,
         (SELECT count(*) FROM p WHERE rule = 'first_of_numbered')::int,
         (SELECT count(*) FROM s WHERE s.n > 0
             AND s.id NOT IN (SELECT station_id FROM p)
             AND s.names <> CASE WHEN s.n = 1 THEN ARRAY[cng_normalize_name(s.station_name)]
                                 ELSE array(SELECT cng_normalize_name(s.station_name || ' ' || g) FROM generate_series(1, s.n::int) g ORDER BY 1) END)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6e_unit_name_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (units_renamed int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; v_expected int; v_done int; v_now timestamptz := clock_timestamp();
BEGIN
  IF nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6e commit requires the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.units_to_rename INTO v_fp, v_expected FROM cng_6e_unit_name_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6e commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF v_expected = 0 THEN
    RAISE EXCEPTION '6e commit refused: nothing left to rename' USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6e ON COMMIT DROP AS SELECT * FROM cng_6e_unit_name_proposal();

  UPDATE units u SET unit_name = p.new_name, updated_at = v_now
    FROM _6e p WHERE u.id = p.unit_id AND u.unit_name = p.current_name;
  GET DIAGNOSTICS v_done = ROW_COUNT;
  IF v_done <> v_expected THEN
    RAISE EXCEPTION '6e commit refused: % renamed, % expected', v_done, v_expected USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  SELECT 'record_updated', 'units', p.unit_id, NULL, 'service_role:unit_names_6e',
         format('Unit renamed to the owner naming rule (%s): %s -> %s. %s', p.rule, p.current_name, p.new_name, coalesce(p_reason, '')),
         jsonb_build_object('unit_name', p.current_name), jsonb_build_object('unit_name', p.new_name, 'preview_fingerprint', v_fp),
         v_now
    FROM _6e p;

  RETURN QUERY SELECT v_done, v_fp;
END;
$$;

COMMENT ON FUNCTION cng_6d_compressor_proposal(uuid) IS 'Phase 6d: one compressor per Unit linked from Station data base.xlsx. Read-only.';
COMMENT ON FUNCTION cng_6d_compressor_preview(uuid) IS 'Phase 6d: counts and content-bound fingerprint (prefix 6D). Read-only.';
COMMENT ON FUNCTION cng_6d_compressor_commit(uuid, text, text) IS 'Phase 6d: one guarded insert of the approved compressors.';
COMMENT ON FUNCTION cng_6e_unit_name_proposal() IS 'Phase 6e: Units whose names do not follow the owner rule and have one unambiguous target. Read-only.';
COMMENT ON FUNCTION cng_6e_unit_name_preview() IS 'Phase 6e: counts and content-bound fingerprint (prefix 6E). Read-only.';
COMMENT ON FUNCTION cng_6e_unit_name_commit(text, text) IS 'Phase 6e: one guarded rename; one audit row per Unit with old and new name.';

REVOKE ALL ON FUNCTION cng_6d_compressor_proposal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6d_compressor_proposal(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6d_compressor_preview(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6d_compressor_preview(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6d_compressor_commit(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6d_compressor_commit(uuid, text, text) TO service_role;
REVOKE ALL ON FUNCTION cng_6e_unit_name_proposal() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6e_unit_name_proposal() TO service_role;
REVOKE ALL ON FUNCTION cng_6e_unit_name_preview() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6e_unit_name_preview() TO service_role;
REVOKE ALL ON FUNCTION cng_6e_unit_name_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6e_unit_name_commit(text, text) TO service_role;
