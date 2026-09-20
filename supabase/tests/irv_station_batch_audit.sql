\set ON_ERROR_STOP on
SET client_min_messages TO notice;
CREATE OR REPLACE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE OR REPLACE FUNCTION pg_temp.refused(l text, s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE s; RAISE NOTICE 'FAILED: % (accepted)', l;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PASS  % refused [%]', l, SQLSTATE; END $$;

SELECT set_config('request.jwt.claims', json_build_object('sub','u_admin')::text, false);

-- ---------------------------------------------------------------------------
-- The batch BEFORE anything is committed. Both evidence mechanisms must be
-- present, or the regression proves nothing about the field that read 0.
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE before_state AS SELECT * FROM cng_irv_station_batch_preview();

SELECT pg_temp.ck('IRVAUD-0  the disposable batch carries BOTH mechanisms',
  (SELECT byte_exact_rows > 0 AND normalized_rows > 0 FROM before_state));
SELECT pg_temp.ck('IRVAUD-1  pre-commit X=839 byte-exact, Y=215 normalization-only, 1054/127',
  (SELECT byte_exact_rows = 839 AND normalized_rows = 215
      AND eligible_rows = 1054 AND eligible_identities = 127 FROM before_state));

-- The fix is STRUCTURAL: the body may read the preview exactly once, so no
-- figure it reports can come from after the UPDATE. Re-derived from the
-- catalog, never trusted from a comment.
SELECT pg_temp.ck('IRVAUD-2  the commit body calls the preview EXACTLY ONCE',
  (SELECT array_length(string_to_array(prosrc, 'cng_irv_station_batch_preview()'), 1) - 1 = 1
     FROM pg_proc WHERE proname = 'cng_irv_station_batch_commit'));
SELECT pg_temp.ck('IRVAUD-2b that detector would catch a second call',
  (SELECT array_length(string_to_array(
     'a cng_irv_station_batch_preview() b cng_irv_station_batch_preview() c',
     'cng_irv_station_batch_preview()'), 1) - 1 = 2));

-- ---------------------------------------------------------------------------
-- THE AUTHORIZED RUN
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE res AS
  SELECT * FROM cng_irv_station_batch_commit(
    (SELECT preview_fingerprint FROM before_state), 1054, 127,
    'Prompt 25K disposable audit regression');

CREATE TEMP TABLE payload AS
  SELECT a.after_data d, a.actor_id, a.summary
    FROM audit_logs a WHERE a.entity_id = (SELECT batch_id FROM res);

-- ===== the defect itself ====================================================
SELECT pg_temp.ck('IRVAUD-3  audit records byte_exact_rows = X (839), NOT 0',
  (SELECT (d ->> 'byte_exact_rows')::int = (SELECT byte_exact_rows FROM before_state) FROM payload));
SELECT pg_temp.ck('IRVAUD-4  audit records normalization_only_rows = Y (215)',
  (SELECT (d ->> 'normalization_only_rows')::int = (SELECT normalized_rows FROM before_state) FROM payload));
SELECT pg_temp.ck('IRVAUD-5  the two mechanisms sum to the mapped rows',
  (SELECT (d ->> 'byte_exact_rows')::int + (d ->> 'normalization_only_rows')::int
          = (d ->> 'srvs_mapped')::int FROM payload));
SELECT pg_temp.ck('IRVAUD-6  identity-level mechanism counts are recorded and sum to 127',
  (SELECT (d ->> 'byte_exact_identities')::int + (d ->> 'normalization_only_identities')::int
          = (d ->> 'identities_mapped')::int FROM payload));
SELECT pg_temp.ck('IRVAUD-7  Region counts are recorded and sum to the mapped rows',
  (SELECT (SELECT sum(value::int) FROM jsonb_each_text(d -> 'rows_by_region'))
          = (d ->> 'srvs_mapped')::int FROM payload));
SELECT pg_temp.ck('IRVAUD-8  distinct target Stations recorded (127)',
  (SELECT (d ->> 'distinct_target_stations')::int
          = (SELECT distinct_target_stations FROM before_state) FROM payload));

-- ===== captured from the SAME pre-update preview that was approved ==========
SELECT pg_temp.ck('IRVAUD-9  the recorded fingerprint IS the approved pre-commit one',
  (SELECT d ->> 'preview_fingerprint' = (SELECT preview_fingerprint FROM before_state) FROM payload));
SELECT pg_temp.ck('IRVAUD-10 every recorded figure equals the pre-commit preview row',
  (SELECT (d ->> 'srvs_mapped')::int        = (SELECT eligible_rows FROM before_state)
      AND (d ->> 'identities_mapped')::int  = (SELECT eligible_identities FROM before_state)
      AND (d ->> 'byte_exact_rows')::int    = (SELECT byte_exact_rows FROM before_state)
      AND (d ->> 'normalization_only_rows')::int = (SELECT normalized_rows FROM before_state)
     FROM payload));
SELECT pg_temp.ck('IRVAUD-11 and NOT the post-update preview, which is now empty',
  (SELECT eligible_rows = 0 AND byte_exact_rows = 0 FROM cng_irv_station_batch_preview()));

-- ===== the forbidden inference stays refused, and is now legible ============
SELECT pg_temp.ck('IRVAUD-12 the one-Unit population is recorded with units_assigned 0',
  (SELECT (d ->> 'rows_under_one_unit_station')::int > 0
      AND (d ->> 'units_assigned')::int = 0
      AND (d ->> 'equipment_assigned')::int = 0 FROM payload));

-- ===== MAPPING SEMANTICS UNCHANGED =========================================
SELECT pg_temp.ck('IRVAUD-13 1,054 mapped, all needs_unit_mapping',
  (SELECT count(*) = 1054 FROM installed_relief_valves WHERE mapping_status = 'needs_unit_mapping'));
SELECT pg_temp.ck('IRVAUD-14 unit_id NULL on ALL mapped',
  (SELECT count(*) = 0 FROM installed_relief_valves WHERE station_id IS NOT NULL AND unit_id IS NOT NULL));
SELECT pg_temp.ck('IRVAUD-15 equipment NULL on ALL mapped',
  (SELECT count(*) = 0 FROM installed_relief_valves
    WHERE station_id IS NOT NULL AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) > 0));
