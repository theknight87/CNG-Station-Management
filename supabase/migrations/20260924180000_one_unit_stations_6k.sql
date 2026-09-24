-- Phase 6k: a Unit named as its Station for every Station that still has no Unit.
--
-- Owner 2026-09-24: "yes apply the rule" - the one-Unit rule (a Station with one Unit has that Unit named as the
-- Station; 6c-2 / SU2) applied to the Stations no source row describes at Unit level. Only the Unit record is created:
-- no attribute, compressor or asset is attached by this step. service_role only, content-bound (prefix 6K).
-- This migration executes no DML.

CREATE OR REPLACE FUNCTION cng_6k_proposal()
RETURNS TABLE (station_id uuid, region_id uuid, unit_name text)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT s.id, s.region_id, s.station_name
    FROM stations s
   WHERE s.archived_at IS NULL
     AND NOT EXISTS (SELECT 1 FROM units u WHERE u.station_id = s.id)
   ORDER BY s.id;
$$;

CREATE OR REPLACE FUNCTION cng_6k_preview()
RETURNS TABLE (preview_fingerprint text, units_to_create int, alex int, canal int, upper_region int, east int, west int, delta int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT p.*, g.name AS region FROM cng_6k_proposal() p JOIN regions g ON g.id = p.region_id)
  SELECT encode(sha256(convert_to('6K|' || coalesce((SELECT string_agg(concat_ws('|', station_id, region_id, unit_name), E'\n'
           ORDER BY station_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE region = 'Alex')::int, (SELECT count(*) FROM p WHERE region = 'Canal')::int,
         (SELECT count(*) FROM p WHERE region = 'Upper')::int, (SELECT count(*) FROM p WHERE region = 'East')::int,
         (SELECT count(*) FROM p WHERE region = 'West')::int, (SELECT count(*) FROM p WHERE region = 'Delta')::int;
$$;

CREATE OR REPLACE FUNCTION cng_6k_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (units_created int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; v int;
BEGIN
  SELECT pv.preview_fingerprint, pv.units_to_create INTO v_fp, e FROM cng_6k_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6k commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 THEN RAISE EXCEPTION '6k commit refused: nothing to create' USING ERRCODE = '22023'; END IF;
  INSERT INTO units (station_id, region_id, unit_name, source_file, source_raw)
  SELECT station_id, region_id, unit_name, 'owner rule 6k (one-Unit Station named as the Station)',
         jsonb_build_object('rule', 'SU2/6c-2: one Unit = Station name', 'no_source_row', true)
    FROM cng_6k_proposal();
  GET DIAGNOSTICS v = ROW_COUNT;
  IF v <> e THEN RAISE EXCEPTION '6k commit refused: % created, % expected', v, e USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'units', NULL, NULL, 'service_role:one_unit_stations_6k',
          format('Phase 6k: %s Units created, each named as its Station (owner one-Unit rule). %s', v, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'units_created', v), now());
  RETURN QUERY SELECT v, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6k_proposal(), cng_6k_preview(), cng_6k_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6k_proposal(), cng_6k_preview(), cng_6k_commit(text, text) TO service_role;
