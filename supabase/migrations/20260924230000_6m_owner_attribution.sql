-- Phase 6m follow-up: the ruling owner is the FIRST active administrator (the owner account created on the empty
-- project), not "the only" one. Production also holds a later E2E test admin, which the 6m guard correctly refused to
-- attribute an owner ruling to. Only cng_6m_commit is replaced; grants are unchanged. No DML here.

CREATE OR REPLACE FUNCTION cng_6m_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; n int; v_owner uuid;
        v_note text := 'Equipment from owner ruling 6m: the only equipment of the Location kind in the Unit';
BEGIN
  SELECT pv.preview_fingerprint, pv.total INTO v_fp, e FROM cng_6m_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6m commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 THEN RAISE EXCEPTION '6m commit refused: nothing to link' USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_owner FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION '6m commit refused: no active admin to attribute the ruling to' USING ERRCODE = '22023'; END IF;
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
