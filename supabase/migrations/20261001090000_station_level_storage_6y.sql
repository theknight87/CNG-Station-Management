-- Owner ruling 6y (2026-10-01): STORAGE BELONGS TO THE STATION, NOT TO A UNIT.
--
-- The owner: "اي ريليفات storage سيبهم بأسم المحطة فقط لان الخزان احيانا بيبقى متوصل بكذا unit" — a storage
-- vessel bank is often piped to several Units at once, so naming one Unit as its owner states something false.
-- The owner chose the full change: storage vessels and their relief valves are recorded at STATION level
-- (unit_id NULL), count as complete (resolved), and are shown under the Station for every one of its Units.
--
-- What changes:
--   * storage_vessels: a resolved vessel may have no Unit (it is a Station-level vessel). needs_unit_mapping keeps
--     its old meaning and shape. (storage_vessels_resolved_ck is dropped.)
--   * installed_relief_valves: a storage relief valve may be resolved with no Unit — its Station proven, its parent
--     the Station's storage (a specific vessel when known, else the storage bank). Every other family keeps the old
--     rule: resolved = Unit + exactly one parent. A new composite key makes the vessel belong to the valve's Station,
--     because the old (vessel, unit) key is not checked when the Unit is NULL.
--   * Views: v_unit_srvs and the new v_unit_storage_vessels show each Station-level row under every live Unit of its
--     Station (a VIEW repeats it; the record itself is ONE row — CLAUDE.md §4 "never duplicate SRV records").
--     v_unit_summary counts them the same way. Station, Region and dashboard totals are unchanged (they count rows).
-- Nothing here guesses a Unit or an equipment parent; it removes the Unit from storage instead of inventing one.

-- 1. Storage vessels ---------------------------------------------------------------------------------------------
ALTER TABLE storage_vessels DROP CONSTRAINT storage_vessels_resolved_ck;
ALTER TABLE storage_vessels ADD CONSTRAINT storage_vessels_id_station_uq UNIQUE (id, station_id);

-- 2. Installed relief valves --------------------------------------------------------------------------------------
ALTER TABLE installed_relief_valves DROP CONSTRAINT irv_status_shape_ck;
ALTER TABLE installed_relief_valves ADD CONSTRAINT irv_status_shape_ck CHECK (
  CASE mapping_status
    WHEN 'needs_station_mapping' THEN
      station_id IS NULL AND unit_id IS NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'needs_unit_mapping' THEN
      station_id IS NOT NULL AND unit_id IS NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'needs_equipment_mapping' THEN
      station_id IS NOT NULL AND unit_id IS NOT NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'resolved' THEN
      station_id IS NOT NULL AND (
        -- Unit-level equipment: the Unit and exactly one parent.
        (unit_id IS NOT NULL AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 1)
        -- Station-level storage (ruling 6y): no Unit, never a compressor or dispenser, and storage either named
        -- as the parent or stated as the expected parent.
        OR (unit_id IS NULL AND compressor_id IS NULL AND dispenser_id IS NULL
            AND (storage_vessel_id IS NOT NULL OR expected_parent_kind = 'storage_vessel')))
    WHEN 'conflict' THEN
      num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) <= 1
  END
);
ALTER TABLE installed_relief_valves ADD CONSTRAINT irv_storage_vessel_station_fk
  FOREIGN KEY (storage_vessel_id, station_id) REFERENCES storage_vessels (id, station_id) ON DELETE RESTRICT;

-- 3. Unit SRV tab: Unit-confirmed rows as before, plus the Station's storage relief valves under every live Unit.
--    view_unit_id is the Unit being viewed; unit_id stays the record's own (NULL for Station-level storage).
CREATE OR REPLACE VIEW v_unit_srvs WITH (security_invoker = true) AS
SELECT
       m.id, m.region_id, m.region_name, m.station_id, m.station_name, m.source_station_name_raw,
       m.station_display, m.needs_station_mapping, m.unit_id, m.unit_name, m.mapping_status, m.needs_mapping,
       m.mapping_label, m.expected_parent_kind, m.location_raw, m.parent_kind, m.parent_id, m.parent_label,
       m.tag_number, m.serial_number, m.serial_number_raw, m.serial_status, m.part_number, m.manufacturer,
       m.size_type, m.inlet_size, m.outlet_size, m.set_pressure_raw, m.pressure_min, m.pressure_max,
       m.pressure_unit, m.last_calibration_date, m.last_calibration_precision, m.last_calibration_display,
       m.next_calibration_date, m.next_calibration_precision, m.next_calibration_display, m.days_left,
       m.due_status, m.source_status_raw, m.needs_review, m.notes, m.import_batch_id, m.source_file,
       m.source_sheet, m.source_row, m.created_at, m.updated_at,
       m.unit_id AS view_unit_id, false AS station_level
  FROM v_installed_srv_management m
 WHERE m.unit_id IS NOT NULL
   AND m.mapping_status IN ('resolved', 'needs_equipment_mapping')
