-- Phase 6u: النوبارية — the owner's structure for its snapshot SRVs (ruling 2026-09-27).
--
-- Owner: the 17 snapshot SRVs named only "النوبارية" belong to two Stations, each with ONE Unit:
--   * النوبارية 59 — a Kwangshin compressor carrying 5 DK-LOK SRVs, and an EKC storage skid carrying 3 SRVs (new Station);
--   * النوبارية 81 — the Station already recorded as "النوباريه 81 خيري النجار" (its EKC vessel), whose compressor is the
--     SAFE compressor recorded under Unit "النوباريه 81" of Station "النوباريه"; it carries 6 Technical SRVs, and the
--     EKC vessel 3 SRVs.
-- 57 and 79 are out of service and are left exactly as recorded. The six EKC Storage SRVs carry no serial, so the first
-- three by id go to 59's skid and the rest to 81's vessel (positional, as in 6s). The function finds every record from
-- the ids passed and REFUSES unless it finds exactly 5 DK-LOK + 6 Technical Stage SRVs, 6 EKC Storage SRVs, one SAFE
-- compressor and one vessel at 81. resolved_by = the first active admin (the owner). service_role only, prefix 6U.

CREATE OR REPLACE FUNCTION cng_6u_proposal(p_old_station uuid, p_81_station uuid, p_81_old_unit uuid)
RETURNS TABLE (srv_id uuid, target text, kind text, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH s AS (
    SELECT i.id, i.location_raw, i.manufacturer, i.updated_at,
           row_number() OVER (PARTITION BY i.location_raw ORDER BY i.id) AS k
      FROM installed_relief_valves i
     WHERE i.station_id = p_old_station AND i.archived_at IS NULL AND i.mapping_status = 'needs_unit_mapping' AND i.unit_id IS NULL
  )
  SELECT s.id,
         CASE WHEN s.location_raw = 'Stage' AND s.manufacturer = 'DK-LOK' THEN '59'
              WHEN s.location_raw = 'Stage' AND s.manufacturer = 'Technical' THEN '81'
              WHEN s.location_raw = 'Storage' AND s.manufacturer = 'EKC' THEN CASE WHEN s.k <= 3 THEN '59' ELSE '81' END END,
         CASE s.location_raw WHEN 'Stage' THEN 'compressor' ELSE 'storage_vessel' END, s.updated_at
    FROM s ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6u_preview(p_old_station uuid, p_81_station uuid, p_81_old_unit uuid, p_59_name text)
RETURNS TABLE (preview_fingerprint text, to_59 int, to_81 int, unplaced int, safe_compressors int, vessels_at_81 int, units_at_81 int, name_taken int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6u_proposal(p_old_station, p_81_station, p_81_old_unit))
  SELECT encode(sha256(convert_to('6U|' || concat_ws('|', p_old_station, p_81_station, p_81_old_unit, p_59_name) || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', srv_id, target, updated_at), E'\n' ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p WHERE target = '59')::int,
         (SELECT count(*) FROM p WHERE target = '81')::int,
         (SELECT count(*) FROM p WHERE target IS NULL)::int,
         (SELECT count(*) FROM compressors c WHERE c.unit_id = p_81_old_unit AND c.station_id = p_old_station AND c.archived_at IS NULL)::int,
         (SELECT count(*) FROM storage_vessels v WHERE v.station_id = p_81_station AND v.archived_at IS NULL)::int,
         (SELECT count(*) FROM units u WHERE u.station_id = p_81_station AND u.archived_at IS NULL)::int,
         (SELECT count(*) FROM stations x JOIN stations o ON o.id = p_old_station
           WHERE x.region_id = o.region_id AND x.normalized_name = cng_normalize_name(p_59_name))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6u_commit(p_old_station uuid, p_81_station uuid, p_81_old_unit uuid, p_59_name text,
                                         p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (srvs_resolved int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; a int; b int; un int; sc int; nv int; nu int; nt int; n int;
        v_owner uuid; v_region uuid; st59 uuid; u59 uuid; c59 uuid; v59 uuid; u81 uuid; c81 uuid; v81 uuid;
BEGIN
  SELECT pv.preview_fingerprint, pv.to_59, pv.to_81, pv.unplaced, pv.safe_compressors, pv.vessels_at_81, pv.units_at_81, pv.name_taken
    INTO v_fp, a, b, un, sc, nv, nu, nt FROM cng_6u_preview(p_old_station, p_81_station, p_81_old_unit, p_59_name) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6u commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF (a, b, un, sc, nv, nu, nt) IS DISTINCT FROM (8, 9, 0, 1, 1, 1, 0) THEN
    RAISE EXCEPTION '6u commit refused: found 59=% 81=% unplaced=% SAFE=% vessels81=% units81=% name_taken=%', a, b, un, sc, nv, nu, nt
      USING ERRCODE = '22023';
  END IF;
  SELECT id INTO v_owner FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;
  SELECT region_id INTO v_region FROM stations WHERE id = p_old_station;
  CREATE TEMP TABLE _6u ON COMMIT DROP AS SELECT * FROM cng_6u_proposal(p_old_station, p_81_station, p_81_old_unit);

  -- النوبارية 59: Station, its one Unit, the Kwangshin compressor, the EKC skid
  INSERT INTO stations (region_id, station_name) VALUES (v_region, p_59_name) RETURNING id INTO st59;
  INSERT INTO units (station_id, region_id, unit_name, source_file, source_raw)
  VALUES (st59, v_region, p_59_name, 'owner ruling 6u', jsonb_build_object('rule', '6u: owner structure for النوبارية')) RETURNING id INTO u59;
  INSERT INTO compressors (station_id, region_id, unit_id, mapping_status, manufacturer, manufacturer_raw, mapping_note, source_file)
  VALUES (st59, v_region, u59, 'resolved', 'Kwangshin', 'Kwangshin', 'Owner ruling 6u', 'owner ruling 6u') RETURNING id INTO c59;
  INSERT INTO storage_vessels (station_id, region_id, unit_id, mapping_status, manufacturer, manufacturer_raw, mapping_note, source_file)
  VALUES (st59, v_region, u59, 'resolved', 'EKC', 'EKC', 'Owner ruling 6u: EKC storage skid', 'owner ruling 6u') RETURNING id INTO v59;

  -- النوبارية 81: its Unit and vessel as recorded; the SAFE compressor moves to it
  SELECT id INTO u81 FROM units WHERE station_id = p_81_station AND archived_at IS NULL;
  SELECT id INTO v81 FROM storage_vessels WHERE station_id = p_81_station AND archived_at IS NULL;
  UPDATE compressors SET station_id = p_81_station, region_id = (SELECT region_id FROM stations WHERE id = p_81_station), unit_id = u81,
         mapping_note = coalesce(mapping_note || '; ', '') || 'moved to النوبارية 81 by owner ruling 6u'
   WHERE unit_id = p_81_old_unit AND station_id = p_old_station AND archived_at IS NULL
  RETURNING id INTO c81;

  UPDATE installed_relief_valves i
     SET station_id = CASE p.target WHEN '59' THEN st59 ELSE p_81_station END,
         region_id = CASE p.target WHEN '59' THEN v_region ELSE (SELECT region_id FROM stations WHERE id = p_81_station) END,
         unit_id = CASE p.target WHEN '59' THEN u59 ELSE u81 END,
         compressor_id = CASE WHEN p.kind = 'compressor' THEN CASE p.target WHEN '59' THEN c59 ELSE c81 END END,
         storage_vessel_id = CASE WHEN p.kind = 'storage_vessel' THEN CASE p.target WHEN '59' THEN v59 ELSE v81 END END,
         mapping_status = 'resolved', resolved_by = v_owner, resolved_at = now(),
         review_reason = coalesce(i.review_reason || '; ', '') || 'النوبارية ' || p.target || ' by owner ruling 6u'
    FROM _6u p WHERE i.id = p.srv_id AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 17 THEN RAISE EXCEPTION '6u commit refused: % SRVs updated, 17 expected', n USING ERRCODE = '40001'; END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'stations', st59, v_owner, 'service_role:nubaria_split_6u',
          format('Phase 6u: النوبارية 59 created (Unit, Kwangshin compressor, EKC skid); SAFE compressor moved to النوبارية 81; 17 SRVs resolved (owner ruling). %s', coalesce(p_reason, '')),
          jsonb_build_object('safe_compressor_unit', p_81_old_unit, 'old_station', p_old_station),
          jsonb_build_object('preview_fingerprint', v_fp, 'station_59', st59, 'station_81', p_81_station,
                             'srvs', (SELECT jsonb_agg(jsonb_build_array(srv_id, target, kind) ORDER BY srv_id) FROM _6u)), now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6u_proposal(uuid, uuid, uuid), cng_6u_preview(uuid, uuid, uuid, text),
                       cng_6u_commit(uuid, uuid, uuid, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6u_proposal(uuid, uuid, uuid), cng_6u_preview(uuid, uuid, uuid, text),
                          cng_6u_commit(uuid, uuid, uuid, text, text, text) TO service_role;
