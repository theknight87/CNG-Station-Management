-- Phase 6q: move a Station (and everything under it) to another Region.
--
-- Owner ruling 2026-09-24 (عزبة مختار, "أيوه انقلها Delta"): the station snapshot places the Station in Delta. Region is
-- part of Station identity and every child carries (station_id, region_id) under NON-deferrable composite FKs, so the
-- Station and all of its rows move in ONE statement (data-modifying CTEs; the FK checks run once, at its end). Active
-- installed SRVs in the new Region still awaiting a Station whose raw source name normalizes to the Station's name are
-- then given that Station (needs_unit_mapping; the 6l/6m rulings may be re-run). service_role only, content-bound,
-- prefix 6Q. No DML here.

CREATE OR REPLACE FUNCTION cng_6q_preview(p_station_id uuid, p_region text)
RETURNS TABLE (preview_fingerprint text, station_name text, from_region text, units int, compressors int, dispensers int,
               storage_vessels int, recovery_tanks int, gas_detectors int, hoses int, installed_srvs int, srvs_to_relink int,
               refused int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH s AS (SELECT st.*, g.name AS rn FROM stations st JOIN regions g ON g.id = st.region_id WHERE st.id = p_station_id),
       r AS (SELECT id FROM regions WHERE name = p_region),
       rl AS (SELECT i.id, i.updated_at FROM installed_relief_valves i, s, r
               WHERE i.archived_at IS NULL AND i.mapping_status = 'needs_station_mapping' AND i.region_id = r.id
                 AND cng_normalize_name(i.source_station_name_raw) = s.normalized_name)
  SELECT encode(sha256(convert_to('6Q|' || p_station_id || '|' || coalesce(p_region, '') || '|' ||
           coalesce((SELECT updated_at::text FROM s), '') || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', id, updated_at), E'\n' ORDER BY id) FROM rl), ''), 'UTF8')), 'hex'),
         (SELECT station_name FROM s), (SELECT rn FROM s),
         (SELECT count(*) FROM units WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM compressors WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM dispensers WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM storage_vessels WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM recovery_tanks WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM gas_detectors WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM hoses WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM installed_relief_valves WHERE station_id = p_station_id)::int,
         (SELECT count(*) FROM rl)::int,
         ((SELECT count(*) FROM s) = 0 OR (SELECT count(*) FROM r) = 0
          OR (SELECT s.region_id FROM s) = (SELECT id FROM r)
          OR EXISTS (SELECT 1 FROM stations x, s, r WHERE x.region_id = r.id AND x.normalized_name = s.normalized_name))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6q_commit(p_station_id uuid, p_region text, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (moved_rows int, srvs_relinked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; rf int; v_to uuid; v_from uuid; n int; nr int; v_norm text;
BEGIN
  SELECT pv.preview_fingerprint, pv.refused INTO v_fp, rf FROM cng_6q_preview(p_station_id, p_region) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6q commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF rf > 0 THEN RAISE EXCEPTION '6q commit refused: station missing, region unknown/same, or name taken in target' USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_to FROM regions WHERE name = p_region;
  SELECT region_id, normalized_name INTO v_from, v_norm FROM stations WHERE id = p_station_id;

  WITH a AS (UPDATE stations SET region_id = v_to WHERE id = p_station_id RETURNING 1),
       b AS (UPDATE units SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       c AS (UPDATE compressors SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       d AS (UPDATE dispensers SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       e AS (UPDATE storage_vessels SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       f AS (UPDATE recovery_tanks SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       g AS (UPDATE gas_detectors SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       h AS (UPDATE gas_detector_presence SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       i AS (UPDATE hoses SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       j AS (UPDATE installed_relief_valves SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       k AS (UPDATE station_aliases SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       l AS (UPDATE unit_aliases SET region_id = v_to WHERE station_id = p_station_id RETURNING 1),
       m AS (UPDATE import_mapping_decisions SET region_id = v_to WHERE confirmed_station_id = p_station_id RETURNING 1),
       o AS (UPDATE warehouse_relief_valves SET target_region_id = v_to WHERE target_station_id = p_station_id RETURNING 1)
  SELECT (SELECT count(*) FROM a) + (SELECT count(*) FROM b) + (SELECT count(*) FROM c) + (SELECT count(*) FROM d)
       + (SELECT count(*) FROM e) + (SELECT count(*) FROM f) + (SELECT count(*) FROM g) + (SELECT count(*) FROM h)
       + (SELECT count(*) FROM i) + (SELECT count(*) FROM j) + (SELECT count(*) FROM k) + (SELECT count(*) FROM l)
       + (SELECT count(*) FROM m) + (SELECT count(*) FROM o) INTO n;

  UPDATE installed_relief_valves x SET station_id = p_station_id, mapping_status = 'needs_unit_mapping',
         review_reason = coalesce(x.review_reason || '; ', '') || 'Station after its move to ' || p_region || ' (owner ruling 6q)'
   WHERE x.archived_at IS NULL AND x.mapping_status = 'needs_station_mapping' AND x.region_id = v_to
     AND cng_normalize_name(x.source_station_name_raw) = v_norm;
  GET DIAGNOSTICS nr = ROW_COUNT;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'stations', p_station_id, NULL, 'service_role:station_region_move_6q',
          format('Phase 6q: Station moved to %s with %s rows under it; %s installed SRVs relinked (owner ruling). %s',
                 p_region, n, nr, coalesce(p_reason, '')),
          jsonb_build_object('region_id', v_from), jsonb_build_object('region_id', v_to, 'preview_fingerprint', v_fp), now());
  RETURN QUERY SELECT n, nr, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6q_preview(uuid, text), cng_6q_commit(uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6q_preview(uuid, text), cng_6q_commit(uuid, text, text, text) TO service_role;
