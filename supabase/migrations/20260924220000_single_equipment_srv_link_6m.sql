-- Phase 6m: installed SRVs linked to the only equipment of their kind in their Unit.
--
-- Owner ruling 2026-09-24 (asked explicitly, CLAUDE.md §4 requires it): an installed SRV awaiting equipment mapping
-- whose source Location is Stage belongs to its Unit's compressor when the Unit has exactly one; one whose Location is
-- Storage belongs to its Unit's storage vessel when the Unit has exactly one. Units with several vessels, or with no
-- compressor/vessel, are left untouched (the owner chose to hold them). resolved_by is the owner who ruled: the single
-- active admin, derived server-side; the commit refuses if there is not exactly one. Records changed since the preview
-- are refused (updated_at guard). service_role only, prefix 6M. No DML here.

CREATE OR REPLACE FUNCTION cng_6m_proposal()
RETURNS TABLE (srv_id uuid, unit_id uuid, parent_kind text, parent_id uuid, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH c1 AS MATERIALIZED (
    SELECT c.unit_id, min(c.id::text)::uuid AS id FROM compressors c WHERE c.archived_at IS NULL AND c.unit_id IS NOT NULL
     GROUP BY c.unit_id HAVING count(*) = 1
  ), v1 AS MATERIALIZED (
    SELECT v.unit_id, min(v.id::text)::uuid AS id FROM storage_vessels v WHERE v.archived_at IS NULL AND v.unit_id IS NOT NULL
     GROUP BY v.unit_id HAVING count(*) = 1
  )
  SELECT i.id, i.unit_id, 'compressor', c1.id, i.updated_at FROM installed_relief_valves i JOIN c1 ON c1.unit_id = i.unit_id
   WHERE i.archived_at IS NULL AND i.mapping_status = 'needs_equipment_mapping' AND i.expected_parent_kind = 'compressor'
  UNION ALL
  SELECT i.id, i.unit_id, 'storage_vessel', v1.id, i.updated_at FROM installed_relief_valves i JOIN v1 ON v1.unit_id = i.unit_id
   WHERE i.archived_at IS NULL AND i.mapping_status = 'needs_equipment_mapping' AND i.expected_parent_kind = 'storage_vessel'
  ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6m_preview()
RETURNS TABLE (preview_fingerprint text, total int, to_compressor int, to_storage_vessel int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6m_proposal())
  SELECT encode(sha256(convert_to('6M|' || coalesce((SELECT string_agg(concat_ws('|', srv_id, unit_id, parent_kind, parent_id, updated_at), E'\n'
           ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int,
         (SELECT count(*) FROM p WHERE parent_kind = 'compressor')::int,
         (SELECT count(*) FROM p WHERE parent_kind = 'storage_vessel')::int;
$$;

CREATE OR REPLACE FUNCTION cng_6m_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; n int; v_owner uuid; a int;
        v_note text := 'Equipment from owner ruling 6m: the only equipment of the Location kind in the Unit';
BEGIN
  SELECT pv.preview_fingerprint, pv.total INTO v_fp, e FROM cng_6m_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6m commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 THEN RAISE EXCEPTION '6m commit refused: nothing to link' USING ERRCODE = '22023'; END IF;
  SELECT count(*), min(id::text)::uuid INTO a, v_owner FROM app_users WHERE role = 'admin' AND is_active;
  IF a <> 1 THEN RAISE EXCEPTION '6m commit refused: % active admins, the ruling owner must be the only one', a USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6m ON COMMIT DROP AS SELECT * FROM cng_6m_proposal();

  UPDATE installed_relief_valves i
     SET compressor_id = CASE WHEN p.parent_kind = 'compressor' THEN p.parent_id END,
         storage_vessel_id = CASE WHEN p.parent_kind = 'storage_vessel' THEN p.parent_id END,
         mapping_status = 'resolved', resolved_by = v_owner, resolved_at = now(), mapping_note = v_note
    FROM _6m p WHERE i.id = p.srv_id AND i.mapping_status = 'needs_equipment_mapping' AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n <> e THEN RAISE EXCEPTION '6m commit refused: % linked, % expected', n, e USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, v_owner, 'service_role:single_equipment_srv_link_6m',
          format('Phase 6m: %s installed SRVs linked to the only equipment of their Location kind in their Unit (owner ruling). %s', n, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp,
                                   'records', (SELECT jsonb_agg(jsonb_build_array(srv_id, parent_kind, parent_id) ORDER BY srv_id) FROM _6m)),
          now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6m_proposal(), cng_6m_preview(), cng_6m_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6m_proposal(), cng_6m_preview(), cng_6m_commit(text, text) TO service_role;
