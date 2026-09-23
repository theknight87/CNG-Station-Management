-- Phase 6c-1: attach `Station data base.xlsx` attributes to the Unit each row names.
--
-- OWNER RULINGS (2026-09-23): U1, SU and SU2 approved; X (blank rows) removed.
--   U1  the row's name equals exactly one Unit name in the same Region.
--   SU  a single-Unit Station whose Unit carries the Station's name.
--   SU2 Station "X" with Units "X" and "X 2": the row "X" is Unit "X" (owner's
--       numbering rule: the plain name is the first Unit).
-- All three are the same evidence test: the row's normalized name equals the
-- normalized name of EXACTLY ONE Unit in the row's Region. No Station-level
-- name is ever pushed down to its only Unit (that is the forbidden one-Unit
-- inference, CLAUDE.md §4); S1 / N1 / Z rows stay staged, untouched.
--
-- Written: units.{dispenser,hose,storage}_count_reported (+ raw text) and
-- units.bay_status (+ raw). Counts only when the raw cell is a plain integer;
-- anything else ("2 / 4", "3_2") keeps its raw text and a NULL number.
-- bay_status only for text starting open/clos (case-insensitive); the raw
-- text is always kept. A Unit that already holds any of these values is not
-- overwritten (the proposal excludes it).
--
-- X: rows with no name at all are marked outcome = 'rejected' with a reason.
-- Nothing is deleted (§10 no hard deletes); source_raw is untouched.
--
-- service_role only, like Stage A and the asset import: `units` carries no
-- actor column, so there is no human attribution to derive. The approval is
-- content-bound: the commit re-derives the fingerprint in its own transaction.

