-- Owner ruling 6y (2026-10-01), part 3: SRV mapping knows that storage belongs to the Station.
-- Choosing parent kind 'storage_vessel' resolves the valve at Station level: the vessel is optional, the Unit is the
-- vessel's own (NULL for a Station-level vessel) and never the caller's, and the status is still DERIVED. Every other
-- kind keeps the 0038 behaviour unchanged. The body is the deployed 0038 definition with only those lines changed.

CREATE OR REPLACE FUNCTION cng_admin_map_srv(
  p_srv_id      uuid,
  p_station_id  uuid,
  p_unit_id     uuid DEFAULT NULL,
  p_parent_kind srv_parent_kind DEFAULT NULL,
  p_parent_id   uuid DEFAULT NULL,
  p_expected_updated_at timestamptz DEFAULT NULL,
  p_reason      text DEFAULT NULL
)
RETURNS TABLE (mapping_status srv_mapping_status, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor  uuid := cng_require_admin();
  v_before installed_relief_valves%ROWTYPE;
  v_after  installed_relief_valves%ROWTYPE;
  v_status srv_mapping_status;
  v_region uuid;
  v_unit   uuid := p_unit_id;
  v_storage boolean := coalesce(p_parent_kind = 'storage_vessel', false);
BEGIN
  SELECT * INTO v_before FROM installed_relief_valves WHERE id = p_srv_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'relief valve not found' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  IF p_station_id IS NULL THEN
    RAISE EXCEPTION 'a Station must be confirmed before any deeper mapping'
      USING ERRCODE = '23514';
  END IF;
  -- The Region follows the Station. It is never taken from the caller, and never
  -- from the unconfirmed raw source value on the row.
  SELECT region_id INTO v_region FROM stations WHERE id = p_station_id;
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'station not found' USING ERRCODE = '42704';
  END IF;

  -- Ruling 6y: storage belongs to the Station. Confirming "storage" is enough — the vessel is optional, and the
  -- Unit is the vessel's own (NULL for a Station-level vessel), never the caller's.
  IF v_storage THEN
    v_unit := (SELECT sv.unit_id FROM storage_vessels sv WHERE sv.id = p_parent_id);
  ELSIF (p_parent_kind IS NULL) <> (p_parent_id IS NULL) THEN
    RAISE EXCEPTION 'an equipment parent needs both a kind and an id'
      USING ERRCODE = '23514';
  END IF;
  IF p_parent_id IS NOT NULL AND v_unit IS NULL AND NOT v_storage THEN
    RAISE EXCEPTION 'equipment cannot be confirmed before its Unit'
      USING ERRCODE = '23514';
  END IF;

  -- The status is DERIVED from what was proven, never supplied by the caller.
  v_status := CASE
    WHEN v_storage             THEN 'resolved'
    WHEN v_unit IS NULL        THEN 'needs_unit_mapping'
    WHEN p_parent_id IS NULL   THEN 'needs_equipment_mapping'
    ELSE 'resolved'
  END;

  UPDATE installed_relief_valves SET
    station_id        = p_station_id,
    region_id         = v_region,
    unit_id           = v_unit,
    compressor_id     = CASE WHEN p_parent_kind = 'compressor'     THEN p_parent_id END,
    storage_vessel_id = CASE WHEN p_parent_kind = 'storage_vessel' THEN p_parent_id END,
    dispenser_id      = CASE WHEN p_parent_kind = 'dispenser'      THEN p_parent_id END,
    expected_parent_kind = CASE WHEN v_storage THEN 'storage_vessel' ELSE expected_parent_kind END,
    mapping_status    = v_status,
    -- irv_resolved_attribution_ck: a resolved row must say WHO resolved it and
    -- WHEN. The actor is the server-derived admin, never a caller parameter, and
    -- the attribution is cleared again if a later correction un-resolves the row.
    resolved_by       = CASE WHEN v_status = 'resolved' THEN v_actor END,
    resolved_at       = CASE WHEN v_status = 'resolved' THEN now() END,
    updated_at        = now()
  WHERE id = p_srv_id
  RETURNING * INTO v_after;

  -- Source evidence is never touched: source_station_name_raw, source_raw and
  -- the file/sheet/row provenance columns are not in the UPDATE above.
  INSERT INTO asset_mapping_audit (
    asset_type, asset_id,
    previous_station_id, new_station_id, previous_unit_id, new_unit_id,
    previous_parent_type, previous_parent_id, new_parent_type, new_parent_id,
    previous_mapping_status, new_mapping_status, changed_by, reason)
  VALUES (
    'installed_relief_valve', p_srv_id,
    v_before.station_id, v_after.station_id, v_before.unit_id, v_after.unit_id,
    CASE WHEN v_before.compressor_id IS NOT NULL THEN 'compressor'::srv_parent_kind
         WHEN v_before.storage_vessel_id IS NOT NULL THEN 'storage_vessel'
         WHEN v_before.dispenser_id IS NOT NULL THEN 'dispenser' END,
    coalesce(v_before.compressor_id, v_before.storage_vessel_id, v_before.dispenser_id),
    CASE WHEN p_parent_id IS NOT NULL THEN p_parent_kind END, p_parent_id,
    v_before.mapping_status::text, v_after.mapping_status::text, v_actor, p_reason);

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('mapping_changed', 'installed_relief_valves', p_srv_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('%s -> %s', v_before.mapping_status, v_after.mapping_status),
          jsonb_build_object('mapping_status', v_before.mapping_status,
                             'station_id', v_before.station_id,
                             'unit_id', v_before.unit_id),
          jsonb_build_object('mapping_status', v_after.mapping_status,
                             'station_id', v_after.station_id,
                             'unit_id', v_after.unit_id));

  RETURN QUERY SELECT v_after.mapping_status, v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) IS
  'Admin-only manual SRV mapping. The resulting mapping_status is DERIVED from what was proven, never supplied. Hierarchy validity is enforced by the pre-existing composite foreign keys and irv_status_shape_ck, not re-implemented here. Source evidence columns are never written. Audited atomically in both asset_mapping_audit and audit_logs.';

REVOKE ALL ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) TO authenticated;
