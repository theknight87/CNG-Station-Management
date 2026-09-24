-- Phase 6p: a valve is its serial (owner ruling 2026-09-24, "اوك" / "امشي مع الملف").
--
-- (1) SPLIT. Phase 6n rewrote 97 installed-SRV records in place with a different serial (and that valve's dates). Under
--     the serial rule those are two valves. For each such record, still carrying the 6n serial: a NEW record is created
--     as an exact copy of it (same Station/Unit/parent/status, new id), and the ORIGINAL record gets its pre-6n serial
--     and dates back (from the 6n audit row) and is archived, so the old valve keeps its own history. The 7 records
--     6n emptied (snapshot had no serial) are not split. The list is read from audit_logs server-side, never supplied.
-- (2) MOVE. p_move ids are valves whose serial the snapshot records in another Region (عزبة مختار: system East, snapshot
--     Delta). Owner: follow the file. They move to p_region with no Station/Unit/parent (needs_station_mapping, raw name
--     kept): the canonical Station of that name exists only in the old Region, and a Station is never guessed.
-- service_role only, content-bound, prefix 6P. No DML here.

CREATE OR REPLACE FUNCTION cng_6p_split_proposal()
RETURNS TABLE (id uuid, serial_now text, updated_at timestamptz, before jsonb)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS (
    SELECT (e->>'id')::uuid AS id, e->>'serial_number' AS sn,
           (SELECT r FROM jsonb_array_elements(a.before_data->'records') r WHERE r->>'id' = e->>'id' LIMIT 1) AS before
      FROM audit_logs a, jsonb_array_elements(a.after_data->'payload') e
     WHERE a.actor_label = 'service_role:srv_snapshot_update_6n'
       AND e->>'kind' = 'serial' AND e->>'serial_number' IS NOT NULL
  )
  SELECT i.id, i.serial_number, i.updated_at, p.before
    FROM p JOIN installed_relief_valves i ON i.id = p.id
   WHERE i.archived_at IS NULL AND i.serial_number IS NOT DISTINCT FROM p.sn AND p.before IS NOT NULL
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6p_preview(p_move jsonb, p_region text)
RETURNS TABLE (preview_fingerprint text, to_split int, to_move int, refused int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH s AS MATERIALIZED (SELECT * FROM cng_6p_split_proposal()),
       m AS MATERIALIZED (SELECT (e #>> '{}')::uuid AS id FROM jsonb_array_elements(p_move) e),
       t AS MATERIALIZED (SELECT m.id, i.updated_at, i.region_id, i.source_station_name_raw
                            FROM m LEFT JOIN installed_relief_valves i ON i.id = m.id AND i.archived_at IS NULL)
  SELECT encode(sha256(convert_to('6P|' || coalesce(p_region, '') || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', id, serial_now, updated_at), E'\n' ORDER BY id) FROM s), '') || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', id, updated_at), E'\n' ORDER BY id) FROM t), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM s)::int,
         (SELECT count(*) FROM t)::int,
         ((SELECT count(*) FROM t WHERE updated_at IS NULL OR source_station_name_raw IS NULL
             OR region_id = (SELECT g.id FROM regions g WHERE g.name = p_region))
          + (SELECT count(*) - count(DISTINCT id) FROM t)
          + CASE WHEN jsonb_array_length(p_move) > 0 AND NOT EXISTS (SELECT 1 FROM regions g WHERE g.name = p_region) THEN 1 ELSE 0 END)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6p_commit(p_move jsonb, p_region text, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (split int, moved int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; es int; em int; rf int; ns int; nn int; nm int; v_region uuid;
BEGIN
  SELECT pv.preview_fingerprint, pv.to_split, pv.to_move, pv.refused INTO v_fp, es, em, rf FROM cng_6p_preview(p_move, p_region) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6p commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF rf > 0 OR es + em = 0 THEN RAISE EXCEPTION '6p commit refused: % refused, % to split, % to move', rf, es, em USING ERRCODE = '22023'; END IF;
  SELECT g.id INTO v_region FROM regions g WHERE g.name = p_region;
  CREATE TEMP TABLE _6p ON COMMIT DROP AS SELECT * FROM cng_6p_split_proposal();

  -- the new valve: an exact copy of the current record under a new id
  INSERT INTO installed_relief_valves
  SELECT (jsonb_populate_record(NULL::installed_relief_valves,
            to_jsonb(i) || jsonb_build_object('id', gen_random_uuid(), 'created_at', now(), 'updated_at', now(),
              'mapping_note', coalesce(i.mapping_note || '; ', '') || 'new valve split from ' || i.id || ' (owner ruling 6p: a valve is its serial)'))).*
    FROM installed_relief_valves i JOIN _6p s ON s.id = i.id;
  GET DIAGNOSTICS nn = ROW_COUNT;

  -- the old valve: its own serial and dates back, then archived
  UPDATE installed_relief_valves i
     SET serial_number = s.before->>'serial_number', serial_number_raw = s.before->>'serial_number_raw',
         part_number = s.before->>'part_number', serial_status = (s.before->>'serial_status')::serial_status,
         set_pressure_raw = s.before->>'set_pressure_raw',
         pressure_min = (s.before->>'pressure_min')::numeric, pressure_max = (s.before->>'pressure_max')::numeric,
         pressure_unit = (s.before->>'pressure_unit')::pressure_unit,
         last_calibration_date = (s.before->>'last_calibration_date')::date,
         last_calibration_precision = (s.before->>'last_calibration_precision')::date_precision,
         last_calibration_raw = s.before->>'last_calibration_raw',
         next_calibration_date = (s.before->>'next_calibration_date')::date,
         next_calibration_precision = (s.before->>'next_calibration_precision')::date_precision,
         next_calibration_raw = s.before->>'next_calibration_raw',
         archived_at = now(),
         review_reason = coalesce(i.review_reason || '; ', '') || 'archived: replaced by a valve with another serial in the 24/9/2026 station snapshot (owner ruling 6p)'
    FROM _6p s WHERE i.id = s.id AND i.updated_at = s.updated_at;
  GET DIAGNOSTICS ns = ROW_COUNT;

  UPDATE installed_relief_valves i
     SET region_id = v_region, source_region_raw = p_region, station_id = NULL, unit_id = NULL,
         compressor_id = NULL, storage_vessel_id = NULL, dispenser_id = NULL,
         mapping_status = 'needs_station_mapping', resolved_by = NULL, resolved_at = NULL,
         review_reason = coalesce(i.review_reason || '; ', '') || 'Region from the 24/9/2026 station snapshot (owner ruling 6p); Station to confirm'
   WHERE i.archived_at IS NULL AND i.id IN (SELECT (e #>> '{}')::uuid FROM jsonb_array_elements(p_move) e);
  GET DIAGNOSTICS nm = ROW_COUNT;

  IF ns <> es OR nn <> es OR nm <> em THEN
    RAISE EXCEPTION '6p commit refused: split %/% (new %), moved %/%', ns, es, nn, nm, em USING ERRCODE = '40001';
  END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'installed_relief_valves', NULL, NULL, 'service_role:srv_serial_identity_6p',
          format('Phase 6p: %s records split into old (archived) + new valve by serial; %s valves moved to %s (owner ruling). %s',
                 ns, nm, p_region, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'split', (SELECT jsonb_agg(id ORDER BY id) FROM _6p), 'moved', p_move),
          now());
  RETURN QUERY SELECT ns, nm, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6p_split_proposal(), cng_6p_preview(jsonb, text), cng_6p_commit(jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6p_split_proposal(), cng_6p_preview(jsonb, text), cng_6p_commit(jsonb, text, text, text) TO service_role;