CREATE OR REPLACE FUNCTION cng_6c_unit_attribute_proposal(p_import_run_id uuid)
RETURNS TABLE (
  staging_row_id uuid, source_row int, source_row_hash text, region text,
  source_name_raw text, unit_id uuid, unit_name text, station_name text,
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
  u AS MATERIALIZED (
    SELECT u.id, u.unit_name, u.normalized_name, r.name AS region, st.station_name,
           (u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
            AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
            AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
            AND u.bay_status IS NULL AND u.bay_status_raw IS NULL) AS empty
      FROM units u JOIN regions r ON r.id = u.region_id JOIN stations st ON st.id = u.station_id
     WHERE u.archived_at IS NULL
  ),
  m AS (
    SELECT rows.*, u.id AS uid, u.unit_name, u.station_name, u.empty,
           count(*) OVER (PARTITION BY rows.id) AS units_matched
      FROM rows JOIN u ON u.region = rows.region AND u.normalized_name = rows.nn
  ),
  one AS (
    SELECT m.*, count(*) OVER (PARTITION BY m.uid) AS rows_per_unit
      FROM m WHERE m.units_matched = 1
  )
  SELECT one.id, one.source_row, one.source_row_hash, one.region, one.raw, one.uid,
         one.unit_name, one.station_name,
         CASE WHEN btrim(one.n->>'dispenser_count_reported_raw') ~ '^\d+$' THEN btrim(one.n->>'dispenser_count_reported_raw')::int END,
         nullif(one.n->>'dispenser_count_reported_raw', ''),
         CASE WHEN btrim(one.n->>'hose_count_reported_raw') ~ '^\d+$' THEN btrim(one.n->>'hose_count_reported_raw')::int END,
         nullif(one.n->>'hose_count_reported_raw', ''),
         CASE WHEN btrim(one.n->>'storage_count_reported_raw') ~ '^\d+$' THEN btrim(one.n->>'storage_count_reported_raw')::int END,
         nullif(one.n->>'storage_count_reported_raw', ''),
         CASE WHEN lower(btrim(one.n->>'bay_status_raw')) LIKE 'open%' THEN 'open'::bay_status
              WHEN lower(btrim(one.n->>'bay_status_raw')) LIKE 'clos%' THEN 'closed'::bay_status END,
         nullif(one.n->>'bay_status_raw', '')
    FROM one
   WHERE one.rows_per_unit = 1 AND one.empty
   ORDER BY one.source_row, one.id;
$$;

CREATE OR REPLACE FUNCTION cng_6c_unit_attribute_preview(p_import_run_id uuid)
RETURNS TABLE (
  preview_fingerprint text, rows_to_attach int, units_affected int,
  blank_rows_to_reject int, east int, west int, delta int,
  counts_non_integer_kept_raw int, bay_status_unrecognised int
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6c_unit_attribute_proposal(p_import_run_id)),
  x AS (
    SELECT s.id, s.source_row_hash FROM import_staging_rows s
     WHERE s.import_run_id = p_import_run_id AND s.target_table = 'unit_attributes'
       AND s.committed_entity_id IS NULL AND s.outcome <> 'rejected'
       AND nullif(btrim(s.normalized->>'source_name_raw'), '') IS NULL
  )
  SELECT encode(sha256(convert_to('6C|' ||
           coalesce((SELECT string_agg(concat_ws('|', staging_row_id, source_row_hash, unit_id,
                       dispenser_count, dispenser_count_raw, hose_count, hose_count_raw,
                       storage_count, storage_count_raw, bay_status, bay_status_raw), E'\n'
                       ORDER BY staging_row_id) FROM p), '') || E'\nX\n' ||
           coalesce((SELECT string_agg(id || '|' || source_row_hash, E'\n' ORDER BY id) FROM x), ''),
         'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(DISTINCT unit_id) FROM p)::int,
         (SELECT count(*) FROM x)::int,
         (SELECT count(*) FROM p WHERE region = 'East')::int,
         (SELECT count(*) FROM p WHERE region = 'West')::int,
         (SELECT count(*) FROM p WHERE region = 'Delta')::int,
         (SELECT count(*) FROM p WHERE (dispenser_count IS NULL AND dispenser_count_raw IS NOT NULL)
                                    OR (hose_count IS NULL AND hose_count_raw IS NOT NULL)
                                    OR (storage_count IS NULL AND storage_count_raw IS NOT NULL))::int,
         (SELECT count(*) FROM p WHERE bay_status IS NULL AND bay_status_raw IS NOT NULL)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6c_unit_attribute_commit(
  p_import_run_id uuid, p_expected_preview_fingerprint text, p_reason text
)
RETURNS TABLE (units_updated int, rows_linked int, blank_rows_rejected int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_fp text; v_expected int; v_units int; v_linked int; v_rejected int;
  v_now timestamptz := clock_timestamp();
BEGIN
  IF p_import_run_id IS NULL OR nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6c commit requires an import run and the approved preview fingerprint'
      USING ERRCODE = '22023';
  END IF;

  SELECT pv.preview_fingerprint, pv.rows_to_attach INTO v_fp, v_expected
    FROM cng_6c_unit_attribute_preview(p_import_run_id) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6c commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF v_expected = 0 THEN
    RAISE EXCEPTION '6c commit refused: nothing left to attach' USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6c ON COMMIT DROP AS
    SELECT * FROM cng_6c_unit_attribute_proposal(p_import_run_id);

  UPDATE units u
     SET dispenser_count_reported = p.dispenser_count, dispenser_count_raw = p.dispenser_count_raw,
         hose_count_reported = p.hose_count, hose_count_raw = p.hose_count_raw,
         storage_count_reported = p.storage_count, storage_count_raw = p.storage_count_raw,
         bay_status = p.bay_status, bay_status_raw = p.bay_status_raw,
         updated_at = v_now
    FROM _6c p
   WHERE u.id = p.unit_id
     AND u.dispenser_count_reported IS NULL AND u.dispenser_count_raw IS NULL
     AND u.hose_count_reported IS NULL AND u.hose_count_raw IS NULL
     AND u.storage_count_reported IS NULL AND u.storage_count_raw IS NULL
     AND u.bay_status IS NULL AND u.bay_status_raw IS NULL;
  GET DIAGNOSTICS v_units = ROW_COUNT;
  IF v_units <> v_expected THEN
    RAISE EXCEPTION '6c commit refused: % Units updated, % expected', v_units, v_expected USING ERRCODE = '40001';
  END IF;

  UPDATE import_staging_rows s
     SET committed_entity_id = p.unit_id, committed_entity_kind = 'unit',
         committed_at = v_now, updated_at = v_now
    FROM _6c p
   WHERE s.id = p.staging_row_id AND s.committed_entity_id IS NULL;
  GET DIAGNOSTICS v_linked = ROW_COUNT;

  UPDATE import_staging_rows s
     SET outcome = 'rejected',
         resolution = coalesce(s.resolution, '{}'::jsonb)
                      || jsonb_build_object('rejected', 'blank row: no name and no identity (owner ruling 6c X)',
                                            'rejected_at', v_now),
         updated_at = v_now
   WHERE s.import_run_id = p_import_run_id AND s.target_table = 'unit_attributes'
     AND s.committed_entity_id IS NULL AND s.outcome <> 'rejected'
     AND nullif(btrim(s.normalized->>'source_name_raw'), '') IS NULL;
  GET DIAGNOSTICS v_rejected = ROW_COUNT;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'import_runs', p_import_run_id, NULL, 'service_role:unit_attributes_6c',
          format('Phase 6c unit attributes: %s Units updated from %s rows; %s blank rows rejected. %s',
                 v_units, v_linked, v_rejected, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'units_updated', v_units,
                                   'blank_rows_rejected', v_rejected),
          v_now);

  RETURN QUERY SELECT v_units, v_linked, v_rejected, v_fp;
END;
$$;

COMMENT ON FUNCTION cng_6c_unit_attribute_proposal(uuid) IS
  'Phase 6c: unit_attributes rows whose name equals exactly one Unit name in the same Region (owner rulings U1/SU/SU2). Read-only.';
COMMENT ON FUNCTION cng_6c_unit_attribute_preview(uuid) IS
  'Phase 6c: counts and content-bound fingerprint (prefix 6C) of the Unit attribute proposal plus blank rows. Read-only.';
COMMENT ON FUNCTION cng_6c_unit_attribute_commit(uuid, text, text) IS
  'Phase 6c: one guarded write of the approved proposal; re-derives the fingerprint; never overwrites a Unit value; rejects (never deletes) blank rows.';

REVOKE ALL ON FUNCTION cng_6c_unit_attribute_proposal(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c_unit_attribute_proposal(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6c_unit_attribute_preview(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c_unit_attribute_preview(uuid) TO service_role;
REVOKE ALL ON FUNCTION cng_6c_unit_attribute_commit(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6c_unit_attribute_commit(uuid, text, text) TO service_role;
