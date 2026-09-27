-- Phase 6v: owner Unit rulings for installed SRVs awaiting a Unit (2026-09-27).
--
-- The owner ruled which Unit the SRVs of a raw source name belong to (first case: "دائري الهرم 1 فويل أب" -> Unit
-- "فويل اب الدائرى 1", "... 2 ..." -> "... 2", where the number sits mid-name so the 6t trailing-number rule missed it).
-- p_rulings rows: [station_id, md5(source_station_name_raw), unit_id] — the raw name is identified by its md5, read
-- from the data, never retyped. Every active needs_unit_mapping SRV of that Station with that exact raw name gets the
-- Unit and moves to needs_equipment_mapping (6m/6r/6s then parent it). The Unit must belong to the Station
-- (the composite FK enforces it too). service_role only, content-bound, prefix 6V. No DML here.

CREATE OR REPLACE FUNCTION cng_6v_proposal(p_rulings jsonb)
RETURNS TABLE (srv_id uuid, unit_id uuid, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT i.id, (e->>2)::uuid, i.updated_at
    FROM jsonb_array_elements(p_rulings) e
    JOIN units u ON u.id = (e->>2)::uuid AND u.station_id = (e->>0)::uuid AND u.archived_at IS NULL
    JOIN installed_relief_valves i ON i.station_id = (e->>0)::uuid AND i.archived_at IS NULL
                                  AND i.mapping_status = 'needs_unit_mapping' AND i.unit_id IS NULL
                                  AND md5(i.source_station_name_raw) = e->>1
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6v_preview(p_rulings jsonb)
RETURNS TABLE (preview_fingerprint text, srvs int, rulings_without_srvs int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6v_proposal(p_rulings))
  SELECT encode(sha256(convert_to('6V|' || p_rulings::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', srv_id, unit_id, updated_at), E'\n' ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM jsonb_array_elements(p_rulings) e
           WHERE NOT EXISTS (SELECT 1 FROM p JOIN installed_relief_valves i ON i.id = p.srv_id
                              WHERE p.unit_id = (e->>2)::uuid AND md5(i.source_station_name_raw) = e->>1))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6v_commit(p_rulings jsonb, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (srvs_linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; ne int; nr int; n int;
BEGIN
  SELECT pv.preview_fingerprint, pv.srvs, pv.rulings_without_srvs INTO v_fp, ne, nr FROM cng_6v_preview(p_rulings) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6v commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF ne = 0 OR nr > 0 THEN RAISE EXCEPTION '6v commit refused: % SRVs, % rulings match no SRV', ne, nr USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6v ON COMMIT DROP AS SELECT * FROM cng_6v_proposal(p_rulings);
  UPDATE installed_relief_valves i
     SET unit_id = p.unit_id, mapping_status = 'needs_equipment_mapping',
         review_reason = coalesce(i.review_reason || '; ', '') || 'Unit by owner ruling 6v'
    FROM _6v p WHERE i.id = p.srv_id AND i.mapping_status = 'needs_unit_mapping' AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> ne THEN RAISE EXCEPTION '6v commit refused: % linked, % expected', n, ne USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, NULL, 'service_role:unit_rulings_srv_6v',
          format('Phase 6v: owner Unit rulings — %s SRVs given a Unit. %s', n, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'rulings', p_rulings,
                                   'srvs', (SELECT jsonb_agg(jsonb_build_array(srv_id, unit_id) ORDER BY srv_id) FROM _6v)), now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6v_proposal(jsonb), cng_6v_preview(jsonb), cng_6v_commit(jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6v_proposal(jsonb), cng_6v_preview(jsonb), cng_6v_commit(jsonb, text, text) TO service_role;
