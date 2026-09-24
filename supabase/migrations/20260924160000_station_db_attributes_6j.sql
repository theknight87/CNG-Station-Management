-- Phase 6j: Station-database attributes and compressors for the rows held since 6c (Alex, Canal, Upper, East).
--
-- Owner 2026-09-24: "approve the existing station and unit name and go to next step" and, asked about Stations with
-- no Unit yet: "أيوه، طبّق القاعدة" - a one-Unit Station's Unit takes the Station's name (the 6c-2 ruling, SU2).
--
-- A held `Station data base.xlsx` row is attached when its own name resolves through owner_station_rulings
-- (cng_6h_ruling_targets) to exactly one Station and:
--   named_unit   the ruling names the Unit                     -> that Unit
--   one_unit     the Station has exactly one Unit              -> that Unit (6c-2 rule)
--   create_unit  the Station has no Unit and exactly one row   -> a Unit named as the Station is created (owner rule)
-- and the Unit holds no attributes yet and receives exactly one row. Everything else is held. The attributes are
-- written exactly as 6c writes them (counts only from plain integers, raw text kept, bay status open/closed only),
-- and a compressor is created exactly as 6d does (model as written, numbers only from plain numbers), unless the
-- Unit already has one. service_role only, content-bound (prefix 6J). This migration executes no DML.

CREATE OR REPLACE FUNCTION cng_6j_proposal()
RETURNS TABLE (staging_row_id uuid, source_row_hash text, kind text, station_id uuid, region_id uuid, unit_id uuid,
               unit_name text, dispenser_count int, dispenser_count_raw text, hose_count int, hose_count_raw text,
               storage_count int, storage_count_raw text, bay_status bay_status, bay_status_raw text,
               model text, total_running_hours numeric, average_hours_per_day numeric,
               average_gas_sales_per_day numeric, average_gas_sales_raw text)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH t AS MATERIALIZED (SELECT * FROM cng_6h_ruling_targets()),
  held AS MATERIALIZED (
    SELECT s.id, s.source_row_hash, s.normalized AS n, g.id AS g_region
      FROM import_staging_rows s JOIN regions g ON g.name = s.normalized->>'region'
     WHERE s.target_table = 'unit_attributes' AND s.committed_entity_id IS NULL
       AND s.outcome NOT IN ('rejected','excluded','replayed')
       AND nullif(btrim(s.normalized->>'source_name_raw'), '') IS NOT NULL
  ),
  m AS (
    SELECT h.*, t.station_id, t.unit_id AS ruled_unit,
           (SELECT count(*) FROM units u WHERE u.station_id = t.station_id AND u.archived_at IS NULL) AS n_units
      FROM held h JOIN t ON t.region_id = h.g_region AND t.name_norm = cng_normalize_name(h.n->>'source_name_raw')
  ),
  k AS (
    SELECT m.*, st.region_id AS st_region, st.station_name,
           CASE WHEN m.ruled_unit IS NOT NULL THEN 'named_unit'
                WHEN m.n_units = 1 THEN 'one_unit'
                WHEN m.n_units = 0 THEN 'create_unit' END AS kind,
           coalesce(m.ruled_unit, CASE WHEN m.n_units = 1 THEN
             (SELECT u.id FROM units u WHERE u.station_id = m.station_id AND u.archived_at IS NULL) END) AS target_unit
      FROM m JOIN stations st ON st.id = m.station_id
  ),
  ok AS (
    SELECT k.*,
           count(*) OVER (PARTITION BY coalesce(k.target_unit::text, 'new:' || k.station_id)) AS rows_per_target
      FROM k WHERE k.kind IS NOT NULL
  )
  SELECT ok.id, ok.source_row_hash, ok.kind, ok.station_id, ok.st_region, ok.target_unit,
         coalesce((SELECT u.unit_name FROM units u WHERE u.id = ok.target_unit), ok.station_name),
         CASE WHEN btrim(ok.n->>'dispenser_count_reported_raw') ~ '^\d+$' THEN btrim(ok.n->>'dispenser_count_reported_raw')::int END,
         nullif(ok.n->>'dispenser_count_reported_raw', ''),
         CASE WHEN btrim(ok.n->>'hose_count_reported_raw') ~ '^\d+$' THEN btrim(ok.n->>'hose_count_reported_raw')::int END,
         nullif(ok.n->>'hose_count_reported_raw', ''),
         CASE WHEN btrim(ok.n->>'storage_count_reported_raw') ~ '^\d+$' THEN btrim(ok.n->>'storage_count_reported_raw')::int END,
         nullif(ok.n->>'storage_count_reported_raw', ''),
         CASE WHEN lower(btrim(ok.n->>'bay_status_raw')) LIKE 'open%' THEN 'open'::bay_status
              WHEN lower(btrim(ok.n->>'bay_status_raw')) LIKE 'clos%' THEN 'closed'::bay_status END,
         nullif(ok.n->>'bay_status_raw', ''),
         nullif(btrim(ok.n->>'compressor_model'), ''),
         CASE WHEN btrim(ok.n->>'total_running_hours') ~ '^\d+(\.\d+)?$' THEN btrim(ok.n->>'total_running_hours')::numeric END,
         CASE WHEN btrim(ok.n->>'avg_hours_per_day') ~ '^\d+(\.\d+)?$' THEN btrim(ok.n->>'avg_hours_per_day')::numeric END,
         CASE WHEN btrim(ok.n->>'avg_gas_sales_per_day_raw') ~ '^\d+(\.\d+)?$' THEN btrim(ok.n->>'avg_gas_sales_per_day_raw')::numeric END,
         nullif(ok.n->>'avg_gas_sales_per_day_raw', '')
    FROM ok
   WHERE ok.rows_per_target = 1
     AND (ok.target_unit IS NULL OR EXISTS (
           SELECT 1 FROM units u WHERE u.id = ok.target_unit
              AND u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
              AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
              AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
              AND u.bay_status IS NULL AND u.bay_status_raw IS NULL))
   ORDER BY ok.id;
