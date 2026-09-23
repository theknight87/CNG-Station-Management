-- admin_editing_photos.sql — regression suite for 20260923230000_admin_record_editing_and_photos.sql
\set ON_ERROR_STOP on
SET client_min_messages TO notice;
BEGIN;

CREATE FUNCTION pg_temp.ck(l text, c boolean) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF c THEN RAISE NOTICE 'PASS  %', l; ELSE RAISE NOTICE 'FAILED: %', l; END IF; END $$;
CREATE FUNCTION pg_temp.become(p_sub text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM set_config('request.jwt.claims', CASE WHEN p_sub IS NULL THEN '{"role":"authenticated"}'
          ELSE json_build_object('sub', p_sub, 'role', 'authenticated')::text END, true);
  EXECUTE 'SET LOCAL ROLE authenticated';
END $$;
CREATE FUNCTION pg_temp.try_as(p_sub text, p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text := 'OK';
BEGIN
  PERFORM pg_temp.become(p_sub);
  BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN s := SQLSTATE; END;
  EXECUTE 'RESET ROLE';
  RETURN s;
END $$;

INSERT INTO app_users (id, clerk_user_id, role, is_active, full_name) VALUES
  ('ed000000-0000-0000-0000-00000000000a','ed_admin','admin',true,'TESTDATA ED Admin'),
  ('ed000000-0000-0000-0000-00000000000b','ed_manager','manager',true,'TESTDATA ED Manager'),
  ('ed000000-0000-0000-0000-00000000000c','ed_eng','engineer',true,'TESTDATA ED Engineer'),
  ('ed000000-0000-0000-0000-00000000000d','ed_west','engineer',true,'TESTDATA ED West Engineer'),
  ('ed000000-0000-0000-0000-00000000000f','ed_off','admin',false,'TESTDATA ED Inactive');
INSERT INTO user_region_access (app_user_id, region_id, can_map)
SELECT 'ed000000-0000-0000-0000-00000000000c'::uuid, id, true FROM regions WHERE name = 'East'
UNION ALL SELECT 'ed000000-0000-0000-0000-00000000000d'::uuid, id, true FROM regions WHERE name = 'West';

INSERT INTO stations (id, region_id, station_name) SELECT 'ed100000-0000-0000-0000-000000000001', id, 'TED STATION' FROM regions WHERE name = 'East';
INSERT INTO units (id, station_id, region_id, unit_name) SELECT 'ed200000-0000-0000-0000-000000000001', 'ed100000-0000-0000-0000-000000000001', id, 'TED UNIT' FROM regions WHERE name = 'East';
INSERT INTO installed_relief_valves (id, region_id, station_id, unit_id, mapping_status, serial_number, serial_number_raw,
                                     set_pressure_raw, pressure_min, pressure_max, pressure_unit)
SELECT 'ed300000-0000-0000-0000-000000000001', id, 'ed100000-0000-0000-0000-000000000001', NULL, 'needs_unit_mapping',
       'SER-1', 'SER-1 raw', '300 BAR', 300, 300, 'BAR' FROM regions WHERE name = 'East';

-- ------------------------------------------------------------------ editable-column rule
SELECT pg_temp.ck('EDIT-1 raw source, hierarchy links, mapping state and system columns are never editable',
  NOT EXISTS (SELECT 1 FROM unnest(cng_admin_editable_tables()) t, cng_admin_editable_columns(t) c
               WHERE c.column_name LIKE '%\_raw' ESCAPE '\' OR c.column_name LIKE 'source\_%' ESCAPE '\'
                  OR c.column_name IN ('id','region_id','station_id','unit_id','compressor_id','storage_vessel_id',
                                       'dispenser_id','mapping_status','normalized_name','created_at','updated_at',
                                       'archived_at','archived_by','resolved_by','resolved_at','import_batch_id')));
SELECT pg_temp.ck('EDIT-2 plain attributes are editable (serial, pressures, warehouse code, notes)',
  (SELECT count(*) FROM cng_admin_editable_columns('installed_relief_valves')
    WHERE column_name IN ('serial_number','pressure_min','pressure_max','pressure_unit','warehouse_code','notes')) = 6);

-- ------------------------------------------------------------------ who may edit
SELECT pg_temp.ck('EDIT-3 manager, engineer, inactive admin and no-subject are refused (42501)',
  (SELECT bool_and(pg_temp.try_as(s, $q$SELECT cng_admin_update_record('installed_relief_valves',
     'ed300000-0000-0000-0000-000000000001', now(), '{"notes":"x"}')$q$) = '42501')
     FROM unnest(ARRAY['ed_manager','ed_eng','ed_off',NULL]) s));
SELECT pg_temp.ck('EDIT-4 a non-admin cannot even read the edit form',
  pg_temp.try_as('ed_eng', $q$SELECT cng_admin_record_for_edit('installed_relief_valves','ed300000-0000-0000-0000-000000000001')$q$) = '42501');

-- ------------------------------------------------------------------ admin edits
CREATE TEMP TABLE ver AS SELECT updated_at FROM installed_relief_valves WHERE id = 'ed300000-0000-0000-0000-000000000001';
GRANT SELECT ON ver TO authenticated;
SELECT pg_temp.ck('EDIT-5 admin reads the form: row plus editable columns',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_record_for_edit('installed_relief_valves','ed300000-0000-0000-0000-000000000001')$q$) = 'OK');
SELECT pg_temp.ck('EDIT-6 editing a raw or hierarchy field is refused (42501)',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM ver), '{"serial_number_raw":"x"}')$q$) = '42501'
  AND pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM ver), '{"station_id":null}')$q$) = '42501');
