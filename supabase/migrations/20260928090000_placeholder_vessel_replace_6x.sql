-- Phase 6x: replace 6r placeholder storage vessels with the real vessels from the owner's workbook (2026-09-28).
--
-- Owner ruling: the storage/recovery workbook he supplied lists the real storage vessels; each 6r placeholder is to take
-- the data of the workbook's Storage rows for its Unit. Only placeholders whose Station name matches the workbook
-- exactly (after whitespace/letter folding, same Region) are in the payload, and only where no workbook serial already
-- sits on a vessel of another Station; everything else is held for the owner (scripts/import/6x_vessels_extract.py).
-- p_rows: [placeholder_id, k, source_row, manufacturer, manufacturer_raw, serial, serial_raw, serial_status,
--          compressor_type_raw, last_raw, last_date, last_precision, next_raw, next_date, next_precision, notes, cells]
-- normalized by the import pipeline's own functions (scripts/import/6x_vessels_normalize.ts). Row k = 0 turns the
-- placeholder itself into the real vessel (its SRVs stay on it); rows k > 0 are further real vessels of the same Unit.
-- In a Unit that ends with several vessels, its Storage SRVs return to needs_equipment_mapping so the owner's 6s ruling
-- (serial order) re-pairs them. A repeated serial is stored as given (principle 16 — reported, never merged).
-- resolved_by = the first active admin (the owner). service_role only, content-bound, prefix 6X. No DML here.

CREATE OR REPLACE FUNCTION cng_6x_proposal(p_rows jsonb)
RETURNS TABLE (placeholder_id uuid, k int, unit_id uuid, updated_at timestamptz, r jsonb)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT v.id, (e->>1)::int, v.unit_id, v.updated_at, e
    FROM jsonb_array_elements(p_rows) e
    JOIN storage_vessels v ON v.id = (e->>0)::uuid AND v.archived_at IS NULL AND v.source_file = 'owner rule 6r' AND v.unit_id IS NOT NULL
   ORDER BY 1, 2;
$$;