$$;

CREATE OR REPLACE FUNCTION cng_6j_preview()
RETURNS TABLE (preview_fingerprint text, rows_to_attach int, named_unit int, one_unit int, units_to_create int,
               compressors_to_create int, held_rows int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6j_proposal())
  SELECT encode(sha256(convert_to('6J|' || coalesce((SELECT string_agg(concat_ws('|', staging_row_id, source_row_hash, kind, station_id,
           unit_id, unit_name, dispenser_count, dispenser_count_raw, hose_count, hose_count_raw, storage_count, storage_count_raw,
           bay_status, bay_status_raw, model, total_running_hours, average_hours_per_day, average_gas_sales_per_day,
           average_gas_sales_raw), E'\n' ORDER BY staging_row_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE kind = 'named_unit')::int,
         (SELECT count(*) FROM p WHERE kind = 'one_unit')::int,
         (SELECT count(*) FROM p WHERE kind = 'create_unit')::int,
         (SELECT count(*) FROM p WHERE (model IS NOT NULL OR total_running_hours IS NOT NULL OR average_hours_per_day IS NOT NULL)
             AND (p.unit_id IS NULL OR NOT EXISTS (SELECT 1 FROM compressors c WHERE c.unit_id = p.unit_id AND c.archived_at IS NULL)))::int,
         (SELECT count(*) FROM import_staging_rows s WHERE s.target_table = 'unit_attributes' AND s.committed_entity_id IS NULL
             AND s.outcome NOT IN ('rejected','excluded','replayed')
             AND nullif(btrim(s.normalized->>'source_name_raw'), '') IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM p WHERE p.staging_row_id = s.id))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6j_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (rows_attached int, units_created int, compressors_created int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e_rows int; e_new int; e_comp int; v_new int; v_upd int; v_comp int; v_linked int; v_now timestamptz := now();
BEGIN
  IF nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6j commit requires the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.rows_to_attach, pv.units_to_create, pv.compressors_to_create
    INTO v_fp, e_rows, e_new, e_comp FROM cng_6j_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6j commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e_rows = 0 THEN RAISE EXCEPTION '6j commit refused: nothing to attach' USING ERRCODE = '22023'; END IF;

  CREATE TEMP TABLE _6j ON COMMIT DROP AS SELECT * FROM cng_6j_proposal();

  -- Owner rule: a Station with one Unit - here a Station with none yet and exactly one Station-database line -
  -- gets that Unit, named as the Station.
  WITH ins AS (
    INSERT INTO units (station_id, region_id, unit_name, source_file, source_raw)
    SELECT p.station_id, p.region_id, p.unit_name, 'owner rule 6j (one-Unit Station named as the Station)',
           jsonb_build_object('staging_row_id', p.staging_row_id, 'rule', 'SU2/6c-2: one Unit = Station name')
      FROM _6j p WHERE p.kind = 'create_unit'
    RETURNING id, station_id)
  UPDATE _6j p SET unit_id = ins.id FROM ins WHERE p.kind = 'create_unit' AND p.station_id = ins.station_id;
  GET DIAGNOSTICS v_new = ROW_COUNT;

  UPDATE units u
     SET dispenser_count_reported = p.dispenser_count, dispenser_count_raw = p.dispenser_count_raw,
         hose_count_reported = p.hose_count, hose_count_raw = p.hose_count_raw,
         storage_count_reported = p.storage_count, storage_count_raw = p.storage_count_raw,
         bay_status = p.bay_status, bay_status_raw = p.bay_status_raw, updated_at = v_now
    FROM _6j p
   WHERE u.id = p.unit_id
     AND u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
     AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
     AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
     AND u.bay_status IS NULL AND u.bay_status_raw IS NULL;
  GET DIAGNOSTICS v_upd = ROW_COUNT;

  INSERT INTO compressors (station_id, region_id, unit_id, mapping_status, model, model_raw,
                           total_running_hours, average_hours_per_day, average_gas_sales_per_day, average_gas_sales_raw,
                           import_batch_id, source_file, source_sheet, source_row, source_raw)
  SELECT p.station_id, p.region_id, p.unit_id, 'resolved', p.model, p.model,
         p.total_running_hours, p.average_hours_per_day, p.average_gas_sales_per_day, p.average_gas_sales_raw,
         s.import_batch_id, s.source_file, s.source_sheet, s.source_row, s.source_raw
    FROM _6j p JOIN import_staging_rows s ON s.id = p.staging_row_id
   WHERE (p.model IS NOT NULL OR p.total_running_hours IS NOT NULL OR p.average_hours_per_day IS NOT NULL)
     AND NOT EXISTS (SELECT 1 FROM compressors c WHERE c.unit_id = p.unit_id AND c.archived_at IS NULL);
  GET DIAGNOSTICS v_comp = ROW_COUNT;

  UPDATE import_staging_rows s
     SET committed_entity_id = p.unit_id, committed_entity_kind = 'unit', committed_at = v_now, updated_at = v_now
    FROM _6j p WHERE s.id = p.staging_row_id AND s.committed_entity_id IS NULL;
  GET DIAGNOSTICS v_linked = ROW_COUNT;

  IF v_new <> e_new OR v_upd <> e_rows OR v_linked <> e_rows OR v_comp <> e_comp THEN
    RAISE EXCEPTION '6j commit refused: % Units / % attributes / % links / % compressors, expected % / % / % / %',
      v_new, v_upd, v_linked, v_comp, e_new, e_rows, e_rows, e_comp USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'units', NULL, NULL, 'service_role:station_db_attributes_6j',
          format('Phase 6j: %s Station-database rows attached (%s Units created under the one-Unit rule), %s compressors created. %s',
                 v_upd, v_new, v_comp, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp,
                                   'staging_row_ids', (SELECT jsonb_agg(staging_row_id ORDER BY staging_row_id) FROM _6j),
                                   'unit_ids', (SELECT jsonb_agg(unit_id ORDER BY unit_id) FROM _6j)), v_now);
  RETURN QUERY SELECT v_upd, v_new, v_comp, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6j_proposal(), cng_6j_preview(), cng_6j_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6j_proposal(), cng_6j_preview(), cng_6j_commit(text, text) TO service_role;
