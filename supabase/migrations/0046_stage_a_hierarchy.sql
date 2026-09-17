-- 0046_stage_a_hierarchy.sql
-- Stage A: the canonical Station and Unit hierarchy pipeline (Prompt 21C).
--
-- WHAT THIS IS. Production holds one completed staging run
-- (cdad1e5e-7faa-4f3b-9432-12a720f3dd64) whose 402 `stations_units` rows are the
-- ONLY source that states structure explicitly. `stations` and `units` are both
-- 0, so no asset can be mapped to anything: Stage A creates the hierarchy those
-- mappings will later hang from, and nothing else.
--
-- WHAT THIS IS NOT. It creates no alias, no mapping decision and no canonical
-- asset. It resolves no SRV, vessel, detector or hose. It infers no Region, no
-- Unit and no Station: Canal, Alex and Upper contribute zero rows to this source
-- and therefore receive zero Stations — their Stations are NOT invented from
-- asset workbooks, which name Stations without stating structure.
--
-- APPLYING THIS MIGRATION CREATES NOTHING. It installs three functions. The
-- hierarchy appears only when an operator calls `cng_stage_a_commit` with a
-- content-bound approval, which is a separate, separately authorized act.
--
-- ============================== IDENTITY RULES ===============================
-- Station identity  = (region_id, cng_normalize_name(station_name))
-- Unit    identity  = (station_id, cng_normalize_name(unit_name))
--
-- Both are already DATABASE properties — `stations_region_norm_uq` and
-- `units_station_norm_uq` — so this pipeline does not re-implement uniqueness,
-- it relies on it. `units_station_region_fk` likewise already makes a Unit whose
-- Region differs from its Station's inexpressible.
--
-- Region is part of Station identity. Two Regions may legitimately hold the same
-- name and stay two Stations; no name is ever matched across Regions.
--
-- EXPLICITLY NOT IDENTITY, and used for nothing here:
--   * the job number — 4 job numbers are reused across different Units in this
--     very run, and 68 rows carry none at all. It is an ATTRIBUTE, it never
--     identifies a Unit, and its absence never blocks creating one (principle #4).
--   * the compressor model, dispenser model, storage model or any serial.
--   * similarity, suffix stripping, edit distance or any other fuzzy rule.
--   * names appearing in ASSET sources. Those prove a name was written down,
--     not that a Station exists with that structure.
--
-- =============================== DISPLAY NAMES ===============================
-- The normalized form is the COMPARISON key; it is never a display name. The
-- canonical `station_name` / `unit_name` stored is the source's own text, taken
-- verbatim from the row with the lowest (file, sheet, row) for that identity.
--
-- That tie-break is deterministic but it is also never exercised: measured on
-- this run, ZERO Station identities and ZERO Unit identities carry more than one
-- distinct display form. `cng_stage_a_commit` REFUSES rather than picking if
-- that ever stops being true, because silently choosing between two spellings a
-- human has not reconciled is exactly the guess CLAUDE.md §8 forbids.
--
-- ================================== LINEAGE ==================================
-- 402 staging rows become 157 Stations + 188 Units, so one row is NOT one
-- entity and this does not pretend otherwise. Lineage is recorded in BOTH
-- directions and each direction says something true:
--
--   entity -> row : every Station and Unit carries the file/sheet/row and
--                   `import_batch_id` of the row it was created from, so the
--                   evidence for a canonical record is always reachable.
--   row -> entity : `committed_entity_id` on the staging row names the FINEST
--                   entity that row contributed to — its Unit where the row
--                   names one, otherwise its Station. `committed_entity_kind`
--                   says which table that id is in, so no consumer has to
--                   re-derive it from the presence of a unit name.
--
-- Several rows may point at one entity. That is the honest shape of the source
-- and is not flattened into a fake one-to-one.
--
-- ============================ THE CANONICAL SCOPE ============================
-- `cng_stage_a_commit` writes exactly three tables, all named as literals:
-- `stations`, `units`, and `import_staging_rows` (lineage columns only). There
-- is NO dynamic SQL — no EXECUTE, no format(), no quote_ident() — so a caller
-- can never name a destination. It touches no asset table, no alias table and no
-- mapping-decision table. A schema assertion re-derives this from
-- `pg_proc.prosrc` rather than trusting this comment.
--
-- =============================== AUTHORIZATION ===============================
-- EXECUTE on all three functions is granted to `service_role` ONLY. No browser
-- role, admin included, can preview or commit the hierarchy. No function takes
-- an actor parameter, so no caller can attribute the act to someone else.

-- ---------------------------------------------------------------------------
-- 0. ONE ADDITIVE COLUMN
-- ---------------------------------------------------------------------------
-- `committed_entity_id` has existed since 0004 and is deliberately NOT a foreign
-- key, because the entity it names lives in whichever canonical table the row
-- fed. What was missing is which table that is. Stage A makes the ambiguity real
-- for the first time — the same run produces both Station and Unit targets — so
-- the kind is recorded rather than re-derived by every reader from "does this
-- row have a unit name".
--
-- Additive and nullable: every existing row keeps exactly the meaning it has
-- today. The CHECK is an explicit allowlist of canonical kinds, so a later stage
-- cannot quietly widen it by writing free text.

ALTER TABLE import_staging_rows
  ADD COLUMN IF NOT EXISTS committed_entity_kind text;

DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'import_staging_rows'::regclass
       AND conname  = 'isr_committed_entity_kind_ck'
  ) THEN
    ALTER TABLE import_staging_rows
      ADD CONSTRAINT isr_committed_entity_kind_ck CHECK (
        committed_entity_kind IS NULL OR committed_entity_kind IN (
          'station', 'unit', 'compressor', 'recovery_tank', 'gas_detector',
          'dispenser', 'storage_vessel', 'hose', 'installed_relief_valve',
          'warehouse_relief_valve'
        )
      );
  END IF;
