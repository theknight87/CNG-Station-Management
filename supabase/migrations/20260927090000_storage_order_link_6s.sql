-- Phase 6s: Storage SRVs in Units with several vessels, parented in order.
--
-- Owner ruling 2026-09-27 (explicit, CLAUDE.md §4 requires it): in a Unit with several storage vessels, the Storage SRVs
-- awaiting equipment are parented in order — SRVs sorted by serial, vessels sorted by serial, the n-th SRV on the n-th
-- vessel (wrapping when there are more SRVs than vessels). The owner knows the pairing is positional and will review
-- it on site; at the owner's request NO note is written on the records (the single audit row records the batch).
-- resolved_by = the first active admin (the owner, as in 6m). service_role only, content-bound, prefix 6S. No DML here.

CREATE OR REPLACE FUNCTION cng_6s_proposal()
RETURNS TABLE (srv_id uuid, unit_id uuid, vessel_id uuid, updated_at timestamptz)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH s AS (
    SELECT i.id, i.unit_id, i.updated_at,
           row_number() OVER (PARTITION BY i.unit_id ORDER BY i.serial_number NULLS LAST, i.id) - 1 AS k
      FROM installed_relief_valves i
     WHERE i.archived_at IS NULL AND i.mapping_status = 'needs_equipment_mapping' AND i.expected_parent_kind = 'storage_vessel'
  ), v AS (
    SELECT v.id, v.unit_id, row_number() OVER (PARTITION BY v.unit_id ORDER BY v.serial_number NULLS LAST, v.id) - 1 AS k,
           count(*) OVER (PARTITION BY v.unit_id) AS n
      FROM storage_vessels v WHERE v.archived_at IS NULL AND v.unit_id IS NOT NULL
  )
  SELECT s.id, s.unit_id, v.id, s.updated_at
    FROM s JOIN v ON v.unit_id = s.unit_id AND v.n > 1 AND v.k = s.k % v.n
   ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION cng_6s_preview()
RETURNS TABLE (preview_fingerprint text, total int, units int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6s_proposal())
  SELECT encode(sha256(convert_to('6S|' || coalesce((SELECT string_agg(concat_ws('|', srv_id, vessel_id, updated_at), E'\n' ORDER BY srv_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p)::int, (SELECT count(DISTINCT unit_id) FROM p)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6s_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (linked int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; n int; v_owner uuid;
BEGIN
  SELECT pv.preview_fingerprint, pv.total INTO v_fp, e FROM cng_6s_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6s commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 THEN RAISE EXCEPTION '6s commit refused: nothing to link' USING ERRCODE = '22023'; END IF;
  SELECT id INTO v_owner FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;
  IF v_owner IS NULL THEN RAISE EXCEPTION '6s commit refused: no active admin to attribute the ruling to' USING ERRCODE = '22023'; END IF;
  CREATE TEMP TABLE _6s ON COMMIT DROP AS SELECT * FROM cng_6s_proposal();

  UPDATE installed_relief_valves i
     SET storage_vessel_id = p.vessel_id, mapping_status = 'resolved', resolved_by = v_owner, resolved_at = now()
    FROM _6s p WHERE i.id = p.srv_id AND i.mapping_status = 'needs_equipment_mapping' AND i.updated_at = p.updated_at;
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n <> e THEN RAISE EXCEPTION '6s commit refused: % linked, % expected', n, e USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('mapping_changed', 'installed_relief_valves', NULL, v_owner, 'service_role:storage_order_link_6s',
          format('Phase 6s: %s Storage SRVs parented to vessels in serial order (owner ruling; positional, owner to review on site). %s',
                 n, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp,
                                   'records', (SELECT jsonb_agg(jsonb_build_array(srv_id, vessel_id) ORDER BY srv_id) FROM _6s)), now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6s_proposal(), cng_6s_preview(), cng_6s_commit(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6s_proposal(), cng_6s_preview(), cng_6s_commit(text, text) TO service_role;