CREATE OR REPLACE FUNCTION cng_6x_preview(p_rows jsonb)
RETURNS TABLE (preview_fingerprint text, rows_matched int, rows_given int, placeholders int, new_vessels int, srvs_to_repair int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6x_proposal(p_rows)),
       multi AS (SELECT p.unit_id FROM p GROUP BY 1
                  HAVING count(*) + (SELECT count(*) FROM storage_vessels o WHERE o.unit_id = p.unit_id AND o.archived_at IS NULL
                                       AND o.source_file IS DISTINCT FROM 'owner rule 6r') > 1)
  SELECT encode(sha256(convert_to('6X|' || p_rows::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', placeholder_id, k, updated_at), E'\n' ORDER BY placeholder_id, k) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         jsonb_array_length(p_rows),
         (SELECT count(DISTINCT placeholder_id) FROM p)::int,
         (SELECT count(*) FROM p WHERE k > 0)::int,
         (SELECT count(*) FROM installed_relief_valves i JOIN multi m ON m.unit_id = i.unit_id
           WHERE i.archived_at IS NULL AND i.expected_parent_kind = 'storage_vessel' AND i.storage_vessel_id IS NOT NULL)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6x_commit(p_rows jsonb, p_source_file text, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (placeholders_replaced int, vessels_created int, srvs_returned int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; nm int; ng int; np int; nn int; ns int; a int; b int; c int; v_owner uuid;
BEGIN
  SELECT pv.preview_fingerprint, pv.rows_matched, pv.rows_given, pv.placeholders, pv.new_vessels, pv.srvs_to_repair
    INTO v_fp, nm, ng, np, nn, ns FROM cng_6x_preview(p_rows) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6x commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF nm = 0 OR nm <> ng THEN RAISE EXCEPTION '6x commit refused: % of % rows match a placeholder', nm, ng USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_owner FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;
  DROP TABLE IF EXISTS _6x;
  CREATE TEMP TABLE _6x ON COMMIT DROP AS SELECT * FROM cng_6x_proposal(p_rows);

  -- k = 0: the placeholder becomes the real vessel
  UPDATE storage_vessels v
     SET manufacturer = p.r->>3, manufacturer_raw = p.r->>4, serial_number = p.r->>5, serial_number_raw = p.r->>6,
         serial_status = (p.r->>7)::serial_status, compressor_type_raw = p.r->>8,
         last_inspection_raw = p.r->>9, last_inspection_date = (p.r->>10)::date, last_inspection_precision = (p.r->>11)::date_precision,
         next_inspection_raw = p.r->>12, next_inspection_date = (p.r->>13)::date, next_inspection_precision = (p.r->>14)::date_precision,
         notes = p.r->>15, source_file = p_source_file, source_sheet = 'رصيد المحطات', source_row = (p.r->>2)::int, source_raw = p.r->16,
         needs_review = false, review_reason = NULL,
         mapping_note = 'Real vessel from the owner''s workbook (6x); replaced the 6r placeholder'
    FROM _6x p WHERE p.k = 0 AND v.id = p.placeholder_id AND v.updated_at = p.updated_at;
  GET DIAGNOSTICS a = ROW_COUNT;

  -- k > 0: further real vessels of the same Unit
  INSERT INTO storage_vessels (station_id, region_id, unit_id, mapping_status, resolved_by, resolved_at, manufacturer, manufacturer_raw,
                               serial_number, serial_number_raw, serial_status, compressor_type_raw,
                               last_inspection_raw, last_inspection_date, last_inspection_precision,
                               next_inspection_raw, next_inspection_date, next_inspection_precision,
                               notes, source_file, source_sheet, source_row, source_raw, mapping_note)
  SELECT v.station_id, v.region_id, v.unit_id, 'resolved', v_owner, now(), p.r->>3, p.r->>4, p.r->>5, p.r->>6, (p.r->>7)::serial_status, p.r->>8,
         p.r->>9, (p.r->>10)::date, (p.r->>11)::date_precision, p.r->>12, (p.r->>13)::date, (p.r->>14)::date_precision,
         p.r->>15, p_source_file, 'رصيد المحطات', (p.r->>2)::int, p.r->16, 'Real vessel from the owner''s workbook (6x)'
    FROM _6x p JOIN storage_vessels v ON v.id = p.placeholder_id WHERE p.k > 0;
  GET DIAGNOSTICS b = ROW_COUNT;

  -- Units now holding several vessels: their Storage SRVs go back for the 6s serial-order pairing
  UPDATE installed_relief_valves i
     SET storage_vessel_id = NULL, mapping_status = 'needs_equipment_mapping', resolved_by = NULL, resolved_at = NULL
   WHERE i.archived_at IS NULL AND i.expected_parent_kind = 'storage_vessel' AND i.storage_vessel_id IS NOT NULL
     AND i.unit_id IN (SELECT DISTINCT p.unit_id FROM _6x p)
     AND (SELECT count(*) FROM storage_vessels o WHERE o.unit_id = i.unit_id AND o.archived_at IS NULL) > 1;
  GET DIAGNOSTICS c = ROW_COUNT;

  IF a <> np OR b <> nn OR c <> ns THEN
    RAISE EXCEPTION '6x commit refused: replaced % (expected %), created % (expected %), SRVs returned % (expected %)', a, np, b, nn, c, ns
      USING ERRCODE = '40001';
  END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'storage_vessels', NULL, v_owner, 'service_role:placeholder_vessel_replace_6x',
          format('Phase 6x: %s placeholder vessels replaced and %s real vessels added from %s; %s Storage SRVs returned for 6s pairing. %s',
                 a, b, p_source_file, c, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'rows', p_rows), now());
  RETURN QUERY SELECT a, b, c, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6x_proposal(jsonb), cng_6x_preview(jsonb), cng_6x_commit(jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6x_proposal(jsonb), cng_6x_preview(jsonb), cng_6x_commit(jsonb, text, text, text) TO service_role;
