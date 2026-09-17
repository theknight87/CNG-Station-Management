-- Inline reproduction of cng_stage_b_station_preview, for a database where
-- migration 0047 is NOT deployed. Byte-for-byte the same derivation and the same
-- fingerprint expression; validated by equality against the deployed function.
WITH staged AS (
  SELECT r.id, r.target_table, r.source_row_key, r.source_row_hash, r.mapping_status,
         r.normalized ->> 'region' AS region_name,
         r.normalized ->> 'source_station_name_raw' AS source_raw_name,
         cng_normalize_name(r.normalized ->> 'source_station_name_raw') AS an
    FROM import_staging_rows r
   WHERE r.import_run_id = :'RUN'::uuid
     AND r.target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
     AND r.mapping_status = 'needs_station_mapping'
     AND r.outcome NOT IN ('rejected', 'excluded', 'replayed')
),
matched AS (
  SELECT s.*, (SELECT count(*) FROM stations st JOIN regions g ON g.id = st.region_id
                WHERE g.name = s.region_name AND st.normalized_name = s.an) AS n_same_region
    FROM staged s
),
c AS (
  SELECT m.id AS staging_row_id, m.target_table, g.id AS region_id, g.name AS region_name,
         st.id AS station_id, st.station_name, st.normalized_name AS station_norm,
         m.source_raw_name, m.source_row_key, m.source_row_hash, m.mapping_status,
         EXISTS (SELECT 1 FROM import_mapping_decisions d
                  WHERE d.source_row_key = m.source_row_key AND d.superseded_at IS NULL) AS has_active_decision
    FROM matched m
    JOIN regions  g  ON g.name = m.region_name
    JOIN stations st ON st.region_id = g.id AND st.normalized_name = m.an
   WHERE m.n_same_region = 1
),
canon AS (
  SELECT string_agg(
           concat_ws(chr(31),
             c.staging_row_id::text, c.region_id::text, c.station_id::text,
             c.station_norm, c.station_name, c.source_row_hash,
             c.mapping_status, c.has_active_decision::text),
           chr(30) ORDER BY c.staging_row_id) AS blob
    FROM c
),
grp AS (
  SELECT c.region_name, c.station_id,
         count(*) FILTER (WHERE c.has_active_decision) AS decided,
         count(DISTINCT c.mapping_status) AS statuses
    FROM c GROUP BY c.region_name, c.station_id
)
SELECT
  :'RUN'::uuid AS import_run_id,
  (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = :'RUN'::uuid) AS manifest_fingerprint,
  encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex') AS preview_fingerprint,
  (SELECT count(*)::int FROM grp) AS candidate_groups,
  (SELECT count(*)::int FROM c)   AS candidate_rows,
  (SELECT count(*)::int FROM grp WHERE decided = 0 AND statuses <= 1) AS deterministic_groups,
  (SELECT count(*)::int FROM grp WHERE decided > 0 OR statuses > 1)   AS owner_review_groups,
  (SELECT count(*)::int FROM c WHERE c.has_active_decision) AS rows_with_existing_decision,
  (SELECT count(*)::int FROM c WHERE c.target_table = 'storage_vessels') AS storage_vessels,
  (SELECT count(*)::int FROM c WHERE c.target_table = 'recovery_tanks')  AS recovery_tanks,
  (SELECT count(*)::int FROM c WHERE c.target_table = 'gas_detectors')   AS gas_detectors,
  (SELECT count(*)::int FROM c WHERE c.target_table = 'hoses')           AS hoses,
  (SELECT count(*)::int FROM stations) AS canonical_stations,
  (SELECT count(*)::int FROM units)    AS canonical_units,
  (SELECT count(*)::int FROM import_mapping_decisions WHERE superseded_at IS NULL) AS existing_decisions;