SELECT pg_temp.ck('IRVAUD-16 the one-Unit-Station rows received NO Unit',
  (SELECT count(*) = 0 FROM installed_relief_valves v WHERE v.station_id IS NOT NULL
      AND v.unit_id IS NOT NULL
      AND (SELECT count(*) FROM units u WHERE u.station_id = v.station_id) = 1));
SELECT pg_temp.ck('IRVAUD-17 Region unchanged: every target Station is in the row''s own Region',
  (SELECT count(*) = 0 FROM installed_relief_valves v JOIN stations s ON s.id = v.station_id
    WHERE s.region_id <> v.region_id));
SELECT pg_temp.ck('IRVAUD-18 the remaining 1,608 are untouched',
  (SELECT count(*) = 1608 FROM installed_relief_valves
    WHERE mapping_status = 'needs_station_mapping' AND station_id IS NULL));
SELECT pg_temp.ck('IRVAUD-19 resolved_by/resolved_at stay NULL (not a resolution)',
  (SELECT count(*) = 0 FROM installed_relief_valves WHERE resolved_by IS NOT NULL OR resolved_at IS NOT NULL));

-- ===== per-row audit and attribution unchanged =============================
SELECT pg_temp.ck('IRVAUD-20 1,054 bulk audit rows, one batch id, one actor, one timestamp',
  (SELECT count(*) = 1054 AND count(DISTINCT bulk_batch_id) = 1 AND bool_and(is_bulk)
      AND count(DISTINCT changed_by) = 1 AND count(DISTINCT changed_at) = 1
     FROM asset_mapping_audit WHERE asset_type = 'installed_relief_valve'));
