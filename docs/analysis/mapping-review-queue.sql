-- Regenerates the FULL Prompt 20H review queue (327 identities) verbatim from production.
-- READ-ONLY. Run against ypkggegquetvpsflkaxg. Writes nothing and decides nothing.
--
-- `structural_candidates` / `candidate_structural_name` are ADVISORY MEASUREMENTS of what a
-- deterministic separator-folding normalization WOULD match in the staged structural source.
-- They are NOT applied anywhere, and they are NOT mapping decisions. `cng_normalize_name()`
-- already strips tatweel; the folding below additionally collapses whitespace around '/'.
WITH su AS (
  SELECT DISTINCT normalized->>'station_name' AS nm,
         btrim(regexp_replace(regexp_replace(
           cng_normalize_name(normalized->>'station_name'), '\s*/\s*', '/', 'g'), '\s+', ' ', 'g')) AS f
  FROM import_staging_rows WHERE target_table = 'stations_units'),
b AS (
  SELECT normalized->>'source_station_name_raw' AS raw,
         coalesce(normalized->>'region','') AS region,
         target_table
  FROM import_staging_rows
  WHERE mapping_status = 'needs_station_mapping'
    AND target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')),
g AS (
  SELECT raw,
         string_agg(DISTINCT region, '+' ORDER BY region) AS regions,
         count(*) AS rows_affected,
         count(*) FILTER (WHERE target_table='storage_vessels') AS storage_vessels,
         count(*) FILTER (WHERE target_table='recovery_tanks')  AS recovery_tanks,
         count(*) FILTER (WHERE target_table='gas_detectors')   AS gas_detectors,
         count(*) FILTER (WHERE target_table='hoses')           AS hoses,
         btrim(regexp_replace(regexp_replace(
           cng_normalize_name(raw), '\s*/\s*', '/', 'g'), '\s+', ' ', 'g')) AS folded
  FROM b GROUP BY raw)
SELECT g.raw AS raw_station,
       cng_normalize_name(g.raw) AS normalized_station,
       g.regions AS region,
       g.rows_affected, g.storage_vessels, g.recovery_tanks, g.gas_detectors, g.hoses,
       (SELECT count(*) FROM su WHERE su.f = g.folded) AS structural_candidates,
       (SELECT string_agg(su.nm, ' ; ') FROM su WHERE su.f = g.folded) AS candidate_structural_name
FROM g
ORDER BY g.rows_affected DESC, g.raw;