END
$mig$;

COMMENT ON COLUMN import_staging_rows.committed_entity_kind IS
  'Which canonical table committed_entity_id refers to. NULL while the row has '
  'not been committed. Several rows may name one entity: a staging row is '
  'evidence, not a one-to-one image of a canonical record.';

-- ---------------------------------------------------------------------------
-- 1. THE PROPOSAL — the single source of truth
-- ---------------------------------------------------------------------------
-- Preview, fingerprint and commit all read THIS function. They cannot drift
-- apart into "what was shown" and "what was written", because there is only one
-- computation and all three are the same call.
--
-- It is a pure SELECT. It writes nothing.

CREATE OR REPLACE FUNCTION cng_stage_a_proposal(p_import_run_id uuid)
RETURNS TABLE (
  entity_kind      text,
  region_name      text,
  station_norm     text,
  unit_norm        text,
  display_name     text,
  job_number       text,
  source_file      text,
  source_sheet     text,
  source_row       integer,
  source_row_hash  text,
  import_batch_id  uuid
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH src AS (
    SELECT
      r.source_file,
      r.source_sheet,
      r.source_row,
      r.source_row_hash,
      r.import_batch_id,
      r.normalized ->> 'region'          AS region_name,
      r.normalized ->> 'station_name'    AS station_display,
      r.normalized ->> 'unit_name'       AS unit_display,
      r.normalized ->> 'unit_job_number' AS job_number,
      cng_normalize_name(r.normalized ->> 'station_name') AS station_norm,
      cng_normalize_name(r.normalized ->> 'unit_name')    AS unit_norm
    FROM import_staging_rows r
    WHERE r.import_run_id = p_import_run_id
      AND r.target_table  = 'stations_units'
  ),
  -- One Station per (Region, normalized name). The lowest source row supplies
  -- the display text and the provenance.
  station_pick AS (
    SELECT DISTINCT ON (s.region_name, s.station_norm)
      s.region_name, s.station_norm, s.station_display,
      s.source_file, s.source_sheet, s.source_row, s.source_row_hash,
      s.import_batch_id
    FROM src s
    WHERE s.station_norm IS NOT NULL
    ORDER BY s.region_name, s.station_norm, s.source_file, s.source_sheet, s.source_row
  ),
  -- One Unit per (Region, Station, normalized unit name). Rows with no unit
  -- name produce NO Unit — a Station with unknown Units keeps zero Units
  -- (decision D7: no default Unit, ever).
  unit_pick AS (
    SELECT DISTINCT ON (s.region_name, s.station_norm, s.unit_norm)
      s.region_name, s.station_norm, s.unit_norm, s.unit_display,
      s.source_file, s.source_sheet, s.source_row, s.source_row_hash,
      s.import_batch_id
    FROM src s
    WHERE s.station_norm IS NOT NULL AND s.unit_norm IS NOT NULL
    ORDER BY s.region_name, s.station_norm, s.unit_norm, s.source_file, s.source_sheet, s.source_row
  ),
  -- The job number is an attribute carried through where the source states one.
  -- This run has ZERO Units with conflicting job numbers; where a Unit has none,
  -- the Unit is still created and the column stays NULL (principles #3, #4).
  unit_job AS (
    SELECT s.region_name, s.station_norm, s.unit_norm,
           min(s.job_number) AS job_number,
           count(DISTINCT s.job_number) AS distinct_jobs
    FROM src s
    WHERE s.station_norm IS NOT NULL AND s.unit_norm IS NOT NULL
    GROUP BY s.region_name, s.station_norm, s.unit_norm
  )
  SELECT 'station'::text, p.region_name, p.station_norm, NULL::text,
         p.station_display, NULL::text,
         p.source_file, p.source_sheet, p.source_row, p.source_row_hash,
         p.import_batch_id
  FROM station_pick p
  UNION ALL
  SELECT 'unit'::text, u.region_name, u.station_norm, u.unit_norm,
         u.unit_display,
         CASE WHEN j.distinct_jobs > 1 THEN NULL ELSE j.job_number END,
         u.source_file, u.source_sheet, u.source_row, u.source_row_hash,
         u.import_batch_id
  FROM unit_pick u
  JOIN unit_job j
    ON j.region_name = u.region_name
   AND j.station_norm = u.station_norm
   AND j.unit_norm    = u.unit_norm
  ORDER BY 1, 2, 3, 4;
$$;

COMMENT ON FUNCTION cng_stage_a_proposal(uuid) IS
  'Stage A (Prompt 21C): the proposed canonical Station/Unit set for one staging '
  'run, derived deterministically from its stations_units rows. Pure SELECT — '
  'writes nothing, creates nothing, and is the SINGLE computation that preview, '
  'fingerprint and commit all read, so what is approved cannot differ from what '
  'is written.';

-- ---------------------------------------------------------------------------
-- 2. THE PREVIEW DIGEST — what an approval is bound TO
-- ---------------------------------------------------------------------------
-- The fingerprint hashes the proposed CONTENT, not a count and not a timestamp:
-- every proposed entity's kind, Region, identity keys, display text and job
-- number, sorted. Change any one of those and the fingerprint changes, so an
-- approval cannot survive the proposal drifting underneath it.
--
-- `source_row_hash` of each contributing row is folded in as well, which binds
-- the approval to the EVIDENCE and not merely to the conclusion — the same
-- content-binding rule migration 0041 established for mapping decisions, for the
-- same reason: a decision must record what the human actually read.
--
-- ASCII 31/30 separate fields and records. Neither can occur in a name, a hex
-- digest or a job number, so no two different proposals can serialise alike.

CREATE OR REPLACE FUNCTION cng_stage_a_preview(p_import_run_id uuid)
RETURNS TABLE (
  import_run_id         uuid,
  manifest_fingerprint  text,
  preview_fingerprint   text,
  source_rows           integer,
  proposed_stations     integer,
  proposed_units        integer,
  stations_without_unit integer,
  existing_stations     integer,
  existing_units        integer
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS (
    SELECT * FROM cng_stage_a_proposal(p_import_run_id)
  ),
  canon AS (
    SELECT string_agg(
             concat_ws(chr(31),
               p.entity_kind, p.region_name, p.station_norm,
               coalesce(p.unit_norm, ''), p.display_name,
               coalesce(p.job_number, ''), p.source_row_hash),
             chr(30)
             ORDER BY p.entity_kind, p.region_name, p.station_norm,
                      coalesce(p.unit_norm, '')
           ) AS blob
    FROM p
  )
  SELECT
    p_import_run_id,
    (SELECT run.summary ->> 'manifest_fingerprint' FROM import_runs run WHERE run.id = p_import_run_id),
    encode(sha256(convert_to(coalesce((SELECT blob FROM canon), ''), 'UTF8')), 'hex'),
    (SELECT count(*)::integer FROM import_staging_rows r
      WHERE r.import_run_id = p_import_run_id AND r.target_table = 'stations_units'),
    (SELECT count(*)::integer FROM p WHERE p.entity_kind = 'station'),
    (SELECT count(*)::integer FROM p WHERE p.entity_kind = 'unit'),
    (SELECT count(*)::integer FROM p s
      WHERE s.entity_kind = 'station'
        AND NOT EXISTS (SELECT 1 FROM p u
                        WHERE u.entity_kind = 'unit'
                          AND u.region_name  = s.region_name
                          AND u.station_norm = s.station_norm)),
    (SELECT count(*)::integer FROM stations),
    (SELECT count(*)::integer FROM units);
$$;

COMMENT ON FUNCTION cng_stage_a_preview(uuid) IS
  'Stage A (Prompt 21C): the content fingerprint and counts an owner approval is '
  'bound to. Read-only. The fingerprint covers every proposed entity AND the '
  'source_row_hash of the evidence behind it, so an approval lapses the moment '
  'either the proposal or its source content changes.';

-- ---------------------------------------------------------------------------
-- 3. THE COMMIT — fail closed
-- ---------------------------------------------------------------------------
-- Both fingerprints are REQUIRED parameters and are re-derived inside this
-- transaction. There is no "approve whatever is current" path: a NULL, an empty
-- string or a stale value refuses. That is the difference between an approval
-- bound to content and an approval that can drift between preview and commit.

CREATE OR REPLACE FUNCTION cng_stage_a_commit(
  p_import_run_id                uuid,
  p_expected_manifest_fingerprint text,
  p_expected_preview_fingerprint  text
)
RETURNS TABLE (
  import_run_id        uuid,
  stations_created     integer,
  units_created        integer,
  staging_rows_linked  integer,
  preview_fingerprint  text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actual_manifest text;
  v_actual_preview  text;
  v_completed       timestamptz;
  v_bad_region      text;
  v_ambiguous       integer;
  v_stations        integer := 0;
  v_units           integer := 0;
  v_linked          integer := 0;
BEGIN
  -- --- GATE 1: an approval must actually be presented ----------------------
  IF p_import_run_id IS NULL
     OR coalesce(btrim(p_expected_manifest_fingerprint), '') = ''
     OR coalesce(btrim(p_expected_preview_fingerprint), '')  = '' THEN
    RAISE EXCEPTION 'Stage A commit requires an explicit import run and both approval fingerprints'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 2: the run must exist and be a completed staging run -----------
  SELECT run.completed_at, run.summary ->> 'manifest_fingerprint'
    INTO v_completed, v_actual_manifest
    FROM import_runs run
   WHERE run.id = p_import_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Stage A commit: import run % does not exist', p_import_run_id
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_completed IS NULL THEN
    RAISE EXCEPTION 'Stage A commit: import run % is not completed', p_import_run_id
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 3: the approved SOURCE CONTENT ---------------------------------
  IF v_actual_manifest IS DISTINCT FROM p_expected_manifest_fingerprint THEN
    RAISE EXCEPTION 'Stage A commit refused: manifest fingerprint does not match the approved one'
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 4: the approved PROPOSAL ---------------------------------------
  SELECT pv.preview_fingerprint INTO v_actual_preview
    FROM cng_stage_a_preview(p_import_run_id) pv;

  IF v_actual_preview IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION 'Stage A commit refused: the proposed hierarchy no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_actual_preview
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- --- GATE 5: replay ------------------------------------------------------
  -- One completed Stage A per run. Committing twice would attempt duplicate
  -- identities anyway and be refused by the unique constraints, but refusing
  -- here says WHY rather than surfacing a constraint violation.
  IF EXISTS (
    SELECT 1 FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table  = 'stations_units'
       AND r.committed_entity_id IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'Stage A commit refused: run % has already been committed', p_import_run_id
      USING ERRCODE = 'unique_violation';
  END IF;

  -- --- GATE 6: every Region must be a canonical Region ----------------------
  -- Not matched loosely and never created. An unrecognised Region value is a
  -- human question, not something to fold into the nearest name.
  SELECT DISTINCT pr.region_name INTO v_bad_region
    FROM cng_stage_a_proposal(p_import_run_id) pr
   WHERE NOT EXISTS (SELECT 1 FROM regions g WHERE g.name = pr.region_name)
   LIMIT 1;

  IF v_bad_region IS NOT NULL THEN
    RAISE EXCEPTION 'Stage A commit refused: % is not a canonical Region', v_bad_region
      USING ERRCODE = 'foreign_key_violation';
  END IF;

  -- --- GATE 7: no identity may carry two display spellings -----------------
  -- Measured at zero on this run. If it is ever non-zero the commit refuses:
  -- picking one spelling would silently resolve a question a human has not been
  -- asked.
  SELECT count(*)::integer INTO v_ambiguous FROM (
    SELECT 1
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table  = 'stations_units'
     GROUP BY r.normalized ->> 'region',
              cng_normalize_name(r.normalized ->> 'station_name')
    HAVING count(DISTINCT r.normalized ->> 'station_name') > 1
    UNION ALL
    SELECT 1
      FROM import_staging_rows r
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table  = 'stations_units'
       AND r.normalized ->> 'unit_name' IS NOT NULL
     GROUP BY r.normalized ->> 'region',
              cng_normalize_name(r.normalized ->> 'station_name'),
              cng_normalize_name(r.normalized ->> 'unit_name')
    HAVING count(DISTINCT r.normalized ->> 'unit_name') > 1
  ) amb;

  IF v_ambiguous > 0 THEN
    RAISE EXCEPTION 'Stage A commit refused: % identities carry more than one source spelling and must be reconciled by a human', v_ambiguous
      USING ERRCODE = 'invalid_parameter_value';
  END IF;

  -- =========================== CANONICAL WRITES ============================
  -- From here on: `stations`, `units`, and the lineage columns of
  -- `import_staging_rows`. Three literal targets, no dynamic SQL.

  WITH proposal AS (
    SELECT * FROM cng_stage_a_proposal(p_import_run_id) WHERE entity_kind = 'station'
  ), ins AS (
    INSERT INTO stations (
      region_id, station_name,
      import_batch_id, source_file, source_sheet, source_row, source_raw
    )
    SELECT g.id, pr.display_name,
           pr.import_batch_id, pr.source_file, pr.source_sheet, pr.source_row,
           jsonb_build_object(
             'stage', 'A',
             'import_run_id', p_import_run_id,
             'source_row_hash', pr.source_row_hash
           )
      FROM proposal pr
      JOIN regions g ON g.name = pr.region_name
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_stations FROM ins;

  WITH proposal AS (
    SELECT * FROM cng_stage_a_proposal(p_import_run_id) WHERE entity_kind = 'unit'
  ), ins AS (
    INSERT INTO units (
      station_id, region_id, unit_name, job_number, job_number_raw,
      import_batch_id, source_file, source_sheet, source_row, source_raw
    )
    SELECT st.id, g.id, pr.display_name, pr.job_number, pr.job_number,
           pr.import_batch_id, pr.source_file, pr.source_sheet, pr.source_row,
           jsonb_build_object(
             'stage', 'A',
             'import_run_id', p_import_run_id,
             'source_row_hash', pr.source_row_hash
           )
      FROM proposal pr
      JOIN regions  g  ON g.name = pr.region_name
      JOIN stations st ON st.region_id = g.id AND st.normalized_name = pr.station_norm
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_units FROM ins;

  -- --- LINEAGE -------------------------------------------------------------
  -- Each staging row points at the FINEST entity it contributed to: its Unit
  -- where it names one, otherwise its Station. Several rows may share an entity;
  -- that is the true shape of a 402-row source describing 345 entities.
  WITH resolved AS (
    SELECT r.id AS row_id,
           coalesce(u.id, st.id) AS entity_id,
           CASE WHEN u.id IS NOT NULL THEN 'unit' ELSE 'station' END AS entity_kind
      FROM import_staging_rows r
      JOIN regions  g  ON g.name = r.normalized ->> 'region'
      JOIN stations st ON st.region_id = g.id
                      AND st.normalized_name = cng_normalize_name(r.normalized ->> 'station_name')
      LEFT JOIN units u ON u.station_id = st.id
                      AND u.normalized_name = cng_normalize_name(r.normalized ->> 'unit_name')
     WHERE r.import_run_id = p_import_run_id
       AND r.target_table  = 'stations_units'
  ), upd AS (
    UPDATE import_staging_rows r
       SET committed_entity_id   = resolved.entity_id,
           committed_entity_kind = resolved.entity_kind,
           committed_at          = now(),
           updated_at            = now()
      FROM resolved
     WHERE r.id = resolved.row_id
    RETURNING 1
  )
  SELECT count(*)::integer INTO v_linked FROM upd;

  RETURN QUERY SELECT p_import_run_id, v_stations, v_units, v_linked, v_actual_preview;
END;
$$;

COMMENT ON FUNCTION cng_stage_a_commit(uuid, text, text) IS
  'Stage A (Prompt 21C): creates the canonical Station/Unit hierarchy from one '
  'approved staging run. Fails closed — both the manifest fingerprint (source '
  'content) and the preview fingerprint (the exact proposal) are required and '
  're-derived here, so an approval that has drifted is refused rather than '
  'reinterpreted. Writes stations, units and the lineage columns of '
  'import_staging_rows ONLY; no alias, no mapping decision, no asset, no '
  'dynamic SQL, no caller-supplied actor.';

REVOKE ALL ON FUNCTION cng_stage_a_proposal(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_a_proposal(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_stage_a_proposal(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_stage_a_preview(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_a_preview(uuid) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_stage_a_preview(uuid) TO service_role;

REVOKE ALL ON FUNCTION cng_stage_a_commit(uuid, text, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION cng_stage_a_commit(uuid, text, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_stage_a_commit(uuid, text, text) TO service_role;
