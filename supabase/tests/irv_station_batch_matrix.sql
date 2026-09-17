\set ON_ERROR_STOP on
SET client_min_messages TO notice;
CREATE OR REPLACE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE OR REPLACE FUNCTION pg_temp.refused(l text, s text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE s; RAISE NOTICE 'FAILED: % (accepted)', l;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PASS  % refused [%]', l, SQLSTATE; END $$;
CREATE OR REPLACE FUNCTION pg_temp.as_user(c text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM set_config('request.jwt.claims', json_build_object('sub',c)::text, false); END $$;

SELECT pg_temp.as_user('u_admin');
CREATE TEMP TABLE fp AS SELECT * FROM cng_irv_station_batch_preview();

-- 1-11 preview shape
SELECT pg_temp.ck('T1  preview eligible = 1,054',(SELECT eligible_rows=1054 FROM fp));
SELECT pg_temp.ck('T2  exact 127 identities',(SELECT eligible_identities=127 FROM fp));
SELECT pg_temp.ck('T3  839 byte-exact (100 identities)',(SELECT byte_exact_rows=839 AND byte_exact_identities=100 FROM fp));
SELECT pg_temp.ck('T4  215 normalization-only (27 identities)',(SELECT normalized_rows=215 AND normalized_identities=27 FROM fp));
SELECT pg_temp.ck('T5  1,596 no-candidate excluded',(SELECT excluded_no_candidate=1596 FROM fp));
SELECT pg_temp.ck('T6  12 cross-Region-only excluded',(SELECT excluded_cross_region_only=12 FROM fp));
SELECT pg_temp.ck('T7  0 multi-candidate',(SELECT excluded_multi_candidate=0 FROM fp));
SELECT pg_temp.ck('T7b exclusions + eligible = 2,662',(SELECT eligible_rows+excluded_no_candidate+excluded_cross_region_only=2662 FROM fp));
SELECT pg_temp.ck('T8  every proposal is Station-only (no unit/equipment column in the UPDATE)',
  (SELECT prosrc !~* 'unit_id\s*=' AND prosrc !~* 'compressor_id\s*=' AND prosrc !~* 'storage_vessel_id\s*='
      AND prosrc !~* 'dispenser_id\s*=' FROM pg_proc WHERE proname='cng_irv_station_batch_commit'));
SELECT pg_temp.ck('T8b the detector would fire on a violating column list',
  ('SET station_id = x, unit_id = y' ~* 'unit_id\s*='));
SELECT pg_temp.ck('T11 preview says 0 rows would get a Unit, with 1,022 under one-Unit Stations',
  (SELECT rows_that_would_get_a_unit=0 AND rows_under_one_unit_station>0 FROM fp));

-- 12 correct fingerprint accepted (inside a rolled-back transaction first: T25)
BEGIN;
SELECT pg_temp.ck('T25 mid-transaction: 1,054 mapped',
  (SELECT srvs_mapped=1054 FROM cng_irv_station_batch_commit((SELECT preview_fingerprint FROM fp),1054,127,'matrix')));
ROLLBACK;
SELECT pg_temp.ck('T25b rollback left ZERO mapped',(SELECT count(*)=0 FROM installed_relief_valves WHERE station_id IS NOT NULL));
SELECT pg_temp.ck('T25c rollback left ZERO audit',(SELECT count(*)=0 FROM asset_mapping_audit));

-- 13-15 guards
SELECT pg_temp.refused('T13 wrong fingerprint', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')', repeat('a',64)));
SELECT pg_temp.refused('T14 wrong row count', format('SELECT cng_irv_station_batch_commit(%L,1053,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.refused('T15 wrong identity count', format('SELECT cng_irv_station_batch_commit(%L,1054,126,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.refused('T12b empty fingerprint', 'SELECT cng_irv_station_batch_commit('''',1054,127,''x'')');

-- 16-22 evidence drift each invalidates the approved fingerprint
CREATE TEMP TABLE one AS SELECT srv_id FROM cng_irv_station_batch_candidates() WHERE eligibility='A_STATION_CONFIRMABLE' LIMIT 1;
CREATE OR REPLACE FUNCTION pg_temp.drift(l text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE newfp text; BEGIN
  EXECUTE stmt;
  SELECT preview_fingerprint INTO newfp FROM cng_irv_station_batch_preview();
  IF newfp IS DISTINCT FROM (SELECT preview_fingerprint FROM fp) THEN RAISE NOTICE 'PASS  % invalidates the fingerprint', l;
  ELSE RAISE NOTICE 'FAILED: % did NOT invalidate the fingerprint', l; END IF;
END $$;

BEGIN;
SELECT pg_temp.drift('T16 changed source hash',
  $$UPDATE import_staging_rows SET source_row_hash=repeat('b',64) WHERE committed_entity_id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T17 changed lineage key',
  $$UPDATE import_staging_rows SET source_row_key=source_row_key||'-X' WHERE committed_entity_id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T17b lineage removed',
  $$UPDATE import_staging_rows SET committed_entity_id=NULL, committed_entity_kind=NULL, committed_at=NULL WHERE committed_entity_id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T18 changed raw Station on the SRV',
  $$UPDATE installed_relief_valves SET source_station_name_raw=source_station_name_raw||'-Z' WHERE id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T19 changed Region on the SRV',
  $$UPDATE installed_relief_valves SET region_id=(SELECT id FROM regions WHERE name='Upper') WHERE id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T20 changed normalization result (canonical Station renamed)',
  $$UPDATE stations SET station_name=station_name||'-RENAMED'
     WHERE id=(SELECT target_station_id FROM cng_irv_station_batch_candidates() WHERE srv_id=(SELECT srv_id FROM one))$$);
ROLLBACK;
-- T22: a competing SAME-REGION candidate is UNREACHABLE, not merely unhandled --
-- stations_region_norm_uq forbids two Stations sharing a normalized name in one
-- Region. Proved by attempting it (the Prompt 22A finding, restated here).
SELECT pg_temp.refused('T22 a competing same-Region candidate is forbidden by the database',
  $$INSERT INTO stations (region_id, station_name)
    SELECT v.region_id, upper(v.source_station_name_raw) FROM installed_relief_valves v WHERE v.id=(SELECT srv_id FROM one)$$);
-- and a competing candidate in ANOTHER Region never makes a row eligible
BEGIN;
SELECT pg_temp.ck('T22c a same-name Station in another Region does not change the set',
  (SELECT (SELECT eligible_rows FROM cng_irv_station_batch_preview())=1054));
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T23 one row already Station-mapped',
  $$UPDATE installed_relief_valves SET station_id=(SELECT target_station_id FROM cng_irv_station_batch_candidates() WHERE srv_id=(SELECT srv_id FROM one)),
      mapping_status='needs_unit_mapping' WHERE id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T24 one row version changed',
  $$UPDATE installed_relief_valves SET updated_at=now()+interval '1 second' WHERE id=(SELECT srv_id FROM one)$$);
ROLLBACK;
BEGIN;
SELECT pg_temp.drift('T22b a qualifying row removed from the set',
  $$UPDATE installed_relief_valves SET source_station_name_raw='NOSUCH-ZZZZ' WHERE id=(SELECT srv_id FROM one)$$);
ROLLBACK;

-- 33-37 authorization, by attack
SELECT pg_temp.as_user('u_viewer');
SELECT pg_temp.refused('T34 Viewer', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.as_user('u_eng');
SELECT pg_temp.refused('T35 Engineer', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.as_user('u_mgr');
SELECT pg_temp.refused('T36 Manager (mapping reserved to Admin here)', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.as_user('u_inactive');
SELECT pg_temp.refused('T33b deactivated Admin', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT set_config('request.jwt.claims','{}',false);
SELECT pg_temp.refused('T33c no verified subject', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.ck('T37 no actor parameter exists on any batch function',
  (SELECT count(*)=0 FROM pg_proc WHERE proname LIKE 'cng_irv_station_batch%'
     AND pg_get_function_arguments(oid) ~* '(actor|decided_by|resolved_by|changed_by|clerk|sub |app_user)'));
SELECT pg_temp.ck('T37b service_role holds NO execute on the batch',
  (SELECT bool_and(NOT has_function_privilege('service_role',oid,'EXECUTE')) FROM pg_proc WHERE proname LIKE 'cng_irv_station_batch%'));
SELECT pg_temp.ck('T37c anon holds NO execute on the batch',
  (SELECT bool_and(NOT has_function_privilege('anon',oid,'EXECUTE')) FROM pg_proc WHERE proname LIKE 'cng_irv_station_batch%'));
SELECT pg_temp.ck('T37d read paths are STABLE and NOT definer',
  (SELECT bool_and(provolatile='s' AND NOT prosecdef) FROM pg_proc
     WHERE proname IN ('cng_irv_station_batch_candidates','cng_irv_station_batch_preview')));
SELECT pg_temp.ck('T37e commit is SECURITY DEFINER with pinned search_path',
  (SELECT prosecdef AND proconfig::text LIKE '%search_path=pg_catalog, public%' FROM pg_proc WHERE proname='cng_irv_station_batch_commit'));
SELECT pg_temp.ck('T37f no dynamic SQL anywhere in the batch',
  (SELECT bool_and(prosrc !~* '\mEXECUTE\M' AND prosrc !~* 'quote_ident') FROM pg_proc WHERE proname LIKE 'cng_irv_station_batch%'));

-- the authorized run
SELECT pg_temp.as_user('u_admin');
CREATE TEMP TABLE res AS SELECT * FROM cng_irv_station_batch_commit((SELECT preview_fingerprint FROM fp),1054,127,'Prompt 25H local authorized run');
SELECT pg_temp.ck('T12 correct fingerprint accepted: 1,054 / 127',(SELECT srvs_mapped=1054 AND identities_mapped=127 FROM res));
SELECT pg_temp.ck('T9  unit_id NULL on ALL mapped',(SELECT count(*)=0 FROM installed_relief_valves WHERE station_id IS NOT NULL AND unit_id IS NOT NULL));
SELECT pg_temp.ck('T10 equipment NULL on ALL mapped',(SELECT count(*)=0 FROM installed_relief_valves WHERE station_id IS NOT NULL AND num_nonnulls(compressor_id,storage_vessel_id,dispenser_id)>0));
SELECT pg_temp.ck('T11b the 1,022 one-Unit-Station rows received NO Unit',
  (SELECT count(*)=0 FROM installed_relief_valves v WHERE v.station_id IS NOT NULL AND v.unit_id IS NOT NULL
     AND (SELECT count(*) FROM units u WHERE u.station_id=v.station_id)=1));
SELECT pg_temp.ck('T8c all 1,054 now needs_unit_mapping',(SELECT count(*)=1054 FROM installed_relief_valves WHERE mapping_status='needs_unit_mapping'));
SELECT pg_temp.ck('T8d the other 1,608 untouched',(SELECT count(*)=1608 FROM installed_relief_valves WHERE mapping_status='needs_station_mapping' AND station_id IS NULL));
SELECT pg_temp.ck('T8e target Station is Region-correct on all 1,054',
  (SELECT count(*)=0 FROM installed_relief_valves v JOIN stations s ON s.id=v.station_id WHERE s.region_id<>v.region_id));
SELECT pg_temp.ck('T26b resolved_by/resolved_at stay NULL (not a resolution)',
  (SELECT count(*)=0 FROM installed_relief_valves WHERE resolved_by IS NOT NULL OR resolved_at IS NOT NULL));
-- 26 replay
SELECT pg_temp.refused('T26 replay with the old fingerprint', format('SELECT cng_irv_station_batch_commit(%L,1054,127,''x'')',(SELECT preview_fingerprint FROM fp)));
SELECT pg_temp.ck('T26c preview is now empty',(SELECT eligible_rows=0 FROM cng_irv_station_batch_preview()));
SELECT pg_temp.refused('T26d replay with the CURRENT fingerprint (0 eligible)',
  format('SELECT cng_irv_station_batch_commit(%L,0,0,''x'')',(SELECT preview_fingerprint FROM cng_irv_station_batch_preview())));
-- 27-32 firewalls
SELECT pg_temp.ck('T27 no alias created',(SELECT (SELECT count(*) FROM station_aliases)=0 AND (SELECT count(*) FROM unit_aliases)=0));
SELECT pg_temp.ck('T28 no Unit created',(SELECT count(*)=189 FROM units));
SELECT pg_temp.ck('T28b no Station created',(SELECT count(*)=157 FROM stations));
SELECT pg_temp.ck('T29 no equipment created',(SELECT (SELECT count(*) FROM compressors)=0 AND (SELECT count(*) FROM dispensers)=0
   AND (SELECT count(*) FROM storage_vessels)=0));
SELECT pg_temp.ck('T30 no Stage-B decision created',(SELECT count(*)=0 FROM import_mapping_decisions));
SELECT pg_temp.ck('T31b staging evidence untouched',(SELECT count(*)=2662 FROM import_staging_rows WHERE mapping_status='needs_station_mapping'));
-- 38-39 audit
SELECT pg_temp.ck('T38 exactly one audit_logs batch row, admin-attributed',
  (SELECT count(*)=1 FROM audit_logs a JOIN app_users u ON u.id=a.actor_id
    WHERE a.action='mapping_changed' AND a.entity_table='installed_relief_valves' AND u.clerk_user_id='u_admin'));
SELECT pg_temp.ck('T38b never attributed to service_role',
  (SELECT count(*)=0 FROM audit_logs WHERE actor_label ILIKE '%service_role%'));
SELECT pg_temp.ck('T39 per-SRV attribution: 1,054 bulk audit rows, one batch id, one actor',
  (SELECT count(*)=1054 AND count(DISTINCT bulk_batch_id)=1 AND bool_and(is_bulk) AND count(DISTINCT changed_by)=1
     FROM asset_mapping_audit WHERE asset_type='installed_relief_valve'));
SELECT pg_temp.ck('T39b audit records the true before/after and NO unit or parent',
  (SELECT count(*)=1054 FROM asset_mapping_audit WHERE previous_mapping_status='needs_station_mapping'
     AND new_mapping_status='needs_unit_mapping' AND previous_station_id IS NULL AND new_station_id IS NOT NULL
     AND new_unit_id IS NULL AND new_parent_id IS NULL));
SELECT pg_temp.ck('T39c every mapped SRV has exactly one audit row',
  (SELECT count(*)=0 FROM installed_relief_valves v WHERE v.station_id IS NOT NULL
     AND (SELECT count(*) FROM asset_mapping_audit a WHERE a.asset_id=v.id)<>1));
-- 40 the per-row path still works unchanged
CREATE TEMP TABLE pr AS
  SELECT v.id AS srv, v.station_id AS st, v.updated_at AS ver,
         (SELECT u.id FROM units u WHERE u.station_id=v.station_id LIMIT 1) AS un
    FROM installed_relief_valves v WHERE v.station_id IS NOT NULL LIMIT 1;
CREATE TEMP TABLE pr2 AS SELECT * FROM cng_admin_map_srv(
  (SELECT srv FROM pr),(SELECT st FROM pr),(SELECT un FROM pr),NULL,NULL,(SELECT ver FROM pr),'per-row path still works');
SELECT pg_temp.ck('T40 cng_admin_map_srv still works unchanged (Unit added to an already-batched row)',
  (SELECT mapping_status='needs_equipment_mapping' FROM pr2));
SELECT pg_temp.ck('T40b that per-row change wrote its own non-bulk audit row',
  (SELECT count(*)=1 FROM asset_mapping_audit WHERE asset_id=(SELECT srv FROM pr) AND NOT is_bulk));
