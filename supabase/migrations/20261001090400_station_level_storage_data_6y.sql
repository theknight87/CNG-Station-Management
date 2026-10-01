-- Owner ruling 6y (2026-10-01), part 5: move existing storage to Station level.
--
--   1. Every storage relief valve (its parent a storage vessel, or its expected parent storage) leaves its Unit and
--      becomes resolved at Station level. A valve already on a vessel KEEPS that vessel. An unlinked one is linked
--      to its Station's vessel only where the Station has exactly ONE live storage vessel (owner ruling 6m, applied at
--      the Station now that storage is Station-level); otherwise it stays on the Station's storage bank, vessel unknown.
--      Valves whose Station is not confirmed are not touched.
--   2. Every storage vessel leaves its Unit and becomes resolved at Station level.
-- Attribution for newly resolved rows: the first active administrator (the owner account), as for rulings 6m-6x.
-- The move is a function (service_role only) so the regression suite can exercise it; it is invoked once below. It is
-- idempotent: a second run finds nothing to move. On a database with no storage rows (a fresh build) it changes nothing.

CREATE FUNCTION cng_6y_move_storage()
RETURNS TABLE (srvs int, vessels int, linked int)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_owner uuid;
  n_srv int; n_linked int; n_sv int;
  v_note text := 'Owner ruling 6y: storage belongs to the Station';
BEGIN
  SELECT id INTO v_owner FROM app_users WHERE role = 'admin' AND is_active ORDER BY created_at, id LIMIT 1;

  WITH one_vessel AS (
    SELECT sv.station_id, (array_agg(sv.id))[1] AS vessel_id
      FROM storage_vessels sv WHERE sv.archived_at IS NULL
     GROUP BY sv.station_id HAVING count(*) = 1
  ), moved AS (
    UPDATE installed_relief_valves i
       SET unit_id = NULL,
           storage_vessel_id = CASE WHEN i.storage_vessel_id IS NOT NULL OR i.archived_at IS NOT NULL
                                    THEN i.storage_vessel_id ELSE o.vessel_id END,
           mapping_status = 'resolved',
           resolved_by = coalesce(i.resolved_by, v_owner),
           resolved_at = coalesce(i.resolved_at, now()),
           mapping_note = CASE WHEN i.storage_vessel_id IS NULL AND i.archived_at IS NULL AND o.vessel_id IS NOT NULL
                               THEN v_note || ' (the Station''s only storage vessel, ruling 6m)'
                               WHEN i.mapping_status <> 'resolved' THEN v_note
                               ELSE i.mapping_note END
      FROM installed_relief_valves b
      LEFT JOIN one_vessel o ON o.station_id = b.station_id
     WHERE b.id = i.id
       AND i.station_id IS NOT NULL
       AND i.compressor_id IS NULL AND i.dispenser_id IS NULL
       AND (i.storage_vessel_id IS NOT NULL OR i.expected_parent_kind = 'storage_vessel')
       AND i.mapping_status IN ('resolved', 'needs_unit_mapping', 'needs_equipment_mapping')
       AND (i.unit_id IS NOT NULL OR i.mapping_status <> 'resolved')
    RETURNING i.id, (b.storage_vessel_id IS NULL AND i.storage_vessel_id IS NOT NULL) AS newly_linked
  )
  SELECT count(*), count(*) FILTER (WHERE newly_linked) INTO n_srv, n_linked FROM moved;

  UPDATE storage_vessels
     SET unit_id = NULL, mapping_status = 'resolved',
         resolved_by = coalesce(resolved_by, v_owner), resolved_at = coalesce(resolved_at, now())
   WHERE unit_id IS NOT NULL OR mapping_status <> 'resolved';
  GET DIAGNOSTICS n_sv = ROW_COUNT;

  IF n_srv + n_sv > 0 THEN
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
    VALUES ('mapping_changed', 'storage_vessels', NULL, v_owner, 'migration:station_level_storage_6y',
            format('Ruling 6y: %s storage relief valves and %s storage vessels moved to Station level; %s valves linked to their Station''s only vessel.',
                   n_srv, n_sv, n_linked),
            NULL, jsonb_build_object('srvs', n_srv, 'vessels', n_sv, 'linked', n_linked), now());
  END IF;
  RETURN QUERY SELECT n_srv, n_sv, n_linked;
END $$;

REVOKE ALL ON FUNCTION cng_6y_move_storage() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6y_move_storage() TO service_role;

SELECT * FROM cng_6y_move_storage();
