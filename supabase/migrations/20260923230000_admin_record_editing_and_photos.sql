-- Admin record editing and photos (owner request 2026-09-23: "I want all data to be editable to admin and the
-- option to add an image to the details of the SRV, hose, gas detector, vessel and assets").
--
-- EDITING
--   * One SECURITY DEFINER path, `cng_admin_update_record`, admin-gated by cng_require_admin() (actor derived,
--     never supplied), for an explicit allowlist of tables.
--   * Editable = plain attribute columns only. NEVER editable:
--       - identity and hierarchy links (every uuid column: id, region/station/unit/parent ids) - the hierarchy is
--         changed only through the mapping workflow (CLAUDE.md §4, §9);
--       - mapping_status, resolved_*, archived_*, created_at/updated_at;
--       - original source evidence: every *_raw column, source_file/sheet/row/raw, import_batch_id,
--         location_raw, expected_parent_kind (data principle #6);
--       - generated columns (normalized_name).
--     The editable list is DERIVED from the catalog with that rule, so a new source column is protected by default.
--   * Stale-write guard: the caller sends the updated_at it read; a different value refuses (40001).
--   * Values are cast by the table's own types (jsonb_populate_record), so every CHECK / enum / FK still applies.
--   * One audit row per save with the changed fields only (before and after).
--   Dynamic SQL is used ONLY with identifiers from the allowlist and the catalog, quoted with %I; values are bound.
--
-- PHOTOS
--   * `asset_photos` rows point at an object in the private Storage bucket `asset-photos`.
--   * Anyone who can read the record (under that table's own RLS) can see its photos; only an admin can add or
--     archive one. Archiving hides a photo; nothing is deleted (§10).
--   * JPEG/PNG/WebP, 5 MB max, enforced by the bucket AND the table.
--   The Storage part is conditional: it runs only where the `storage` schema exists (hosted Supabase), so the
--   plain-PostgreSQL gate can still build from zero.

-- ============================================================================ editing
CREATE OR REPLACE FUNCTION cng_admin_editable_tables()
RETURNS text[]
LANGUAGE sql IMMUTABLE
AS $$ SELECT ARRAY['stations','units','compressors','dispensers','storage_vessels','recovery_tanks',
                   'gas_detectors','hoses','installed_relief_valves','warehouse_relief_valves'] $$;

CREATE OR REPLACE FUNCTION cng_admin_editable_columns(p_table text)
RETURNS TABLE (column_name text, data_type text, enum_values text[], is_nullable boolean)
LANGUAGE sql STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT c.column_name::text,
         CASE WHEN c.data_type = 'USER-DEFINED' THEN 'enum' ELSE c.data_type END::text,
         CASE WHEN c.data_type = 'USER-DEFINED'
              THEN (SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder) FROM pg_enum e
                      JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = c.udt_name) END,
         c.is_nullable = 'YES'
    FROM information_schema.columns c
   WHERE c.table_schema = 'public'
     AND c.table_name = p_table
     AND p_table = ANY (cng_admin_editable_tables())
     AND c.is_generated = 'NEVER'
     AND c.data_type IN ('text','numeric','integer','date','boolean','USER-DEFINED')
     AND c.column_name NOT LIKE '%\_raw' ESCAPE '\'
     AND c.column_name NOT LIKE 'source\_%' ESCAPE '\'
     AND c.column_name NOT IN ('mapping_status','expected_parent_kind','import_batch_id')
   ORDER BY c.ordinal_position;
$$;

CREATE OR REPLACE FUNCTION cng_admin_record_for_edit(p_table text, p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_row jsonb;
BEGIN
  PERFORM cng_require_admin();
  IF p_table IS NULL OR NOT (p_table = ANY (cng_admin_editable_tables())) THEN
    RAISE EXCEPTION 'table % is not editable', p_table USING ERRCODE = '22023';
  END IF;
  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id = $1', p_table) INTO v_row USING p_id;
  IF v_row IS NULL THEN RAISE EXCEPTION 'record not found' USING ERRCODE = '42704'; END IF;
  RETURN jsonb_build_object(
    'row', v_row,
    'columns', (SELECT coalesce(jsonb_agg(jsonb_build_object('name', column_name, 'type', data_type,
                  'enum_values', enum_values, 'nullable', is_nullable)), '[]'::jsonb)
                  FROM cng_admin_editable_columns(p_table)));
END;
$$;

CREATE OR REPLACE FUNCTION cng_admin_update_record(
  p_table text, p_id uuid, p_expected_updated_at timestamptz, p_changes jsonb, p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_cols text[]; v_bad text[]; v_before jsonb; v_after jsonb; v_set text; v_now timestamptz := clock_timestamp();
BEGIN
  IF p_table IS NULL OR NOT (p_table = ANY (cng_admin_editable_tables())) THEN
    RAISE EXCEPTION 'table % is not editable', p_table USING ERRCODE = '22023';
  END IF;
  IF p_changes IS NULL OR jsonb_typeof(p_changes) <> 'object' OR p_changes = '{}'::jsonb THEN
    RAISE EXCEPTION 'no changes supplied' USING ERRCODE = '22023';
  END IF;
  IF p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'the version you edited (updated_at) is required' USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(k) INTO v_bad FROM jsonb_object_keys(p_changes) k
   WHERE k NOT IN (SELECT column_name FROM cng_admin_editable_columns(p_table));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'these fields cannot be edited: %', array_to_string(v_bad, ', ') USING ERRCODE = '42501';
  END IF;
  SELECT array_agg(k ORDER BY k) INTO v_cols FROM jsonb_object_keys(p_changes) k;

  EXECUTE format('SELECT to_jsonb(t) FROM public.%I t WHERE t.id = $1 FOR UPDATE', p_table) INTO v_before USING p_id;
  IF v_before IS NULL THEN RAISE EXCEPTION 'record not found' USING ERRCODE = '42704'; END IF;
  IF (v_before->>'updated_at')::timestamptz IS DISTINCT FROM p_expected_updated_at THEN
    RAISE EXCEPTION 'this record was changed by someone else; reload it and try again' USING ERRCODE = '40001';
  END IF;

  SELECT string_agg(format('%I = r.%I', c, c), ', ') INTO v_set FROM unnest(v_cols) c;
  EXECUTE format(
    'UPDATE public.%I t SET %s, updated_at = $3 FROM jsonb_populate_record(NULL::public.%I, $2) r WHERE t.id = $1 RETURNING to_jsonb(t)',
    p_table, v_set, p_table)
    INTO v_after USING p_id, p_changes, v_now;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', p_table, p_id, v_actor, 'admin_edit',
          format('Admin edited %s: %s. %s', p_table, array_to_string(v_cols, ', '), coalesce(p_reason, '')),
          (SELECT jsonb_object_agg(c, v_before->c) FROM unnest(v_cols) c),
          (SELECT jsonb_object_agg(c, v_after->c) FROM unnest(v_cols) c),
          v_now);
  RETURN v_after;
END;
$$;

COMMENT ON FUNCTION cng_admin_update_record(text, uuid, timestamptz, jsonb, text) IS
  'Admin-only edit of plain attribute columns (derived allowlist); stale-write guarded; one audit row per save. Hierarchy links, mapping state and raw source evidence are never editable here.';

REVOKE ALL ON FUNCTION cng_admin_editable_tables() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_editable_tables() TO authenticated;
REVOKE ALL ON FUNCTION cng_admin_editable_columns(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_editable_columns(text) TO authenticated;
REVOKE ALL ON FUNCTION cng_admin_record_for_edit(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_record_for_edit(text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION cng_admin_update_record(text, uuid, timestamptz, jsonb, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_update_record(text, uuid, timestamptz, jsonb, text) TO authenticated;

-- ============================================================================ photos
CREATE TABLE IF NOT EXISTS asset_photos (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_table  text NOT NULL CHECK (entity_table = ANY (cng_admin_editable_tables())),
  entity_id     uuid NOT NULL,
  storage_path  text NOT NULL UNIQUE,
  content_type  text NOT NULL CHECK (content_type IN ('image/jpeg','image/png','image/webp')),
  byte_size     integer NOT NULL CHECK (byte_size > 0 AND byte_size <= 5242880),
  caption       text NULL,
  uploaded_by   uuid NOT NULL REFERENCES app_users(id),
  uploaded_at   timestamptz NOT NULL DEFAULT now(),
  archived_at   timestamptz NULL,
  archived_by   uuid NULL REFERENCES app_users(id),
  CONSTRAINT asset_photos_path_ck CHECK (storage_path LIKE entity_table || '/' || entity_id::text || '/%')
);
CREATE INDEX IF NOT EXISTS asset_photos_entity_idx ON asset_photos (entity_table, entity_id) WHERE archived_at IS NULL;
ALTER TABLE asset_photos ENABLE ROW LEVEL SECURITY;

-- Can the CALLER read this record? SECURITY INVOKER, so each table's own RLS decides.
CREATE OR REPLACE FUNCTION cng_can_read_entity(p_table text, p_id uuid)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT CASE p_table
    WHEN 'stations' THEN EXISTS (SELECT 1 FROM stations WHERE id = p_id)
    WHEN 'units' THEN EXISTS (SELECT 1 FROM units WHERE id = p_id)
    WHEN 'compressors' THEN EXISTS (SELECT 1 FROM compressors WHERE id = p_id)
    WHEN 'dispensers' THEN EXISTS (SELECT 1 FROM dispensers WHERE id = p_id)
    WHEN 'storage_vessels' THEN EXISTS (SELECT 1 FROM storage_vessels WHERE id = p_id)
    WHEN 'recovery_tanks' THEN EXISTS (SELECT 1 FROM recovery_tanks WHERE id = p_id)
    WHEN 'gas_detectors' THEN EXISTS (SELECT 1 FROM gas_detectors WHERE id = p_id)
    WHEN 'hoses' THEN EXISTS (SELECT 1 FROM hoses WHERE id = p_id)
    WHEN 'installed_relief_valves' THEN EXISTS (SELECT 1 FROM installed_relief_valves WHERE id = p_id)
    WHEN 'warehouse_relief_valves' THEN EXISTS (SELECT 1 FROM warehouse_relief_valves WHERE id = p_id)
    ELSE false END;
$$;
REVOKE ALL ON FUNCTION cng_can_read_entity(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_can_read_entity(text, uuid) TO authenticated;

DROP POLICY IF EXISTS asset_photos_select ON asset_photos;
CREATE POLICY asset_photos_select ON asset_photos FOR SELECT TO authenticated
  USING ((SELECT cng_is_admin()) OR (archived_at IS NULL AND cng_can_read_entity(entity_table, entity_id)));
REVOKE ALL ON asset_photos FROM anon, authenticated;
GRANT SELECT ON asset_photos TO authenticated;

CREATE OR REPLACE FUNCTION cng_admin_add_photo(
  p_table text, p_id uuid, p_storage_path text, p_content_type text, p_byte_size integer, p_caption text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); v_id uuid; v_exists boolean;
BEGIN
  IF NOT (p_table = ANY (cng_admin_editable_tables())) THEN
    RAISE EXCEPTION 'photos cannot be attached to %', p_table USING ERRCODE = '22023';
  END IF;
  EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I WHERE id = $1)', p_table) INTO v_exists USING p_id;
  IF NOT v_exists THEN RAISE EXCEPTION 'record not found' USING ERRCODE = '42704'; END IF;
  IF to_regclass('storage.objects') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM storage.objects WHERE bucket_id = ''asset-photos'' AND name = $1)'
      INTO v_exists USING p_storage_path;
    IF NOT v_exists THEN RAISE EXCEPTION 'the uploaded file was not found' USING ERRCODE = '42704'; END IF;
  END IF;
  INSERT INTO asset_photos (entity_table, entity_id, storage_path, content_type, byte_size, caption, uploaded_by)
  VALUES (p_table, p_id, p_storage_path, p_content_type, p_byte_size, nullif(btrim(p_caption), ''), v_actor)
  RETURNING id INTO v_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', 'asset_photos', v_id, v_actor, 'admin_photo',
          format('Photo added to %s %s', p_table, p_id), NULL,
          jsonb_build_object('entity_table', p_table, 'entity_id', p_id, 'storage_path', p_storage_path), now());
  RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION cng_admin_archive_photo(p_photo_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); v_row asset_photos;
BEGIN
  UPDATE asset_photos SET archived_at = now(), archived_by = v_actor
   WHERE id = p_photo_id AND archived_at IS NULL RETURNING * INTO v_row;
  IF v_row.id IS NULL THEN RAISE EXCEPTION 'photo not found or already removed' USING ERRCODE = '42704'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', 'asset_photos', p_photo_id, v_actor, 'admin_photo',
          format('Photo removed from %s %s (archived, file kept)', v_row.entity_table, v_row.entity_id),
          jsonb_build_object('archived_at', NULL), jsonb_build_object('archived_at', v_row.archived_at), now());
END;
$$;

REVOKE ALL ON FUNCTION cng_admin_add_photo(text, uuid, text, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_photo(text, uuid, text, text, integer, text) TO authenticated;
REVOKE ALL ON FUNCTION cng_admin_archive_photo(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_archive_photo(uuid) TO authenticated;

-- Storage (hosted Supabase only).
DO $storage$
BEGIN
  IF to_regclass('storage.buckets') IS NULL THEN
    RAISE NOTICE 'storage schema not present: asset-photos bucket and policies skipped';
    RETURN;
  END IF;
  INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  VALUES ('asset-photos', 'asset-photos', false, 5242880, ARRAY['image/jpeg','image/png','image/webp'])
  ON CONFLICT (id) DO UPDATE SET public = false, file_size_limit = 5242880,
                                 allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp'];

  EXECUTE 'DROP POLICY IF EXISTS asset_photos_upload ON storage.objects';
  EXECUTE $p$CREATE POLICY asset_photos_upload ON storage.objects FOR INSERT TO authenticated
            WITH CHECK (bucket_id = 'asset-photos' AND (SELECT public.cng_is_admin()))$p$;
  EXECUTE 'DROP POLICY IF EXISTS asset_photos_read ON storage.objects';
  EXECUTE $p$CREATE POLICY asset_photos_read ON storage.objects FOR SELECT TO authenticated
            USING (bucket_id = 'asset-photos' AND ((SELECT public.cng_is_admin())
                   OR EXISTS (SELECT 1 FROM public.asset_photos p WHERE p.storage_path = name)))$p$;
END
$storage$;