SELECT pg_temp.ck('IRVAUD-21 per-row audit records the true before/after and NO unit or parent',
  (SELECT count(*) = 1054 FROM asset_mapping_audit
    WHERE previous_mapping_status = 'needs_station_mapping'
      AND new_mapping_status = 'needs_unit_mapping'
      AND previous_station_id IS NULL AND new_station_id IS NOT NULL
      AND new_unit_id IS NULL AND new_parent_id IS NULL));
SELECT pg_temp.ck('IRVAUD-22 the batch is attributed to the active Admin, never service_role',
  (SELECT u.role = 'admin' AND u.is_active FROM payload p JOIN app_users u ON u.id = p.actor_id));
SELECT pg_temp.ck('IRVAUD-23 exactly one batch-level audit row',
  (SELECT count(*) = 1 FROM payload));

-- ===== guards unchanged =====================================================
SELECT pg_temp.refused('IRVAUD-24 replay with the approved fingerprint', format(
  'SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')', (SELECT preview_fingerprint FROM before_state)));
SELECT pg_temp.refused('IRVAUD-25 wrong fingerprint', format(
  'SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')', repeat('a',64)));
SELECT pg_temp.refused('IRVAUD-26 wrong row count', format(
  'SELECT cng_irv_station_batch_commit(%L,1053,127,''x'')',
  (SELECT preview_fingerprint FROM cng_irv_station_batch_preview())));
SELECT pg_temp.refused('IRVAUD-27 wrong identity count', format(
  'SELECT cng_irv_station_batch_commit(%L,0,126,''x'')',
  (SELECT preview_fingerprint FROM cng_irv_station_batch_preview())));
SELECT pg_temp.refused('IRVAUD-28 empty fingerprint',
  'SELECT cng_irv_station_batch_commit('''',1054,127,''x'')');

-- ===== firewalls ============================================================
SELECT pg_temp.ck('IRVAUD-29 no alias, no Stage-B decision, no equipment created',
  (SELECT (SELECT count(*) FROM station_aliases) = 0
      AND (SELECT count(*) FROM unit_aliases) = 0
      AND (SELECT count(*) FROM import_mapping_decisions) = 0
      AND (SELECT count(*) FROM compressors) = 0
      AND (SELECT count(*) FROM dispensers) = 0));
SELECT pg_temp.ck('IRVAUD-30 no Station or Unit created',
  (SELECT (SELECT count(*) FROM stations) = 157 AND (SELECT count(*) FROM units) = 189));
SELECT pg_temp.ck('IRVAUD-31 staged source evidence untouched',
  (SELECT count(*) = 2662 FROM import_staging_rows WHERE mapping_status = 'needs_station_mapping'));

-- ===== the sibling path is untouched ========================================
SELECT pg_temp.ck('IRVAUD-32 cng_admin_map_srv still derives needs_unit_mapping from a NULL Unit',
  (SELECT prosrc LIKE '%WHEN p_unit_id IS NULL     THEN ''needs_unit_mapping''%'
     FROM pg_proc WHERE proname = 'cng_admin_map_srv'));
SELECT pg_temp.ck('IRVAUD-33 the commit still names NO unit or equipment column in its UPDATE',
  (SELECT prosrc !~* 'unit_id\s*=' AND prosrc !~* 'compressor_id\s*='
      AND prosrc !~* 'storage_vessel_id\s*=' AND prosrc !~* 'dispenser_id\s*='
     FROM pg_proc WHERE proname = 'cng_irv_station_batch_commit'));
SELECT pg_temp.ck('IRVAUD-34 authorization unchanged: definer, admin-gated, no actor parameter',
  (SELECT prosecdef AND prosrc LIKE '%cng_require_admin()%'
      AND pg_get_function_arguments(oid) !~* '(actor|changed_by|clerk|app_user)'
      AND NOT has_function_privilege('service_role', oid, 'EXECUTE')
      AND NOT has_function_privilege('anon', oid, 'EXECUTE')
      AND has_function_privilege('authenticated', oid, 'EXECUTE')
     FROM pg_proc WHERE proname = 'cng_irv_station_batch_commit'));
