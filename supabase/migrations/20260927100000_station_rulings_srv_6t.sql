-- Phase 6t: owner Station rulings for installed SRVs awaiting a Station (2026-09-27).
--
-- The owner ruled, name by name, which Station each unmatched snapshot name is (an existing Station, or a new one named
-- as in the file, optionally with numbered Units, optionally renaming the existing Station to the file's spelling).
-- p_rulings rows: [region, raw source name, target Station name, units to create (array|null), rename_to (text|null)].
-- Every name is copied from the data by scripts/import/6t_station_rulings.py, never typed.
-- For each ruling: the target Station is found in the Region by normalized name, else created (with the given Units,
-- else one Unit named as the Station — the 6k one-Unit rule); then every active SRV of that Region still awaiting a
-- Station whose normalized raw name equals the ruling's gets the Station, and its Unit when the Station has one Unit,
-- or when the raw name ends in a number n and exactly one Unit of the Station ends in n. Otherwise it awaits its Unit.
-- service_role only, content-bound, prefix 6T. No DML here.

CREATE OR REPLACE FUNCTION cng_6t_proposal(p_rulings jsonb)
RETURNS TABLE (srv_id uuid, region text, raw text, target text, station_id uuid, unit_name text, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH r AS (
    SELECT e->>0 AS region, e->>1 AS raw, e->>2 AS target, e->3 AS units, g.id AS region_id
      FROM jsonb_array_elements(p_rulings) e JOIN regions g ON g.name = e->>0
  ), unit_names AS (   -- the Units the target will have after the batch (existing, or the ones the batch creates)
    SELECT r.raw, r.region, coalesce(
             (SELECT array_agg(u.unit_name ORDER BY u.unit_name) FROM stations s JOIN units u ON u.station_id = s.id
               WHERE s.region_id = r.region_id AND s.normalized_name = cng_normalize_name(r.target) AND s.archived_at IS NULL AND u.archived_at IS NULL),
             CASE WHEN jsonb_typeof(r.units) = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(r.units)) ELSE ARRAY[r.target] END) AS names
      FROM r
  )
  SELECT i.id, r.region, r.raw, r.target,
         (SELECT s.id FROM stations s WHERE s.region_id = r.region_id AND s.normalized_name = cng_normalize_name(r.target) AND s.archived_at IS NULL),
         CASE WHEN cardinality(n.names) = 1 THEN n.names[1]
              WHEN substring(cng_normalize_name(r.raw) FROM '(\d+)\s*$') IS NOT NULL
                   AND (SELECT count(*) FROM unnest(n.names) x
                         WHERE substring(cng_normalize_name(x) FROM '(\d+)\s*$') = substring(cng_normalize_name(r.raw) FROM '(\d+)\s*$')) = 1
              THEN (SELECT x FROM unnest(n.names) x
                     WHERE substring(cng_normalize_name(x) FROM '(\d+)\s*$') = substring(cng_normalize_name(r.raw) FROM '(\d+)\s*$')) END,
         i.updated_at
    FROM r JOIN unit_names n ON n.raw = r.raw AND n.region = r.region
    JOIN installed_relief_valves i ON i.region_id = r.region_id AND i.archived_at IS NULL AND i.mapping_status = 'needs_station_mapping'
                                  AND cng_normalize_name(i.source_station_name_raw) = cng_normalize_name(r.raw)
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6t_preview(p_rulings jsonb)
RETURNS TABLE (preview_fingerprint text, srvs int, with_unit int, stations_to_create int, renames int, rulings_without_srvs int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6t_proposal(p_rulings)),
       r AS (SELECT e->>0 AS region, e->>1 AS raw, e->>2 AS target, e->>4 AS rename_to FROM jsonb_array_elements(p_rulings) e)
  SELECT encode(sha256(convert_to('6T|' || p_rulings::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', srv_id, station_id, unit_name, updated_at), E'\n' ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE unit_name IS NOT NULL)::int,
         (SELECT count(DISTINCT (region, cng_normalize_name(target))) FROM r
           WHERE NOT EXISTS (SELECT 1 FROM stations s JOIN regions g ON g.id = s.region_id
                              WHERE g.name = r.region AND s.normalized_name = cng_normalize_name(r.target) AND s.archived_at IS NULL))::int,
         (SELECT count(*) FROM r WHERE rename_to IS NOT NULL)::int,
         (SELECT count(*) FROM r WHERE NOT EXISTS (SELECT 1 FROM p WHERE p.raw = r.raw AND p.region = r.region))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6t_commit(p_rulings jsonb, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (stations_created int, units_created int, srvs_linked int, srvs_with_unit int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; ne int; nr int; sc int := 0; uc int := 0; c int; n int; nu int; x record;
BEGIN
  SELECT pv.preview_fingerprint, pv.srvs, pv.rulings_without_srvs INTO v_fp, ne, nr FROM cng_6t_preview(p_rulings) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6t commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF ne = 0 OR nr > 0 THEN RAISE EXCEPTION '6t commit refused: % SRVs, % rulings match no SRV', ne, nr USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6t ON COMMIT DROP AS SELECT * FROM cng_6t_proposal(p_rulings);

  -- 1. Stations (and their Units) the rulings create
  FOR x IN SELECT DISTINCT ON (g.id, cng_normalize_name(e->>2)) g.id AS region_id, e->>2 AS target, e->3 AS units
             FROM jsonb_array_elements(p_rulings) e JOIN regions g ON g.name = e->>0
            WHERE NOT EXISTS (SELECT 1 FROM stations s WHERE s.region_id = g.id AND s.normalized_name = cng_normalize_name(e->>2) AND s.archived_at IS NULL)
  LOOP
    WITH s AS (INSERT INTO stations (region_id, station_name) VALUES (x.region_id, x.target) RETURNING id)
    INSERT INTO units (station_id, region_id, unit_name, source_file, source_raw)
    SELECT s.id, x.region_id, un, 'owner ruling 6t', jsonb_build_object('rule', '6t: Station named as in the 24/9/2026 snapshot')
      FROM s, unnest(CASE WHEN jsonb_typeof(x.units) = 'array' THEN ARRAY(SELECT jsonb_array_elements_text(x.units)) ELSE ARRAY[x.target] END) un;
    GET DIAGNOSTICS c = ROW_COUNT; sc := sc + 1; uc := uc + c;
  END LOOP;

  -- 2. renames to the file's spelling (the Station and a Unit that carried the Station's old name)
  FOR x IN SELECT g.id AS region_id, e->>2 AS target, e->>4 AS rename_to
             FROM jsonb_array_elements(p_rulings) e JOIN regions g ON g.name = e->>0 WHERE e->>4 IS NOT NULL
  LOOP
    UPDATE units u SET unit_name = x.rename_to FROM stations s
     WHERE u.station_id = s.id AND s.region_id = x.region_id AND s.normalized_name = cng_normalize_name(x.target)
       AND u.normalized_name = s.normalized_name;
    UPDATE stations SET station_name = x.rename_to WHERE region_id = x.region_id AND normalized_name = cng_normalize_name(x.target);
  END LOOP;

  -- 3. the SRVs: Station always, Unit when determined
  UPDATE installed_relief_valves i
     SET station_id = s.id, unit_id = u.id,
         mapping_status = CASE WHEN u.id IS NULL THEN 'needs_unit_mapping' ELSE 'needs_equipment_mapping' END::srv_mapping_status,
         review_reason = coalesce(i.review_reason || '; ', '') || 'Station by owner ruling 6t'
    FROM _6t p
    JOIN stations s ON s.region_id = (SELECT id FROM regions WHERE name = p.region)
                   AND s.normalized_name = cng_normalize_name(CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(p_rulings) e
                                                                                   WHERE e->>1 = p.raw AND e->>0 = p.region AND e->>4 IS NOT NULL)
                                                                       THEN (SELECT e->>4 FROM jsonb_array_elements(p_rulings) e WHERE e->>1 = p.raw AND e->>0 = p.region)
                                                                       ELSE p.target END)
                   AND s.archived_at IS NULL
    LEFT JOIN units u ON u.station_id = s.id AND u.archived_at IS NULL
                     AND u.normalized_name = cng_normalize_name(CASE WHEN p.unit_name = p.target AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_rulings) e
                                                                         WHERE e->>1 = p.raw AND e->>0 = p.region AND e->>4 IS NOT NULL)
                                                                     THEN (SELECT e->>4 FROM jsonb_array_elements(p_rulings) e WHERE e->>1 = p.raw AND e->>0 = p.region)
                                                                     ELSE p.unit_name END)
   WHERE i.id = p.srv_id AND i.mapping_status = 'needs_station_mapping' AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;
  SELECT count(*) INTO nu FROM installed_relief_valves i JOIN _6t p ON p.srv_id = i.id WHERE i.unit_id IS NOT NULL;

  IF n <> ne THEN RAISE EXCEPTION '6t commit refused: % linked, % expected', n, ne USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, NULL, 'service_role:station_rulings_srv_6t',
          format('Phase 6t: owner Station rulings — %s Stations / %s Units created, %s SRVs given a Station (%s also a Unit). %s',
                 sc, uc, n, nu, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'rulings', p_rulings,
                                   'srvs', (SELECT jsonb_agg(srv_id ORDER BY srv_id) FROM _6t)), now());
  RETURN QUERY SELECT sc, uc, n, nu, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6t_proposal(jsonb), cng_6t_preview(jsonb), cng_6t_commit(jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6t_proposal(jsonb), cng_6t_preview(jsonb), cng_6t_commit(jsonb, text, text) TO service_role;
