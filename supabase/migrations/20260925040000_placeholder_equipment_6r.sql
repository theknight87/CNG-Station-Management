-- Phase 6r: equipment records for Units that have none, so their installed SRVs can be parented.
--
-- Owner ruling 2026-09-24: (1) every Unit has one compressor — a Unit with Stage SRVs awaiting equipment and no
-- compressor record gets ONE compressor record (no model/serial: unknown, never invented); (2) TEMPORARILY, a Unit with
-- Storage SRVs awaiting equipment and no storage-vessel record gets ONE vessel record standing for the Unit's storage.
-- That vessel is flagged needs_review with the reason, so it is visibly a placeholder until the real vessels are
-- recorded. Parenting is then done by re-running the owner's 6m ruling (the only equipment of its kind in the Unit).
-- service_role only, content-bound, prefix 6R. No DML here.

CREATE OR REPLACE FUNCTION cng_6r_proposal()
RETURNS TABLE (kind text, unit_id uuid, station_id uuid, region_id uuid, srvs int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE i.expected_parent_kind WHEN 'compressor' THEN 'compressor' ELSE 'storage_vessel' END,
         u.id, u.station_id, u.region_id, count(*)::int
    FROM installed_relief_valves i JOIN units u ON u.id = i.unit_id
   WHERE i.archived_at IS NULL AND i.mapping_status = 'needs_equipment_mapping'
     AND i.expected_parent_kind IN ('compressor', 'storage_vessel')
     AND ((i.expected_parent_kind = 'compressor'
           AND NOT EXISTS (SELECT 1 FROM compressors c WHERE c.unit_id = u.id AND c.archived_at IS NULL))
       OR (i.expected_parent_kind = 'storage_vessel'
           AND NOT EXISTS (SELECT 1 FROM storage_vessels v WHERE v.unit_id = u.id AND v.archived_at IS NULL)))
   GROUP BY 1, 2, 3, 4
   ORDER BY 1, 2;
$$;

CREATE OR REPLACE FUNCTION cng_6r_preview()
RETURNS TABLE (preview_fingerprint text, compressors_to_create int, vessels_to_create int, srvs_covered int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6r_proposal())
  SELECT encode(sha256(convert_to('6R|' || coalesce((SELECT string_agg(concat_ws('|', kind, unit_id, srvs), E'\n' ORDER BY kind, unit_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p WHERE kind = 'compressor')::int,
         (SELECT count(*) FROM p WHERE kind = 'storage_vessel')::int,
         (SELECT coalesce(sum(srvs), 0) FROM p)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6r_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (compressors_created int, vessels_created int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; ec int; ev int; nc int; nv int;
BEGIN
  SELECT pv.preview_fingerprint, pv.compressors_to_create, pv.vessels_to_create INTO v_fp, ec, ev FROM cng_6r_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6r commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF ec + ev = 0 THEN RAISE EXCEPTION '6r commit refused: nothing to create' USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6r ON COMMIT DROP AS SELECT * FROM cng_6r_proposal();

  INSERT INTO compressors (station_id, region_id, unit_id, mapping_status, mapping_note, source_file, source_raw)
  SELECT station_id, region_id, unit_id, 'resolved',
         'Created by owner ruling 6r: every Unit has one compressor; model and serial not yet recorded',
         'owner rule 6r', jsonb_build_object('rule', '6r: one compressor per Unit', 'srvs_waiting', srvs)
    FROM _6r WHERE kind = 'compressor';
  GET DIAGNOSTICS nc = ROW_COUNT;

  INSERT INTO storage_vessels (station_id, region_id, unit_id, mapping_status, mapping_note, needs_review, review_reason,
                               source_file, source_raw)
  SELECT station_id, region_id, unit_id, 'resolved',
         'Placeholder created by owner ruling 6r (temporary): stands for the Unit''s storage', true,
         'Placeholder vessel (owner ruling 6r, temporary): replace with the real vessels and re-parent their SRVs',
         'owner rule 6r', jsonb_build_object('rule', '6r: temporary storage placeholder', 'srvs_waiting', srvs)
    FROM _6r WHERE kind = 'storage_vessel';
  GET DIAGNOSTICS nv = ROW_COUNT;

  IF nc <> ec OR nv <> ev THEN RAISE EXCEPTION '6r commit refused: created %/% compressors, %/% vessels', nc, ec, nv, ev USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'units', NULL, NULL, 'service_role:placeholder_equipment_6r',
          format('Phase 6r: %s compressors and %s temporary storage placeholders created for Units that had none (owner ruling). %s',
                 nc, nv, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp,
                                   'units', (SELECT jsonb_agg(jsonb_build_array(kind, unit_id) ORDER BY kind, unit_id) FROM _6r)), now());
  RETURN QUERY SELECT nc, nv, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6r_proposal(), cng_6r_preview(), cng_6r_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6r_proposal(), cng_6r_preview(), cng_6r_commit(text, text) TO service_role;
