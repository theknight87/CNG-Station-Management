-- Prompt 21B — separator normalization, proof against the REAL persisted staging run.
-- READ-ONLY. Writes nothing, decides nothing, creates nothing.
--
-- Run BEFORE migration 0045 (expect the "pre" column) and AFTER it (expect the
-- "post" column). The rule collapses whitespace around the literal "/" only.
--
--   metric                                              pre-0045   post-0045
--   structural identities changing comparison form             -          53
--   asset identities gaining exactly ONE same-Region cand.     0          78
--   asset rows covered                                         0         281
--   identities gaining MULTIPLE candidates                     0           0
--   SAME-REGION structural collisions                          0           0
--   cross-Region structural collisions                         0           0
--   other-Region-only candidate identities (MUST NOT match)    -           1
--   rows behind that other-Region candidate                    -           5
WITH suf AS (
  SELECT DISTINCT normalized->>'region' AS r,
         normalized->>'station_name'    AS nm,
         cng_normalize_name(normalized->>'station_name') AS nf
  FROM import_staging_rows
  WHERE import_run_id = 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64'
    AND target_table = 'stations_units'),
af AS (
  SELECT DISTINCT normalized->>'source_station_name_raw' AS raw,
         coalesce(normalized->>'region','')              AS r,
         cng_normalize_name(normalized->>'source_station_name_raw') AS nf
  FROM import_staging_rows
  WHERE import_run_id = 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64'
    AND mapping_status = 'needs_station_mapping'
    AND target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses'))
SELECT 'asset identities gaining exactly ONE same-Region candidate' AS metric,
       (SELECT count(*) FROM af WHERE (SELECT count(*) FROM suf WHERE suf.nf=af.nf AND suf.r=af.r)=1) AS value
UNION ALL SELECT 'asset rows covered',
  (SELECT count(*) FROM import_staging_rows s
    WHERE s.import_run_id='cdad1e5e-7faa-4f3b-9432-12a720f3dd64'
      AND s.mapping_status='needs_station_mapping'
      AND s.target_table IN ('storage_vessels','recovery_tanks','gas_detectors','hoses')
      AND (SELECT count(*) FROM suf
            WHERE suf.nf = cng_normalize_name(s.normalized->>'source_station_name_raw')
              AND suf.r  = coalesce(s.normalized->>'region',''))=1)
UNION ALL SELECT 'identities gaining MULTIPLE candidates (must be 0)',
  (SELECT count(*) FROM af WHERE (SELECT count(*) FROM suf WHERE suf.nf=af.nf AND suf.r=af.r)>1)
UNION ALL SELECT 'SAME-REGION structural collisions (must be 0)',
  (SELECT count(*) FROM (SELECT r,nf FROM suf GROUP BY r,nf HAVING count(DISTINCT nm)>1) c)
UNION ALL SELECT 'cross-Region structural collisions (must be 0)',
  (SELECT count(*) FROM (SELECT nf FROM suf GROUP BY nf HAVING count(DISTINCT r)>1) c)
UNION ALL SELECT 'other-Region-only candidates (MUST NOT auto-match)',
  (SELECT count(*) FROM af WHERE (SELECT count(*) FROM suf WHERE suf.nf=af.nf AND suf.r=af.r)=0
                             AND (SELECT count(*) FROM suf WHERE suf.nf=af.nf)>0)
ORDER BY 1;
