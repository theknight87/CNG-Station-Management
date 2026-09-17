-- Prompt 21A - Stage A proposed canonical STATION review queue.
-- READ-ONLY. Regenerates the complete queue verbatim from production. Writes nothing, decides nothing.
-- Arabic identities are NEVER hand-transcribed; run this to obtain them exactly as stored.
WITH su AS (
  SELECT normalized->>'region'        AS region,
         normalized->>'station_name'  AS station_name,
         normalized->>'station_name_raw' AS station_name_raw,
         normalized->>'unit_name'     AS unit_name,
         source_row_key
  FROM import_staging_rows
  WHERE import_run_id = 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64'
    AND target_table = 'stations_units')
SELECT su.region,
       su.station_name                              AS proposed_canonical_name,
       min(su.station_name_raw)                     AS source_raw_identity,
       count(*)                                     AS supporting_source_rows,
       count(DISTINCT su.unit_name)                 AS named_units,
       count(*) FILTER (WHERE su.unit_name IS NULL) AS rows_without_unit_name,
       CASE WHEN count(DISTINCT su.unit_name) = 0
            THEN 'deterministic_station_no_units'      -- valid record (CLAUDE.md principle #19, decision D7)
            ELSE 'deterministic' END                 AS determinism,
       CASE WHEN count(DISTINCT su.unit_name) = 0
            THEN 'confirm a Station with no Units is correct'
            ELSE 'none' END                          AS owner_action
FROM su
GROUP BY su.region, su.station_name
ORDER BY su.region, su.station_name;
