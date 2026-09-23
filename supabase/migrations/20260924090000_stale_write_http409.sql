-- Stale-write refusals in browser-facing admin functions used SQLSTATE 40001 (serialization_failure).
-- PostgREST RETRIES a transaction that fails with 40001, so through the API a stale write looped until the
-- gateway answered "upstream request timeout" instead of refusing. Same fix as 20260923231000 for
-- cng_admin_update_record: PT409 makes PostgREST answer HTTP 409 immediately.
--
-- Scope (every browser-callable function whose production body contains 40001):
--   * cng_check_precondition  - the shared row-version guard. Its callers inherit the fix unchanged:
--     cng_admin_set_user_role, cng_admin_set_user_active, cng_admin_remove_user, cng_admin_set_alert_rule_enabled,
--     cng_admin_map_srv, cng_admin_set_channel_policy, cng_admin_decide_staged_mapping.
--   * cng_admin_decide_staged_mapping - also raises 40001 directly when a decision already exists.
-- Bodies are the CURRENT PRODUCTION definitions (pg_get_functiondef; the production body of the second function is
-- the 0041 body without its three comment lines, verified by hash), changed ONLY in the ERRCODE. Grants,
-- volatility, SECURITY DEFINER and search_path are unchanged (CREATE OR REPLACE keeps grants).
-- The service_role-only Phase 6c/6d/6e commit functions keep 40001: they are called from SQL, never the API.

CREATE OR REPLACE FUNCTION public.cng_check_precondition(p_actual timestamp with time zone, p_expected timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
BEGIN
  IF p_expected IS NOT NULL AND p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'stale_write: this record changed since you loaded it'
      USING ERRCODE = 'PT409';
  END IF;
END $function$

;

CREATE OR REPLACE FUNCTION public.cng_admin_decide_staged_mapping(p_staging_row_id uuid, p_station_id uuid, p_unit_id uuid DEFAULT NULL::uuid, p_expected_decision_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_reason text DEFAULT NULL::text)
 RETURNS TABLE(decision_id uuid, resulting_mapping_status text, decided_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_actor    uuid := cng_require_admin();
  v_row      import_staging_rows%ROWTYPE;
  v_active   import_mapping_decisions%ROWTYPE;
  v_region   uuid;
  v_status   text;
  v_asset    asset_type;
  v_id       uuid;
  v_at       timestamptz;
BEGIN
  SELECT * INTO v_row FROM import_staging_rows WHERE id = p_staging_row_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'staging row not found' USING ERRCODE = '42704';
  END IF;

  v_asset := CASE v_row.target_table
    WHEN 'storage_vessels' THEN 'storage_vessel'::asset_type
    WHEN 'recovery_tanks'  THEN 'recovery_tank'
    WHEN 'gas_detectors'   THEN 'gas_detector'
    WHEN 'hoses'           THEN 'hose'
  END;
  IF v_asset IS NULL THEN
    RAISE EXCEPTION 'this staged row is not a pre-import mappable asset (%)', v_row.target_table
      USING ERRCODE = '22023';
  END IF;

  IF v_row.mapping_status IS NULL OR v_row.mapping_status = 'resolved' THEN
    RAISE EXCEPTION 'this staged row needs no mapping decision' USING ERRCODE = '22023';
  END IF;
  IF v_row.outcome IN ('rejected', 'excluded', 'replayed') THEN
    RAISE EXCEPTION 'a % staging row is not committable and takes no mapping decision', v_row.outcome
      USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_active FROM import_mapping_decisions
   WHERE source_row_key = v_row.source_row_key AND superseded_at IS NULL;

  PERFORM cng_check_precondition(v_active.decided_at, p_expected_decision_at);
  IF v_active.id IS NOT NULL AND p_expected_decision_at IS NULL THEN
    RAISE EXCEPTION 'stale_write: a decision already exists for this source row'
      USING ERRCODE = 'PT409';
  END IF;

  IF p_station_id IS NULL THEN
    RAISE EXCEPTION 'a Station must be confirmed' USING ERRCODE = '23514';
  END IF;
  SELECT region_id INTO v_region FROM stations WHERE id = p_station_id;
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'station not found' USING ERRCODE = '42704';
  END IF;

  v_status := CASE WHEN p_unit_id IS NULL THEN 'needs_unit_mapping' ELSE 'resolved' END;

  v_id := gen_random_uuid();
  IF v_active.id IS NOT NULL THEN
    UPDATE import_mapping_decisions
       SET superseded_at = now(), superseded_by = v_id
     WHERE id = v_active.id;
  END IF;

  INSERT INTO import_mapping_decisions (
    id, staging_row_id, source_row_key, reviewed_source_row_hash,
    target_table, asset_type,
    region_id, confirmed_station_id, confirmed_unit_id,
    previous_mapping_status, resulting_mapping_status,
    decided_by, reason, source_evidence)
  VALUES (
    v_id, p_staging_row_id, v_row.source_row_key,
    v_row.source_row_hash,
    v_row.target_table, v_asset,
    v_region, p_station_id, p_unit_id,
    v_row.mapping_status, v_status,
    v_actor, p_reason,
    jsonb_build_object(
      'source_file', v_row.source_file, 'source_sheet', v_row.source_sheet,
      'source_row', v_row.source_row, 'source_raw', v_row.source_raw,
      'source_row_hash', v_row.source_row_hash,
      'normalized', v_row.normalized, 'resolution', v_row.resolution,
      'staged_mapping_status', v_row.mapping_status))
  RETURNING import_mapping_decisions.decided_at INTO v_at;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('mapping_changed', 'import_mapping_decisions', v_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('%s %s: %s -> %s', v_row.target_table, v_row.source_row_key,
                 v_row.mapping_status, v_status),
          CASE WHEN v_active.id IS NULL THEN NULL
               ELSE jsonb_build_object(
                 'superseded_decision_id', v_active.id,
                 'station_id', v_active.confirmed_station_id,
                 'unit_id', v_active.confirmed_unit_id,
                 'reviewed_source_row_hash', v_active.reviewed_source_row_hash,
                 'mapping_status', v_active.resulting_mapping_status) END,
          jsonb_build_object(
            'staging_row_id', p_staging_row_id, 'source_row_key', v_row.source_row_key,
            'reviewed_source_row_hash', v_row.source_row_hash,
            'asset_type', v_asset, 'station_id', p_station_id, 'unit_id', p_unit_id,
            'mapping_status', v_status));

  RETURN QUERY SELECT v_id, v_status, v_at;
END $function$

;