SELECT pg_temp.ck('EDIT-7 a stale version is refused (PT409)',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     '2000-01-01', '{"notes":"x"}')$q$) = 'PT409');
SELECT pg_temp.ck('EDIT-8 a table outside the allowlist is refused (22023)',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('app_users','ed000000-0000-0000-0000-00000000000c',
     now(), '{"role":"admin"}')$q$) = '22023');
SELECT pg_temp.ck('EDIT-9 a CHECK still applies (negative count refused)',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('units','ed200000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM units WHERE id='ed200000-0000-0000-0000-000000000001'), '{"dispenser_count_reported":-1}')$q$) = '23514');
SELECT pg_temp.ck('EDIT-10 admin saves serial, pressure and warehouse code',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM ver), '{"serial_number":"SER-1A","pressure_min":310,"pressure_max":310,"warehouse_code":"W-9"}', 'test')$q$) = 'OK');
SELECT pg_temp.ck('EDIT-11 values stored with their types; raw evidence untouched',
  (SELECT (serial_number, pressure_min, warehouse_code, serial_number_raw, set_pressure_raw)
          = ('SER-1A', 310::numeric, 'W-9', 'SER-1 raw', '300 BAR')
     FROM installed_relief_valves WHERE id = 'ed300000-0000-0000-0000-000000000001'));
SELECT pg_temp.ck('EDIT-12 one audit row with the admin as actor and only changed fields',
  (SELECT count(*) FROM audit_logs WHERE entity_id = 'ed300000-0000-0000-0000-000000000001' AND actor_label = 'admin_edit'
     AND actor_id = 'ed000000-0000-0000-0000-00000000000a'
     AND before_data = '{"pressure_max":300,"pressure_min":300,"serial_number":"SER-1","warehouse_code":null}'::jsonb
     AND after_data->>'warehouse_code' = 'W-9') = 1);
-- Another admin saved in between (separate transactions get different now(); simulate it here).
ALTER TABLE installed_relief_valves DISABLE TRIGGER irv_set_updated_at;
UPDATE installed_relief_valves SET updated_at = updated_at + interval '1 second' WHERE id = 'ed300000-0000-0000-0000-000000000001';
ALTER TABLE installed_relief_valves ENABLE TRIGGER irv_set_updated_at;
SELECT pg_temp.ck('EDIT-13 a save made after someone else''s save is refused (PT409)',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM ver), '{"notes":"y"}')$q$) = 'PT409');
SELECT pg_temp.try_as('ed_admin', $q$SELECT cng_admin_update_record('units','ed200000-0000-0000-0000-000000000001',
     (SELECT updated_at FROM units WHERE id='ed200000-0000-0000-0000-000000000001'), '{"unit_name":"TED UNIT 1"}')$q$) AS edit14 \gset
