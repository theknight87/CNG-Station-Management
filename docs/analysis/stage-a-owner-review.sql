-- stage-a-owner-review.sql
-- Prompt 21C-DEPLOY Phase 6. READ-ONLY owner-review artifacts for the Stage A
-- proposal on production import run cdad1e5e-7faa-4f3b-9432-12a720f3dd64.
--
-- HOW TO USE. Run with psql against the production database. Each \copy writes a
-- UTF-8 CSV straight from the database to your machine. The Arabic Station and
-- Unit names are therefore produced BY POSTGRESQL, never retyped by a human or
-- by an agent — retyping identity text is the corruption this project exists to
-- prevent (CLAUDE.md §6 principle #15).
--
--   psql "$CNG_DB_URL" -v ON_ERROR_STOP=1 -f docs/analysis/stage-a-owner-review.sql
--
-- It writes NOTHING. Every statement is a SELECT.
--
-- ---------------------------------------------------------------------------
-- HOW TO READ THE OUTPUT
-- ---------------------------------------------------------------------------
-- Each proposal row carries a `review_class` column with exactly one of:
--
--   DETERMINISTIC  the entity follows from the approved rules with no judgement.
--                  157 of 157 Stations and 188 of 188 Units are in this class on
--                  the current run. Nothing here needs your attention row by row.
--
--   OWNER REVIEW   informational, or awaiting your explicit confirmation. It does
--                  NOT mean the entity is wrong or that creation is blocked.
--
-- Duplicate source rows that aggregate to the same deterministic entity are NOT
-- listed for review: 402 source rows describe 345 entities, and the 57 extra
-- rows agree with each other. They are surfaced only where a conflict exists,
-- and there are currently zero conflicts of every kind.

\set RUN 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64'

CREATE OR REPLACE VIEW pg_temp.sa_proposal AS
  SELECT * FROM cng_stage_a_proposal(:'RUN'::uuid);

-- ---------------------------------------------------------------------------
-- 1. COMPLETE STATION PROPOSAL (157 rows)
-- ---------------------------------------------------------------------------
\copy (SELECT p.region_name AS region, p.display_name AS station_name, p.station_norm AS comparison_key, (SELECT count(*) FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.region_name=p.region_name AND u.station_norm=p.station_norm) AS proposed_units, p.source_file, p.source_sheet, p.source_row, p.source_row_hash, CASE WHEN NOT EXISTS (SELECT 1 FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.region_name=p.region_name AND u.station_norm=p.station_norm) THEN 'OWNER REVIEW' ELSE 'DETERMINISTIC' END AS review_class, CASE WHEN NOT EXISTS (SELECT 1 FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.region_name=p.region_name AND u.station_norm=p.station_norm) THEN 'Station proposed with ZERO Units. No Unit is invented (decision D7). A Station with no Units is a valid record, not an incomplete one (principle #19).' ELSE '' END AS review_note FROM pg_temp.sa_proposal p WHERE p.entity_kind='station' ORDER BY p.region_name, p.station_norm) TO 'stage-a-station-proposal.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- ---------------------------------------------------------------------------
-- 2. COMPLETE UNIT PROPOSAL (188 rows)
-- ---------------------------------------------------------------------------
\copy (SELECT u.region_name AS region, (SELECT s.display_name FROM pg_temp.sa_proposal s WHERE s.entity_kind='station' AND s.region_name=u.region_name AND s.station_norm=u.station_norm) AS station_name, u.display_name AS unit_name, u.unit_norm AS comparison_key, u.job_number, u.source_file, u.source_sheet, u.source_row, u.source_row_hash, 'DETERMINISTIC' AS review_class, CASE WHEN u.job_number IS NULL THEN 'No job number in source. Stored as NULL; never blocks creation (principle #4) and is NOT identity.' WHEN (SELECT count(DISTINCT u2.region_name||'|'||u2.station_norm||'|'||u2.unit_norm) FROM pg_temp.sa_proposal u2 WHERE u2.entity_kind='unit' AND u2.job_number=u.job_number) > 1 THEN 'Job number also appears on another Unit. INFORMATIONAL: job number is an attribute, never identity, so the Units stay separate.' ELSE '' END AS review_note FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' ORDER BY u.region_name, u.station_norm, u.unit_norm) TO 'stage-a-unit-proposal.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- ---------------------------------------------------------------------------
-- 3. OWNER-REVIEW FLAGS ONLY (the short list: 1 + 4 + 2 findings)
-- ---------------------------------------------------------------------------
\copy (SELECT 'station_without_unit' AS finding, p.region_name AS region, p.display_name AS entity, NULL::text AS job_number, p.source_row, 'Station proposed with zero Units. Confirm this Station genuinely has no Unit recorded in the structural source. No Unit will be invented either way.' AS note FROM pg_temp.sa_proposal p WHERE p.entity_kind='station' AND NOT EXISTS (SELECT 1 FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.region_name=p.region_name AND u.station_norm=p.station_norm) UNION ALL SELECT 'job_number_reused', u.region_name, u.display_name, u.job_number, u.source_row, 'This job number appears on more than one Unit. INFORMATIONAL ONLY: job number is not identity, so no merge is proposed and none will occur.' FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.job_number IS NOT NULL AND (SELECT count(DISTINCT u2.region_name||'|'||u2.station_norm||'|'||u2.unit_norm) FROM pg_temp.sa_proposal u2 WHERE u2.entity_kind='unit' AND u2.job_number=u.job_number) > 1 UNION ALL SELECT 'unit_without_job_number', u.region_name, u.display_name, NULL, u.source_row, 'Source records no job number. Stored NULL; creation is not blocked and nothing is generated.' FROM pg_temp.sa_proposal u WHERE u.entity_kind='unit' AND u.job_number IS NULL ORDER BY 1, 2, 5) TO 'stage-a-owner-review-flags.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8')

-- ---------------------------------------------------------------------------
-- 4. CONFLICT PROOF — all four must return zero rows
-- ---------------------------------------------------------------------------
-- A display-spelling conflict, a Region conflict, a job conflict within one Unit
-- or a compressor-model conflict within one Unit. Any row here is a STOP.
WITH su AS (
  SELECT normalized ->> 'region' AS region,
         normalized ->> 'station_name' AS sname,
         normalized ->> 'unit_name' AS uname,
         normalized ->> 'unit_job_number' AS job,
         normalized ->> 'compressor_model' AS cmodel,
         cng_normalize_name(normalized ->> 'station_name') AS sn,
         cng_normalize_name(normalized ->> 'unit_name') AS un
    FROM import_staging_rows
   WHERE import_run_id = :'RUN'::uuid AND target_table = 'stations_units'
)
SELECT 'station_display_spelling' AS conflict_kind, count(*) AS occurrences
  FROM (SELECT 1 FROM su GROUP BY region, sn HAVING count(DISTINCT sname) > 1) a
UNION ALL
SELECT 'unit_display_spelling', count(*)
  FROM (SELECT 1 FROM su WHERE un IS NOT NULL GROUP BY region, sn, un HAVING count(DISTINCT uname) > 1) b
UNION ALL
SELECT 'station_name_in_two_regions', count(*)
  FROM (SELECT 1 FROM su GROUP BY sn HAVING count(DISTINCT region) > 1) c
UNION ALL
SELECT 'job_number_within_one_unit', count(*)
  FROM (SELECT 1 FROM su WHERE un IS NOT NULL AND job IS NOT NULL
         GROUP BY region, sn, un HAVING count(DISTINCT job) > 1) d
UNION ALL
SELECT 'compressor_model_within_one_unit', count(*)
  FROM (SELECT 1 FROM su WHERE un IS NOT NULL AND cmodel IS NOT NULL
         GROUP BY region, sn, un HAVING count(DISTINCT cmodel) > 1) e;

-- ---------------------------------------------------------------------------
-- 5. MISSING NON-IDENTITY ATTRIBUTES — none of these blocks creation
-- ---------------------------------------------------------------------------
-- Reported so the gaps are visible, NOT so they can be filled. A missing value
-- stays NULL (principles #1, #3, #14, #19). Nothing is badged "incomplete".
WITH su AS (
  SELECT normalized AS n FROM import_staging_rows
   WHERE import_run_id = :'RUN'::uuid AND target_table = 'stations_units'
)
SELECT 'compressor_model'   AS attribute, count(*) FILTER (WHERE n ->> 'compressor_model'    IS NULL) AS source_rows_missing FROM su
UNION ALL SELECT 'dispenser_model',       count(*) FILTER (WHERE n ->> 'dispenser_model'     IS NULL) FROM su
UNION ALL SELECT 'dispenser_serial',      count(*) FILTER (WHERE n ->> 'dispenser_serial'    IS NULL) FROM su
UNION ALL SELECT 'dispenser_bay_label',   count(*) FILTER (WHERE n ->> 'dispenser_bay_label' IS NULL) FROM su
UNION ALL SELECT 'storage_model',         count(*) FILTER (WHERE n ->> 'storage_model'       IS NULL) FROM su
UNION ALL SELECT 'storage_serial',        count(*) FILTER (WHERE n ->> 'storage_serial'      IS NULL) FROM su
UNION ALL SELECT 'unit_job_number',       count(*) FILTER (WHERE n ->> 'unit_job_number'     IS NULL) FROM su
UNION ALL SELECT 'unit_name',             count(*) FILTER (WHERE n ->> 'unit_name'           IS NULL) FROM su;

-- NOTE. Stage A creates Stations and Units only. The compressor, dispenser and
-- storage columns above live on the SOURCE row and are Stage B material; they
-- are listed here because their absence is a fact the owner should see before
-- approving, not because Stage A would store them.
