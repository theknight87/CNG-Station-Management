-- Phase 6g: Stations and Units for Alex, Canal and Upper, and the 11 East sites (N1).
--
-- Owner ruling 2026-09-24: "accept the proposals" for deliverables/phase-6c-zero-station-regions-review.xlsx.
-- Each workbook row names a source spelling (and at most one other spelling) and its proposed Station and
-- Unit. The owner earlier ruled the 11 N1 names (staged as Delta) are East sites; they get the same
-- proposal rule (a trailing number is the Unit, D2) and are loaded from their own staging rows, never retyped.
--
-- owner_station_rulings holds those rulings as data: one row per source name, with the workbook row and
-- file SHA-256 for provenance. It is the evidence later batches use to confirm Stations of staged assets.
-- The 6g commit creates exactly the distinct Stations and Units the rulings name that do not exist yet,
-- and nothing else: no Unit is created for a Station whose rulings name none (D7), no alias, no mapping
-- decision, no asset. Content-bound (prefix 6G), service_role only. This migration executes no DML.

CREATE TABLE IF NOT EXISTS owner_station_rulings (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ruling_set             text NOT NULL,
  region_id              uuid NOT NULL REFERENCES regions(id),
  source_name_raw        text NOT NULL,
  other_spelling_raw     text NULL,
  station_name           text NOT NULL,
  unit_name              text NULL,
  proposal_reason        text NULL,
  evidence               text NOT NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT osr_names_ck CHECK (btrim(source_name_raw) <> '' AND btrim(station_name) <> ''
                                 AND (unit_name IS NULL OR btrim(unit_name) <> '')),
  CONSTRAINT osr_uq UNIQUE (ruling_set, region_id, source_name_raw)
);
ALTER TABLE owner_station_rulings ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS owner_station_rulings_select ON owner_station_rulings;
CREATE POLICY owner_station_rulings_select ON owner_station_rulings FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()));
REVOKE ALL ON owner_station_rulings FROM PUBLIC, anon, authenticated;
GRANT SELECT ON owner_station_rulings TO authenticated;
COMMENT ON TABLE owner_station_rulings IS
  'Owner-accepted Station/Unit rulings per source spelling (phase 6g). Evidence for creating and later confirming Stations; never a fuzzy rule.';

CREATE OR REPLACE FUNCTION cng_6g_proposal(p_ruling_set text)
RETURNS TABLE (kind text, region_id uuid, station_name text, unit_name text, source_names text[], exists_already boolean)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH r AS MATERIALIZED (SELECT * FROM owner_station_rulings WHERE ruling_set = p_ruling_set),
  st AS (
    SELECT r.region_id, min(r.station_name) AS station_name, cng_normalize_name(r.station_name) AS norm,
           array_agg(DISTINCT r.source_name_raw ORDER BY r.source_name_raw) AS names
      FROM r GROUP BY r.region_id, cng_normalize_name(r.station_name)
  ),
  un AS (
    SELECT r.region_id, cng_normalize_name(r.station_name) AS st_norm, min(r.unit_name) AS unit_name,
           array_agg(DISTINCT r.source_name_raw ORDER BY r.source_name_raw) AS names
      FROM r WHERE r.unit_name IS NOT NULL
     GROUP BY r.region_id, cng_normalize_name(r.station_name), cng_normalize_name(r.unit_name)
  )
  SELECT 'station', st.region_id, st.station_name, NULL::text, st.names,
         EXISTS (SELECT 1 FROM stations s WHERE s.region_id = st.region_id AND s.normalized_name = st.norm)
    FROM st
  UNION ALL
  SELECT 'unit', un.region_id, st.station_name, un.unit_name, un.names,
         EXISTS (SELECT 1 FROM stations s JOIN units u ON u.station_id = s.id
                  WHERE s.region_id = un.region_id AND s.normalized_name = un.st_norm
                    AND u.normalized_name = cng_normalize_name(un.unit_name))
    FROM un JOIN st ON st.region_id = un.region_id AND st.norm = un.st_norm
  ORDER BY 1, 2, 3, 4;
$$;