SELECT pg_temp.ck('EDIT-14 renaming a Unit keeps its generated identity in step',
  :'edit14' = 'OK' AND (SELECT normalized_name FROM units WHERE id = 'ed200000-0000-0000-0000-000000000001') = cng_normalize_name('TED UNIT 1'));

-- ------------------------------------------------------------------ photos
SELECT pg_temp.ck('PHOTO-1 a non-admin cannot attach a photo (42501)',
  pg_temp.try_as('ed_eng', $q$SELECT cng_admin_add_photo('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     'installed_relief_valves/ed300000-0000-0000-0000-000000000001/a.jpg','image/jpeg',1000)$q$) = '42501');
SELECT pg_temp.ck('PHOTO-2 admin attaches a photo',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_add_photo('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     'installed_relief_valves/ed300000-0000-0000-0000-000000000001/a.jpg','image/jpeg',1000,'Nameplate')$q$) = 'OK');
SELECT pg_temp.ck('PHOTO-3 path must sit under its own record; type and size are enforced',
  pg_temp.try_as('ed_admin', $q$SELECT cng_admin_add_photo('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     'hoses/other/b.jpg','image/jpeg',1000)$q$) = '23514'
  AND pg_temp.try_as('ed_admin', $q$SELECT cng_admin_add_photo('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     'installed_relief_valves/ed300000-0000-0000-0000-000000000001/c.gif','image/gif',1000)$q$) = '23514'
  AND pg_temp.try_as('ed_admin', $q$SELECT cng_admin_add_photo('installed_relief_valves','ed300000-0000-0000-0000-000000000001',
     'installed_relief_valves/ed300000-0000-0000-0000-000000000001/d.jpg','image/jpeg',6000000)$q$) = '23514');

CREATE FUNCTION pg_temp.photos_seen_by(p_sub text) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint;
BEGIN
  PERFORM pg_temp.become(p_sub);
  SELECT count(*) INTO n FROM asset_photos WHERE entity_id = 'ed300000-0000-0000-0000-000000000001';
  EXECUTE 'RESET ROLE';
  RETURN n;
END $$;
SELECT pg_temp.ck('PHOTO-4 an East engineer who can read the valve sees its photo', pg_temp.photos_seen_by('ed_eng') = 1);
SELECT pg_temp.ck('PHOTO-5 a West-only engineer who cannot read the valve does not', pg_temp.photos_seen_by('ed_west') = 0);
SELECT pg_temp.ck('PHOTO-6 no subject sees nothing', pg_temp.photos_seen_by(NULL) = 0);
SELECT pg_temp.ck('PHOTO-7 browsers have no direct write on asset_photos',
  NOT has_table_privilege('authenticated', 'asset_photos', 'INSERT')
  AND NOT has_table_privilege('authenticated', 'asset_photos', 'UPDATE')
  AND NOT has_table_privilege('authenticated', 'asset_photos', 'DELETE'));
SELECT pg_temp.try_as('ed_admin', $q$SELECT cng_admin_archive_photo((SELECT id FROM asset_photos WHERE caption = 'Nameplate'))$q$) AS photo8_state \gset
SELECT pg_temp.ck('PHOTO-8 archive: ' || :'photo8_state', :'photo8_state' = 'OK'
  AND pg_temp.photos_seen_by('ed_eng') = 0
  AND (SELECT count(*) FROM asset_photos WHERE caption = 'Nameplate' AND archived_by = 'ed000000-0000-0000-0000-00000000000a') = 1);
SELECT pg_temp.ck('PHOTO-9 photo add and archive are audited with the admin as actor',
  (SELECT count(*) FROM audit_logs WHERE entity_table = 'asset_photos' AND actor_id = 'ed000000-0000-0000-0000-00000000000a') = 2);
SELECT pg_temp.ck('PHOTO-10 all new definer functions pin search_path; anon can execute none',
  (SELECT bool_and(proconfig::text LIKE '%search_path%') FROM pg_proc
    WHERE proname IN ('cng_admin_record_for_edit','cng_admin_update_record','cng_admin_add_photo','cng_admin_archive_photo'))
  AND NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname IN ('cng_admin_record_for_edit','cng_admin_update_record',
     'cng_admin_add_photo','cng_admin_archive_photo','cng_can_read_entity') AND has_function_privilege('anon', oid, 'EXECUTE')));

ROLLBACK;
