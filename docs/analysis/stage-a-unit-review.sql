-- Prompt 21A - Stage A proposed canonical UNIT review queue.
-- READ-ONLY. Regenerates the complete queue verbatim from production. Writes nothing, decides nothing.
-- A Unit is proposed ONLY where the source names one. No Unit is invented for a Station that has none
-- (CLAUDE.md decision D7: no default Unit, ever). Missing attributes stay NULL: a NULL is a complete
-- record with an unknown attribute (principle #19) and is never filled in.
WITH su AS (
  SELECT normalized->>'region'           AS region,
         normalized->>'station_name'     AS station_name,
         normalized->>'unit_name'        AS unit_name,
         normalized->>'unit_job_number'  AS unit_job_number,
         normalized->>'compressor_model' AS compressor_model,
         normalized->>'storage_model'    AS storage_model,
         normalized->>'dispenser_model'  AS dispenser_model
  FROM import_staging_rows
  WHERE import_run_id = 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64'
    AND target_table = 'stations_units'
    AND normalized->>'unit_name' IS NOT NULL)
SELECT region, station_name, unit_name,
       count(*)                        AS supporting_source_rows,
       max(unit_job_number)            AS unit_job_number,
       count(DISTINCT unit_job_number) AS distinct_job_numbers,   -- >1 would be a conflict
       max(compressor_model)           AS compressor_model,
       max(storage_model)              AS storage_model,
       max(dispenser_model)            AS dispenser_model,
       CASE WHEN count(DISTINCT unit_job_number) > 1 THEN 'conflict_review'
            ELSE 'deterministic' END   AS determinism
FROM su
GROUP BY region, station_name, unit_name
ORDER BY region, station_name, unit_name;
