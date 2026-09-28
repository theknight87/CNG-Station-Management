-- Owner request 2026-09-28: an administrator can remove a Station (e.g. a test Station added by mistake).
-- "Remove" ARCHIVES (CLAUDE.md §10, no hard deletes): the Station and its Units get archived_at/archived_by and leave
-- every list and count (the summary views filter archived rows since 20260928190000); the rows stay for the audit.
-- A Station that still holds live equipment is refused: archiving it would leave assets pointing at a Station no screen
-- shows. Admin only, actor derived server-side, audited — the pattern of 20260928110000.

CREATE OR REPLACE FUNCTION cng_admin_archive_station(p_station_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_before jsonb;
  v_assets bigint;
  v_units int;
BEGIN
  SELECT to_jsonb(s) INTO v_before FROM stations s WHERE s.id = p_station_id AND s.archived_at IS NULL FOR UPDATE;
  IF v_before IS NULL THEN RAISE EXCEPTION 'this Station no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT (SELECT count(*) FROM installed_relief_valves WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM storage_vessels WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM recovery_tanks WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM gas_detectors WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM hoses WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM compressors WHERE station_id = p_station_id AND archived_at IS NULL)
       + (SELECT count(*) FROM dispensers WHERE station_id = p_station_id AND archived_at IS NULL)
    INTO v_assets;
  IF v_assets > 0 THEN
    RAISE EXCEPTION 'this Station still has % piece(s) of equipment; remove or move them first', v_assets USING ERRCODE = '23503';
  END IF;
  UPDATE units SET archived_at = now(), archived_by = v_actor WHERE station_id = p_station_id AND archived_at IS NULL;
  GET DIAGNOSTICS v_units = ROW_COUNT;
  UPDATE stations SET archived_at = now(), archived_by = v_actor WHERE id = p_station_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', 'stations', p_station_id, v_actor, 'admin_archive_station',
          format('Station %s removed (archived) with %s Unit(s). %s', v_before->>'station_name', v_units, coalesce(p_reason, '')),
          v_before, NULL, now());
END; $$;

COMMENT ON FUNCTION cng_admin_archive_station(uuid, text) IS
  'Admin only: archive a Station and its Units when it holds no live equipment (owner request 2026-09-28). Audited.';
REVOKE ALL ON FUNCTION cng_admin_archive_station(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_archive_station(uuid, text) TO authenticated;