CREATE OR REPLACE FUNCTION cng_6g_preview(p_ruling_set text)
RETURNS TABLE (preview_fingerprint text, rulings int, stations_to_create int, units_to_create int,
               stations_existing int, units_existing int, alex int, canal int, upper_region int, east int,
               spelling_conflicts int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6g_proposal(p_ruling_set)),
  r AS MATERIALIZED (SELECT * FROM owner_station_rulings WHERE ruling_set = p_ruling_set),
  new_st AS (SELECT * FROM p WHERE kind = 'station' AND NOT exists_already)
  SELECT encode(sha256(convert_to('6G|' || coalesce((SELECT string_agg(concat_ws('|', region_id, source_name_raw, other_spelling_raw,
           station_name, unit_name, evidence), E'\n' ORDER BY region_id, source_name_raw) FROM r), '') || '||' ||
           coalesce((SELECT string_agg(concat_ws('|', kind, region_id, station_name, unit_name, exists_already), E'\n'
           ORDER BY kind, region_id, station_name, unit_name) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM r)::int,
         (SELECT count(*) FROM new_st)::int,
         (SELECT count(*) FROM p WHERE kind = 'unit' AND NOT exists_already)::int,
         (SELECT count(*) FROM p WHERE kind = 'station' AND exists_already)::int,
         (SELECT count(*) FROM p WHERE kind = 'unit' AND exists_already)::int,
         (SELECT count(*) FROM new_st JOIN regions g ON g.id = new_st.region_id WHERE g.name = 'Alex')::int,
         (SELECT count(*) FROM new_st JOIN regions g ON g.id = new_st.region_id WHERE g.name = 'Canal')::int,
         (SELECT count(*) FROM new_st JOIN regions g ON g.id = new_st.region_id WHERE g.name = 'Upper')::int,
         (SELECT count(*) FROM new_st JOIN regions g ON g.id = new_st.region_id WHERE g.name = 'East')::int,
         -- one normalized Station identity written two different ways in the rulings: the commit refuses
         (SELECT count(*) FROM (SELECT 1 FROM r GROUP BY region_id, cng_normalize_name(station_name)
                                 HAVING count(DISTINCT station_name) > 1) x)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6g_commit(p_ruling_set text, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (stations_created int, units_created int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e_st int; e_un int; v_conf int; v_st int; v_un int;
BEGIN
  IF nullif(btrim(p_ruling_set), '') IS NULL OR nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6g commit requires the ruling set and the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.stations_to_create, pv.units_to_create, pv.spelling_conflicts
    INTO v_fp, e_st, e_un, v_conf FROM cng_6g_preview(p_ruling_set) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6g commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF v_conf <> 0 THEN
    RAISE EXCEPTION '6g commit refused: % Station identities are spelled two ways in the rulings', v_conf USING ERRCODE = '22023';
  END IF;
  IF e_st = 0 AND e_un = 0 THEN
    RAISE EXCEPTION '6g commit refused: nothing to create' USING ERRCODE = '22023';
  END IF;

  INSERT INTO stations (region_id, station_name, source_file, source_raw)
  SELECT p.region_id, p.station_name, 'owner rulings ' || p_ruling_set,
         jsonb_build_object('ruling_set', p_ruling_set, 'source_names', to_jsonb(p.source_names))
    FROM cng_6g_proposal(p_ruling_set) p
   WHERE p.kind = 'station' AND NOT p.exists_already;
  GET DIAGNOSTICS v_st = ROW_COUNT;

  INSERT INTO units (station_id, region_id, unit_name, source_file, source_raw)
  SELECT s.id, s.region_id, p.unit_name, 'owner rulings ' || p_ruling_set,
         jsonb_build_object('ruling_set', p_ruling_set, 'source_names', to_jsonb(p.source_names))
    FROM cng_6g_proposal(p_ruling_set) p
    JOIN stations s ON s.region_id = p.region_id AND s.normalized_name = cng_normalize_name(p.station_name)
   WHERE p.kind = 'unit' AND NOT p.exists_already;
  GET DIAGNOSTICS v_un = ROW_COUNT;

  IF v_st <> e_st OR v_un <> e_un THEN
    RAISE EXCEPTION '6g commit refused: % Stations / % Units written, % / % expected', v_st, v_un, e_st, e_un
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'stations', NULL, NULL, 'service_role:owner_station_rulings_6g',
          format('Phase 6g (%s): %s Stations and %s Units created from owner-accepted rulings. %s',
                 p_ruling_set, v_st, v_un, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'stations_created', v_st, 'units_created', v_un), now());
  RETURN QUERY SELECT v_st, v_un, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6g_proposal(text), cng_6g_preview(text), cng_6g_commit(text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6g_proposal(text), cng_6g_preview(text), cng_6g_commit(text, text, text) TO service_role;
