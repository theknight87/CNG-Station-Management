-- stage-a-match-simulation.sql
-- Prompt 21C Phase 8. READ-ONLY. Run against the production database to
-- reproduce the figures in docs/stage-a-hierarchy.md §9.
--
-- It writes nothing and needs nothing deployed: the proposed hierarchy is
-- derived inline from the staged rows, exactly as cng_stage_a_proposal derives
-- it, so the simulation can be run before Stage A is committed anywhere.
--
-- It RESOLVES NOTHING. A "candidate" here is an exact same-Region normalized
-- name match and is evidence for a human decision, never a mapping.

WITH proposed_station AS (
  SELECT DISTINCT r.normalized ->> 'region' AS region,
         cng_normalize_name(r.normalized ->> 'station_name') AS sn
    FROM import_staging_rows r
   WHERE r.target_table = 'stations_units'
     AND r.normalized ->> 'station_name' IS NOT NULL
),
proposed_unit AS (
  SELECT DISTINCT r.normalized ->> 'region' AS region,
         cng_normalize_name(r.normalized ->> 'unit_name') AS un
    FROM import_staging_rows r
   WHERE r.target_table = 'stations_units'
     AND r.normalized ->> 'unit_name' IS NOT NULL
),
asset AS (
  SELECT r.normalized ->> 'region' AS region,
         r.normalized ->> 'source_station_name_raw' AS raw,
         cng_normalize_name(r.normalized ->> 'source_station_name_raw') AS an
    FROM import_staging_rows r
   WHERE r.target_table IN ('storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses')
     AND r.mapping_status = 'needs_station_mapping'
),
raw_ident  AS (SELECT region, raw, an, count(*)::int AS rows_covered FROM asset GROUP BY 1, 2, 3),
norm_ident AS (SELECT region, an,       count(*)::int AS rows_covered FROM asset GROUP BY 1, 2),
scored_raw AS (
  SELECT ri.*, (SELECT count(*) FROM proposed_station p WHERE p.region = ri.region AND p.sn = ri.an) AS cand
    FROM raw_ident ri
),
scored_norm AS (
  SELECT ni.*,
    (SELECT count(*) FROM proposed_station p WHERE p.region = ni.region AND p.sn  = ni.an) AS cand,
    (SELECT count(*) FROM proposed_station p WHERE p.region <> ni.region AND p.sn = ni.an) AS other_region,
    (SELECT count(*) FROM proposed_unit    u WHERE u.region = ni.region AND u.un  = ni.an) AS unit_name_match
    FROM norm_ident ni
)
SELECT
  (SELECT count(*)              FROM asset)                              AS asset_rows_in_scope,
  (SELECT count(*)              FROM raw_ident)                          AS distinct_raw_spellings,
  (SELECT count(*)              FROM norm_ident)                         AS distinct_normalized_identities,
  (SELECT count(*)              FROM scored_raw  WHERE cand = 1)         AS raw_spellings_one_candidate,
  (SELECT count(*)              FROM scored_norm WHERE cand = 1)         AS identities_one_candidate,
  (SELECT coalesce(sum(rows_covered), 0) FROM scored_norm WHERE cand = 1) AS rows_covered,
  (SELECT count(*)              FROM scored_norm WHERE cand > 1)         AS identities_multiple_candidates,
  (SELECT count(*)              FROM scored_norm WHERE cand = 0)         AS identities_no_candidate,
  (SELECT coalesce(sum(rows_covered), 0) FROM scored_norm WHERE cand = 0) AS rows_no_candidate,
  -- NOT a match: Region is identity and cross-Region matching is forbidden.
  (SELECT count(*) FROM scored_norm WHERE cand = 0 AND other_region > 0) AS matches_only_in_another_region,
  -- NOT a Station match: a Unit name is a different kind of thing entirely.
  (SELECT count(*) FROM scored_norm WHERE unit_name_match > 0)           AS text_matches_a_unit_name,
  -- A third, separate state Stage A does not touch.
  (SELECT count(*) FROM import_staging_rows
    WHERE mapping_status = 'needs_equipment_mapping')                    AS needs_equipment_mapping_rows;
