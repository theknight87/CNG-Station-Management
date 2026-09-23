-- Phase 6c-2: `Station data base.xlsx` rows that name a STATION (class S1).
--
-- OWNER RULINGS (2026-09-23), explicit and limited to this workbook's S1 rows:
--   * "Neglect the address: the name of the Station is the name of the Unit if it
--     has one Unit." A row naming a Station with exactly ONE Unit belongs to that
--     Unit, whatever the Unit is called (Delta Units carry address names).
--   * "بيلا/كفر الشيخ has a Unit with the same name." A row naming a Station with
--     NO Unit creates that Unit, named exactly as the Station (the Stage A Station
--     with zero Units). Owner-stated fact, not a default Unit (D7).
--   * "فويل اب الدائري has two Units, 1 and 2." A Station whose Units are exactly
--     "<Station> 1" … "<Station> n", named by n rows, takes them in source-row
--     order (the owner's numbering rule: X 1, X 2, X 3 …).
--   * Bay status belongs to the Unit (enclosure), never the Station.
-- Anything else stays held. The one-Unit attachment here is an OWNER RULING for
-- these rows; it does not relax CLAUDE.md §4 anywhere else.
--
-- Same value rules as 6c-1 (0 overwrites; integers only when the cell is a plain
-- integer; raw text always kept). service_role only; content-bound fingerprint
-- prefixed 6C2; the commit re-derives it in its own transaction.

CREATE OR REPLACE FUNCTION cng_6c2_station_row_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id uuid, source_row int, source_row_hash text, region text,
  source_name_raw text, station_id uuid, station_name text, unit_id uuid,
  create_unit boolean, rule text,
  dispenser_count int, dispenser_count_raw text,
  hose_count int, hose_count_raw text,
  storage_count int, storage_count_raw text,
  bay_status bay_status, bay_status_raw text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH rows AS MATERIALIZED (
    SELECT s.id, s.source_row, s.source_row_hash, s.normalized->>'region' AS region,
           s.normalized->>'source_name_raw' AS raw,
           cng_normalize_name(s.normalized->>'source_name_raw') AS nn, s.normalized AS n
      FROM import_staging_rows s
     WHERE s.import_run_id = p_import_run_id
       AND s.target_table = 'unit_attributes'
       AND s.committed_entity_id IS NULL
       AND s.outcome <> 'rejected'
       AND nullif(btrim(s.normalized->>'source_name_raw'), '') IS NOT NULL
  ),
  st AS MATERIALIZED (
    SELECT s.id, s.station_name, s.normalized_name, r.name AS region
      FROM stations s JOIN regions r ON r.id = s.region_id WHERE s.archived_at IS NULL
  ),
  un AS MATERIALIZED (
    SELECT u.id, u.station_id, u.normalized_name,
           (u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
            AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
            AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
            AND u.bay_status IS NULL AND u.bay_status_raw IS NULL) AS empty
      FROM units u WHERE u.archived_at IS NULL
  ),
  -- S1: the name is a Station and NOT any Unit in the Region (U1/SU/SU2 were 6c-1).
  s1 AS (
    SELECT rows.*, st.id AS sid, st.station_name, st.normalized_name AS snn,
           (SELECT count(*) FROM un WHERE un.station_id = st.id) AS nunits,
           row_number() OVER (PARTITION BY st.id ORDER BY rows.source_row, rows.id) AS k,
           count(*) OVER (PARTITION BY st.id) AS nrows
      FROM rows JOIN st ON st.region = rows.region AND st.normalized_name = rows.nn
     WHERE NOT EXISTS (SELECT 1 FROM un JOIN st s2 ON s2.id = un.station_id
                        WHERE s2.region = rows.region AND un.normalized_name = rows.nn)
  ),
  resolved AS (
    -- one Unit, one row
    SELECT s1.*, (SELECT un.id FROM un WHERE un.station_id = s1.sid) AS uid, false AS mk, 'one_unit' AS rule
      FROM s1 WHERE s1.nunits = 1 AND s1.nrows = 1
    UNION ALL
    -- no Unit, one row: create the Unit named as the Station
    SELECT s1.*, NULL::uuid, true, 'create_unit_named_as_station'
      FROM s1 WHERE s1.nunits = 0 AND s1.nrows = 1
    UNION ALL
    -- Units exactly "<Station> 1..n", n rows: k-th row -> "<Station> k"
    SELECT s1.*, un.id, false, 'numbered_units_in_row_order'
      FROM s1 JOIN un ON un.station_id = s1.sid
                     AND un.normalized_name = cng_normalize_name(s1.station_name || ' ' || s1.k)
     WHERE s1.nunits > 1 AND s1.nrows = s1.nunits
       AND (SELECT count(*) FROM un u2 WHERE u2.station_id = s1.sid
             AND u2.normalized_name IN (SELECT cng_normalize_name(s1.station_name || ' ' || g)
                                          FROM generate_series(1, s1.nunits::int) g)) = s1.nunits
  )
  SELECT r.id, r.source_row, r.source_row_hash, r.region, r.raw, r.sid, r.station_name, r.uid, r.mk, r.rule,
         CASE WHEN btrim(r.n->>'dispenser_count_reported_raw') ~ '^\d+$' THEN btrim(r.n->>'dispenser_count_reported_raw')::int END,
         nullif(r.n->>'dispenser_count_reported_raw', ''),
         CASE WHEN btrim(r.n->>'hose_count_reported_raw') ~ '^\d+$' THEN btrim(r.n->>'hose_count_reported_raw')::int END,
         nullif(r.n->>'hose_count_reported_raw', ''),
         CASE WHEN btrim(r.n->>'storage_count_reported_raw') ~ '^\d+$' THEN btrim(r.n->>'storage_count_reported_raw')::int END,
         nullif(r.n->>'storage_count_reported_raw', ''),
         CASE WHEN lower(btrim(r.n->>'bay_status_raw')) LIKE 'open%' THEN 'open'::bay_status
              WHEN lower(btrim(r.n->>'bay_status_raw')) LIKE 'clos%' THEN 'closed'::bay_status END,
         nullif(r.n->>'bay_status_raw', '')
    FROM resolved r
   WHERE r.mk OR EXISTS (SELECT 1 FROM un WHERE un.id = r.uid AND un.empty)
   ORDER BY r.source_row, r.id;
$$;

CREATE OR REPLACE FUNCTION cng_6c2_station_row_preview(p_import_run_id uuid)
RETURNS TABLE (
  preview_fingerprint text, rows_to_attach int, units_to_create int,
  one_unit int, numbered int, delta int, west int, east int, counts_non_integer_kept_raw int
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6c2_station_row_proposal(p_import_run_id))
  SELECT encode(sha256(convert_to('6C2|' || coalesce((SELECT string_agg(concat_ws('|',
           staging_row_id, source_row_hash, station_id, unit_id, create_unit, rule,
           dispenser_count, dispenser_count_raw, hose_count, hose_count_raw,
           storage_count, storage_count_raw, bay_status, bay_status_raw), E'\n' ORDER BY staging_row_id) FROM p), ''),
         'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE create_unit)::int,
         (SELECT count(*) FROM p WHERE rule = 'one_unit')::int,
         (SELECT count(*) FROM p WHERE rule = 'numbered_units_in_row_order')::int,
         (SELECT count(*) FROM p WHERE region = 'Delta')::int,
         (SELECT count(*) FROM p WHERE region = 'West')::int,
         (SELECT count(*) FROM p WHERE region = 'East')::int,
         (SELECT count(*) FROM p WHERE (dispenser_count IS NULL AND dispenser_count_raw IS NOT NULL)
                                    OR (hose_count IS NULL AND hose_count_raw IS NOT NULL)
                                    OR (storage_count IS NULL AND storage_count_raw IS NOT NULL))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6c2_station_row_commit(
  p_import_run_id uuid, p_expected_preview_fingerprint text, p_reason text
)
RETURNS TABLE (units_created int, units_updated int, rows_linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_fp text; v_expected int; v_created int; v_units int; v_linked int;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_import_run_id IS NULL OR nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6c-2 commit requires an import run and the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.rows_to_attach INTO v_fp, v_expected
    FROM cng_6c2_station_row_preview(p_import_run_id) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6c-2 commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF v_expected = 0 THEN
    RAISE EXCEPTION '6c-2 commit refused: nothing left to attach' USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6c2 ON COMMIT DROP AS SELECT * FROM cng_6c2_station_row_proposal(p_import_run_id);

  -- Owner-stated Units (Station with no Unit): named exactly as the Station.
  WITH ins AS (
    INSERT INTO units (station_id, region_id, unit_name, import_batch_id, source_file, source_sheet, source_row, source_raw)
    SELECT st.id, st.region_id, st.station_name, s.import_batch_id, s.source_file, s.source_sheet, s.source_row,
           jsonb_build_object('stage', '6c-2', 'rule', 'owner: Station has a Unit with the same name',
                              'import_run_id', p_import_run_id, 'staging_row_id', s.id)
      FROM _6c2 p JOIN stations st ON st.id = p.station_id JOIN import_staging_rows s ON s.id = p.staging_row_id
     WHERE p.create_unit
    RETURNING id, station_id
  )
  UPDATE _6c2 p SET unit_id = ins.id FROM ins WHERE p.create_unit AND p.station_id = ins.station_id;
  GET DIAGNOSTICS v_created = ROW_COUNT;

  UPDATE units u
     SET dispenser_count_reported = p.dispenser_count, dispenser_count_raw = p.dispenser_count_raw,
         hose_count_reported = p.hose_count, hose_count_raw = p.hose_count_raw,
         storage_count_reported = p.storage_count, storage_count_raw = p.storage_count_raw,
         bay_status = p.bay_status, bay_status_raw = p.bay_status_raw, updated_at = v_now
    FROM _6c2 p
   WHERE u.id = p.unit_id
     AND u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
     AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
     AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
     AND u.bay_status IS NULL AND u.bay_status_raw IS NULL;
  GET DIAGNOSTICS v_units = ROW_COUNT;
  IF v_units <> v_expected THEN
    RAISE EXCEPTION '6c-2 commit refused: % Units updated, % expected', v_units, v_expected USING ERRCODE = '40001';
  END IF;

  UPDATE import_staging_rows s
     SET committed_entity_id = p.unit_id, committed_entity_kind = 'unit', committed_at = v_now, updated_at = v_now
    FROM _6c2 p WHERE s.id = p.staging_row_id AND s.committed_entity_id IS NULL;
  GET DIAGNOSTICS v_linked = ROW_COUNT;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'import_runs', p_import_run_id, NULL, 'service_role:unit_attributes_6c2',
          format('Phase 6c-2 Station-named rows: %s Units updated (%s created) from %s rows. %s',
                 v_units, v_created, v_linked, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'units_updated', v_units, 'units_created', v_created),
          v_now);

  RETURN QUERY SELECT v_created, v_units, v_linked, v_fp;
END;
$$;

COMMENT ON FUNCTION cng_6c2_station_row_proposal(uuid) IS
  'Phase 6c-2: Station-named unit_attributes rows resolved by explicit owner rulings (one Unit; owner-stated same-name Unit; numbered Units in row order). Read-only.';
COMMENT ON FUNCTION cng_6c2_station_row_preview(uuid) IS 'Phase 6c-2: counts and content-bound fingerprint (prefix 6C2). Read-only.';
COMMENT ON FUNCTION cng_6c2_station_row_commit(uuid, text, text) IS
  'Phase 6c-2: one guarded write; re-derives the fingerprint; never overwrites a Unit value; creates only owner-stated same-name Units.';

REVOKE ALL ON FUNCTION cng_6c2_station_row_proposal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c2_station_row_proposal(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6c2_station_row_preview(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c2_station_row_preview(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6c2_station_row_commit(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c2_station_row_commit(uuid, text, text) TO service_role;
