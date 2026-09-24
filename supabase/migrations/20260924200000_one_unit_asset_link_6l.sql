-- Phase 6l: records at a Station with exactly one Unit are linked to that Unit.
--
-- Owner ruling 2026-09-24 (asked explicitly, CLAUDE.md §4 requires it): "أيوه، اربطهم كلهم" - every storage vessel,
-- recovery tank, gas detector, hose and installed SRV that has a Station but no Unit, at a Station with exactly one
-- Unit, belongs to that Unit. Assets become 'resolved'; installed SRVs become 'needs_equipment_mapping' (the equipment
-- parent is still never inferred). Each record gets a mapping_note naming the ruling; one audit row lists every id.
-- Records changed since the preview are refused (updated_at guard). service_role only, prefix 6L. No DML here.

CREATE OR REPLACE FUNCTION cng_6l_proposal()
RETURNS TABLE (entity_table text, entity_id uuid, station_id uuid, unit_id uuid, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH one AS MATERIALIZED (
    SELECT u.station_id, min(u.id::text)::uuid AS unit_id FROM units u WHERE u.archived_at IS NULL
     GROUP BY u.station_id HAVING count(*) = 1
  )
  SELECT 'storage_vessels', a.id, a.station_id, one.unit_id, a.updated_at FROM storage_vessels a JOIN one USING (station_id)
   WHERE a.unit_id IS NULL AND a.archived_at IS NULL AND a.mapping_status = 'needs_unit_mapping'
  UNION ALL
  SELECT 'recovery_tanks', a.id, a.station_id, one.unit_id, a.updated_at FROM recovery_tanks a JOIN one USING (station_id)
   WHERE a.unit_id IS NULL AND a.archived_at IS NULL AND a.mapping_status = 'needs_unit_mapping'
  UNION ALL
  SELECT 'gas_detectors', a.id, a.station_id, one.unit_id, a.updated_at FROM gas_detectors a JOIN one USING (station_id)
   WHERE a.unit_id IS NULL AND a.archived_at IS NULL AND a.mapping_status = 'needs_unit_mapping'
  UNION ALL
  SELECT 'hoses', a.id, a.station_id, one.unit_id, a.updated_at FROM hoses a JOIN one USING (station_id)
   WHERE a.unit_id IS NULL AND a.archived_at IS NULL AND a.mapping_status = 'needs_unit_mapping'
  UNION ALL
  SELECT 'installed_relief_valves', a.id, a.station_id, one.unit_id, a.updated_at FROM installed_relief_valves a JOIN one USING (station_id)
   WHERE a.unit_id IS NULL AND a.archived_at IS NULL AND a.mapping_status = 'needs_unit_mapping'
  ORDER BY 1, 2;
$$;

CREATE OR REPLACE FUNCTION cng_6l_preview()
RETURNS TABLE (preview_fingerprint text, total int, storage_vessels int, recovery_tanks int, gas_detectors int, hoses int,
               installed_srvs int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6l_proposal())
  SELECT encode(sha256(convert_to('6L|' || coalesce((SELECT string_agg(concat_ws('|', entity_table, entity_id, unit_id, updated_at), E'\n'
           ORDER BY entity_table, entity_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE entity_table = 'storage_vessels')::int,
         (SELECT count(*) FROM p WHERE entity_table = 'recovery_tanks')::int,
         (SELECT count(*) FROM p WHERE entity_table = 'gas_detectors')::int,
         (SELECT count(*) FROM p WHERE entity_table = 'hoses')::int,
         (SELECT count(*) FROM p WHERE entity_table = 'installed_relief_valves')::int;
$$;

CREATE OR REPLACE FUNCTION cng_6l_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; n int := 0; c int; v_note text := 'Unit from owner ruling 6l: the Station has exactly one Unit';
BEGIN
  SELECT pv.preview_fingerprint, pv.total INTO v_fp, e FROM cng_6l_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6l commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 THEN RAISE EXCEPTION '6l commit refused: nothing to link' USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6l ON COMMIT DROP AS SELECT * FROM cng_6l_proposal();

  UPDATE storage_vessels a SET unit_id = p.unit_id, mapping_status = 'resolved', mapping_note = v_note
    FROM _6l p WHERE p.entity_table = 'storage_vessels' AND a.id = p.entity_id AND a.unit_id IS NULL AND a.updated_at = p.updated_at;
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  UPDATE recovery_tanks a SET unit_id = p.unit_id, mapping_status = 'resolved', mapping_note = v_note
    FROM _6l p WHERE p.entity_table = 'recovery_tanks' AND a.id = p.entity_id AND a.unit_id IS NULL AND a.updated_at = p.updated_at;
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  UPDATE gas_detectors a SET unit_id = p.unit_id, mapping_status = 'resolved', mapping_note = v_note
    FROM _6l p WHERE p.entity_table = 'gas_detectors' AND a.id = p.entity_id AND a.unit_id IS NULL AND a.updated_at = p.updated_at;
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  UPDATE hoses a SET unit_id = p.unit_id, mapping_status = 'resolved', mapping_note = v_note
    FROM _6l p WHERE p.entity_table = 'hoses' AND a.id = p.entity_id AND a.unit_id IS NULL AND a.updated_at = p.updated_at;
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;
  UPDATE installed_relief_valves a SET unit_id = p.unit_id, mapping_status = 'needs_equipment_mapping',
         mapping_note = v_note || '; equipment parent not proven'
    FROM _6l p WHERE p.entity_table = 'installed_relief_valves' AND a.id = p.entity_id AND a.unit_id IS NULL AND a.updated_at = p.updated_at;
  GET DIAGNOSTICS c = ROW_COUNT; n := n + c;

  IF n <> e THEN RAISE EXCEPTION '6l commit refused: % linked, % expected', n, e USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'units', NULL, NULL, 'service_role:one_unit_asset_link_6l',
          format('Phase 6l: %s records at one-Unit Stations linked to that Unit (owner ruling). %s', n, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp,
                                   'records', (SELECT jsonb_agg(jsonb_build_array(entity_table, entity_id, unit_id) ORDER BY entity_table, entity_id) FROM _6l)),
          now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6l_proposal(), cng_6l_preview(), cng_6l_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6l_proposal(), cng_6l_preview(), cng_6l_commit(text, text) TO service_role;