UNION ALL
SELECT
       m.id, m.region_id, m.region_name, m.station_id, m.station_name, m.source_station_name_raw,
       m.station_display, m.needs_station_mapping, m.unit_id, m.unit_name, m.mapping_status, m.needs_mapping,
       m.mapping_label, m.expected_parent_kind, m.location_raw, m.parent_kind, m.parent_id, m.parent_label,
       m.tag_number, m.serial_number, m.serial_number_raw, m.serial_status, m.part_number, m.manufacturer,
       m.size_type, m.inlet_size, m.outlet_size, m.set_pressure_raw, m.pressure_min, m.pressure_max,
       m.pressure_unit, m.last_calibration_date, m.last_calibration_precision, m.last_calibration_display,
       m.next_calibration_date, m.next_calibration_precision, m.next_calibration_display, m.days_left,
       m.due_status, m.source_status_raw, m.needs_review, m.notes, m.import_batch_id, m.source_file,
       m.source_sheet, m.source_row, m.created_at, m.updated_at,
       u.id AS view_unit_id, true AS station_level
  FROM v_installed_srv_management m
  JOIN units u ON u.station_id = m.station_id AND u.archived_at IS NULL
 WHERE m.unit_id IS NULL
   AND m.mapping_status = 'resolved';

COMMENT ON VIEW v_unit_srvs IS
  'Unit SRV tab. Unit-confirmed relief valves (resolved / needs_equipment_mapping), plus Station-level storage relief '
  'valves (ruling 6y) repeated under every live Unit of their Station. Filter by view_unit_id. One record = one row in '
  'installed_relief_valves; only this view repeats it.';

-- 4. Unit Storage tab: the Unit's own storage vessels (legacy) plus the Station's storage vessels.
CREATE VIEW v_unit_storage_vessels WITH (security_invoker = true) AS
SELECT v.*, u.id AS view_unit_id, (v.unit_id IS NULL) AS station_level
  FROM v_vessel_management v
  JOIN units u ON u.archived_at IS NULL AND u.station_id = v.station_id
              AND (v.unit_id = u.id OR v.unit_id IS NULL)
 WHERE v.asset_type = 'storage_vessel';

COMMENT ON VIEW v_unit_storage_vessels IS
  'Unit Storage tab (ruling 6y): storage vessels of the Unit plus Station-level storage vessels, repeated under every '
  'live Unit of the Station. Filter by view_unit_id. Never used for totals.';
REVOKE ALL ON v_unit_storage_vessels FROM PUBLIC, anon;
GRANT SELECT ON v_unit_storage_vessels TO authenticated;

-- 5. Unit summary: Station-level storage (vessels and their relief valves) is counted under every Unit of the Station.
CREATE OR REPLACE VIEW v_unit_summary WITH (security_invoker = true) AS
SELECT u.id AS unit_id, u.unit_name, u.normalized_name, u.station_id, s.station_name, u.region_id,
       r.code AS region_code, r.name AS region_name, u.job_number, u.job_number_raw, u.dispenser_count_reported,
       u.hose_count_reported, u.storage_count_reported, u.notes, u.needs_review, u.archived_at,
       (SELECT count(*) FROM compressors c WHERE c.archived_at IS NULL AND c.unit_id = u.id) AS compressors,
       (SELECT count(*) FROM dispensers d WHERE d.archived_at IS NULL AND d.unit_id = u.id) AS dispensers,
       (SELECT count(*) FROM storage_vessels sv WHERE sv.archived_at IS NULL
           AND (sv.unit_id = u.id OR (sv.unit_id IS NULL AND sv.station_id = u.station_id))) AS storage_vessels,
       (SELECT count(*) FROM recovery_tanks rt WHERE rt.archived_at IS NULL AND rt.unit_id = u.id) AS recovery_tanks,
       (SELECT count(*) FROM gas_detectors g WHERE g.archived_at IS NULL AND g.unit_id = u.id) AS gas_detectors,
       (SELECT count(*) FROM hoses h WHERE h.archived_at IS NULL AND h.unit_id = u.id) AS hoses,
       (SELECT count(*) FROM installed_relief_valves v WHERE v.archived_at IS NULL
           AND (v.unit_id = u.id
                OR (v.unit_id IS NULL AND v.station_id = u.station_id AND v.mapping_status = 'resolved'))) AS installed_srvs,
       (SELECT count(*) FROM installed_relief_valves v WHERE v.archived_at IS NULL
           AND (v.unit_id = u.id
                OR (v.unit_id IS NULL AND v.station_id = u.station_id AND v.mapping_status = 'resolved'))
           AND cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue')
     + (SELECT count(*) FROM storage_vessels sv WHERE sv.archived_at IS NULL
           AND (sv.unit_id = u.id OR (sv.unit_id IS NULL AND sv.station_id = u.station_id))
           AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue')
     + (SELECT count(*) FROM recovery_tanks rt WHERE rt.archived_at IS NULL AND rt.unit_id = u.id
           AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue')
     + (SELECT count(*) FROM gas_detectors g WHERE g.archived_at IS NULL AND g.unit_id = u.id
           AND cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue')
     + (SELECT count(*) FROM hoses h WHERE h.archived_at IS NULL AND h.unit_id = u.id
           AND cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue') AS overdue
  FROM units u
  JOIN stations s ON s.id = u.station_id
  JOIN regions r ON r.id = u.region_id
 WHERE u.archived_at IS NULL;
