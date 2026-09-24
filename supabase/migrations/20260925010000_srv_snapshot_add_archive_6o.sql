-- Phase 6o: the 24/9/2026 station snapshot (رصيد المحطات) becomes the installed-SRV reference.
--
-- Owner ruling 2026-09-24: "اعتمد الي في الملف ... الي بيحكمني السيريال في الاخر" - the snapshot is the reference and a
-- valve is identified by its serial (a vessel or compressor can carry several valves of one pressure with different
-- serials). A snapshot valve absent from the system is ADDED; a system valve absent from the snapshot is ARCHIVED
-- (archived_at, never deleted). The diff is computed by scripts/import/6o_snapshot_add_archive.py with the import
-- pipeline's own normalizers; this function only resolves the Station and applies it.
--
-- Station of an added valve, never guessed: (1) the Station already recorded on active valves carrying the same Region
-- and normalized source Station name, when they name exactly one; else (2) the one canonical Station of that Region with
-- that normalized name; else NULL (needs_station_mapping, raw name kept). Unit: the one Unit those same valves carry,
-- only when every one of them carries it. Equipment is never set here (6m's ruling may be re-run afterwards).
-- p_add rows are arrays: [row, region, station, location, serial, serial_raw, part_number, serial_status, manufacturer,
-- size_type, inlet, outlet, set_pressure_raw, pmin, pmax, punit, last_date, last_prec, last_raw, next_date, next_prec,
-- next_raw, notes]. Content-bound; a row already added or a valve already archived refuses the batch.
-- service_role only, prefix 6O. No DML here.

CREATE OR REPLACE FUNCTION cng_6o_proposal(p_add jsonb)
RETURNS TABLE (source_row int, region_id uuid, station_id uuid, unit_id uuid, a jsonb)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH r AS MATERIALIZED (
    SELECT (a->>0)::int AS source_row, g.id AS region_id, cng_normalize_name(a->>2) AS nk, a
      FROM jsonb_array_elements(p_add) a LEFT JOIN regions g ON g.name = a->>1
  ), prior AS MATERIALIZED (
    SELECT i.region_id, cng_normalize_name(i.source_station_name_raw) AS nk,
           count(DISTINCT i.station_id) AS ns, min(i.station_id::text)::uuid AS st,
           count(DISTINCT i.unit_id) AS nu, min(i.unit_id::text)::uuid AS un,
           count(*) FILTER (WHERE i.station_id IS NOT NULL AND i.unit_id IS NULL) AS no_unit
      FROM installed_relief_valves i
     WHERE i.archived_at IS NULL AND i.source_station_name_raw IS NOT NULL
     GROUP BY 1, 2
  ), canon AS MATERIALIZED (
    SELECT s.region_id, s.normalized_name AS nk, count(*) AS n, min(s.id::text)::uuid AS st
      FROM stations s WHERE s.archived_at IS NULL GROUP BY 1, 2
  )
  SELECT r.source_row, r.region_id,
         CASE WHEN p.ns = 1 THEN p.st WHEN p.nk IS NULL AND c.n = 1 THEN c.st END,
         CASE WHEN p.ns = 1 AND p.nu = 1 AND p.no_unit = 0 THEN p.un END,
         r.a
    FROM r
    LEFT JOIN prior p ON p.region_id = r.region_id AND p.nk = r.nk
    LEFT JOIN canon c ON c.region_id = r.region_id AND c.nk = r.nk
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6o_preview(p_add jsonb, p_archive jsonb)
RETURNS TABLE (preview_fingerprint text, to_add int, with_station int, with_unit int, to_archive int, refused int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6o_proposal(p_add)),
       x AS MATERIALIZED (SELECT (e #>> '{}')::uuid AS id FROM jsonb_array_elements(p_archive) e),
       t AS MATERIALIZED (SELECT x.id, i.updated_at FROM x LEFT JOIN installed_relief_valves i ON i.id = x.id AND i.archived_at IS NULL)
  SELECT encode(sha256(convert_to('6O|' || p_add::text || '|' || p_archive::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', source_row, station_id, unit_id), E'\n' ORDER BY source_row) FROM p), '') || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', id, updated_at), E'\n' ORDER BY id) FROM t), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE station_id IS NOT NULL)::int,
         (SELECT count(*) FROM p WHERE unit_id IS NOT NULL)::int,
         (SELECT count(*) FROM t)::int,
         ((SELECT count(*) FROM p WHERE region_id IS NULL OR p.a->>2 IS NULL
             OR EXISTS (SELECT 1 FROM installed_relief_valves i WHERE i.source_file = 'Warehouse_Relief_Data.xlsx (2026-09-24)'
                          AND i.source_row = p.source_row))
          + (SELECT count(*) - count(DISTINCT source_row) FROM p)
          + (SELECT count(*) FROM t WHERE updated_at IS NULL)
          + (SELECT count(*) - count(DISTINCT id) FROM t))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6o_commit(p_add jsonb, p_archive jsonb, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (added int, archived int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; ea int; ex int; rf int; na int; nx int;
        v_note text := 'Added from the 24/9/2026 station snapshot (owner ruling 6o)';
BEGIN
  SELECT pv.preview_fingerprint, pv.to_add, pv.to_archive, pv.refused INTO v_fp, ea, ex, rf FROM cng_6o_preview(p_add, p_archive) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6o commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF rf > 0 OR ea + ex = 0 THEN RAISE EXCEPTION '6o commit refused: % refused rows, % to add, % to archive', rf, ea, ex USING ERRCODE = '22023'; END IF;

  INSERT INTO installed_relief_valves (
    region_id, station_id, unit_id, mapping_status, mapping_note, source_station_name_raw, source_region_raw,
    location_raw, expected_parent_kind, serial_number, serial_number_raw, part_number, serial_status,
    manufacturer, manufacturer_raw, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
    last_calibration_date, last_calibration_precision, last_calibration_raw,
    next_calibration_date, next_calibration_precision, next_calibration_raw, notes,
    source_file, source_sheet, source_row, source_raw)
  SELECT p.region_id, p.station_id, p.unit_id,
         CASE WHEN p.station_id IS NULL THEN 'needs_station_mapping' WHEN p.unit_id IS NULL THEN 'needs_unit_mapping'
              ELSE 'needs_equipment_mapping' END::srv_mapping_status,
         v_note, p.a->>2, p.a->>1, p.a->>3,
         CASE p.a->>3 WHEN 'Stage' THEN 'compressor' WHEN 'Storage' THEN 'storage_vessel' END::srv_parent_kind,
         p.a->>4, p.a->>5, p.a->>6, (p.a->>7)::serial_status,
         p.a->>8, p.a->>8, p.a->>9, p.a->>10, p.a->>11, p.a->>12,
         (p.a->>13)::numeric, (p.a->>14)::numeric, (p.a->>15)::pressure_unit,
         (p.a->>16)::date, (p.a->>17)::date_precision, p.a->>18,
         (p.a->>19)::date, (p.a->>20)::date_precision, p.a->>21, p.a->>22,
         'Warehouse_Relief_Data.xlsx (2026-09-24)', 'رصيد المحطات', p.source_row,
         jsonb_build_object('snapshot_row', p.a, 'rule', '6o: snapshot valve absent from the system')
    FROM cng_6o_proposal(p_add) p;
  GET DIAGNOSTICS na = ROW_COUNT;

  UPDATE installed_relief_valves i SET archived_at = now(),
         review_reason = coalesce(i.review_reason || '; ', '') || 'archived: absent from the 24/9/2026 station snapshot (owner ruling 6o)'
   WHERE i.archived_at IS NULL AND i.id IN (SELECT (e #>> '{}')::uuid FROM jsonb_array_elements(p_archive) e);
  GET DIAGNOSTICS nx = ROW_COUNT;

  IF na <> ea OR nx <> ex THEN
    RAISE EXCEPTION '6o commit refused: added %/% archived %/%', na, ea, nx, ex USING ERRCODE = '40001';
  END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'installed_relief_valves', NULL, NULL, 'service_role:srv_snapshot_add_archive_6o',
          format('Phase 6o: %s SRVs added from the 24/9/2026 station snapshot, %s archived as absent from it (owner ruling). %s',
                 na, nx, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'archived', p_archive,
                                   'added_rows', (SELECT jsonb_agg(source_row ORDER BY source_row) FROM cng_6o_proposal(p_add))),
          now());
  RETURN QUERY SELECT na, nx, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6o_proposal(jsonb), cng_6o_preview(jsonb, jsonb), cng_6o_commit(jsonb, jsonb, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6o_proposal(jsonb), cng_6o_preview(jsonb, jsonb), cng_6o_commit(jsonb, jsonb, text, text)
  TO service_role;
