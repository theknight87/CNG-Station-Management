-- Phase 6w: owner Unit rulings by SRV type (2026-09-27).
--
-- Same as 6v, with the SRV manufacturer as an optional part of the ruling. The owner ruled that at a multi-Unit
-- Station each SRV type (manufacturer) belongs to one Unit, e.g. COI on one and DK-LOK on the other; which Unit a
-- type goes to is the owner's ruling (or a numbered raw name), never chosen here. Storage SRVs stay on the Station.
-- p_rulings rows: [station_id, md5(source_station_name_raw), manufacturer|null, unit_id]. service_role only, prefix 6W.

CREATE OR REPLACE FUNCTION cng_6w_proposal(p_rulings jsonb)
RETURNS TABLE (srv_id uuid, unit_id uuid, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT i.id, (e->>3)::uuid, i.updated_at
    FROM jsonb_array_elements(p_rulings) e
    JOIN units u ON u.id = (e->>3)::uuid AND u.station_id = (e->>0)::uuid AND u.archived_at IS NULL
    JOIN installed_relief_valves i ON i.station_id = (e->>0)::uuid AND i.archived_at IS NULL
                                  AND i.mapping_status = 'needs_unit_mapping' AND i.unit_id IS NULL
                                  AND md5(i.source_station_name_raw) = e->>1
                                  AND (e->>2 IS NULL OR i.manufacturer = e->>2)
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6w_preview(p_rulings jsonb)
RETURNS TABLE (preview_fingerprint text, srvs int, rulings_without_srvs int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6w_proposal(p_rulings))
  SELECT encode(sha256(convert_to('6W|' || p_rulings::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', srv_id, unit_id, updated_at), E'\n' ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM jsonb_array_elements(p_rulings) e
           WHERE NOT EXISTS (SELECT 1 FROM p JOIN installed_relief_valves i ON i.id = p.srv_id
                              WHERE p.unit_id = (e->>3)::uuid AND md5(i.source_station_name_raw) = e->>1
                                AND (e->>2 IS NULL OR i.manufacturer = e->>2)))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6w_commit(p_rulings jsonb, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (srvs_linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; ne int; nr int; n int;
BEGIN
  SELECT pv.preview_fingerprint, pv.srvs, pv.rulings_without_srvs INTO v_fp, ne, nr FROM cng_6w_preview(p_rulings) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6w commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF ne = 0 OR nr > 0 THEN RAISE EXCEPTION '6w commit refused: % SRVs, % rulings match no SRV', ne, nr USING ERRCODE = '22023'; END IF;
  DROP TABLE IF EXISTS _6w;
  CREATE TEMP TABLE _6w ON COMMIT DROP AS SELECT * FROM cng_6w_proposal(p_rulings);
  UPDATE installed_relief_valves i
     SET unit_id = p.unit_id, mapping_status = 'needs_equipment_mapping',
         review_reason = coalesce(i.review_reason || '; ', '') || 'Unit by owner ruling 6w'
    FROM _6w p WHERE i.id = p.srv_id AND i.mapping_status = 'needs_unit_mapping' AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> ne THEN RAISE EXCEPTION '6w commit refused: % linked, % expected', n, ne USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, NULL, 'service_role:unit_rulings_srv_6w',
          format('Phase 6w: owner Unit rulings — %s SRVs given a Unit. %s', n, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'rulings', p_rulings,
                                   'srvs', (SELECT jsonb_agg(jsonb_build_array(srv_id, unit_id) ORDER BY srv_id) FROM _6w)), now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6w_proposal(jsonb), cng_6w_preview(jsonb), cng_6w_commit(jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6w_proposal(jsonb), cng_6w_preview(jsonb), cng_6w_commit(jsonb, text, text) TO service_role;
