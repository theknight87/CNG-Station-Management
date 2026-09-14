-- 0016_views_station_mapping.sql
-- Rebuild the SRV views for the five-state lifecycle.
--
-- The station join becomes a LEFT JOIN: an SRV awaiting station confirmation is
-- still an SRV and must appear in Global SRV Management. It shows the raw source
-- station name and a clear "Needs Station Mapping" label — the name the source
-- gave, never a fabricated Station.

DROP VIEW IF EXISTS v_unit_srvs;
DROP VIEW IF EXISTS v_installed_srv_management;

CREATE VIEW v_installed_srv_management
WITH (security_invoker = true) AS
SELECT
  v.id,
  r.id   AS region_id,
  r.name AS region_name,
  v.station_id,
  s.station_name,                       -- NULL while the station is unconfirmed
  v.source_station_name_raw,
  -- What to show as the location. Never invents a Station: falls back to the raw
  -- source spelling, marked as unconfirmed.
  coalesce(s.station_name, v.source_station_name_raw) AS station_display,
  (v.station_id IS NULL)                AS needs_station_mapping,
  u.id   AS unit_id,
  u.unit_name,
  v.mapping_status,
  (v.mapping_status <> 'resolved')      AS needs_mapping,
  -- Single human-readable label for list views and alert bodies.
  CASE v.mapping_status
    WHEN 'needs_station_mapping'   THEN 'Needs Station Mapping'
    WHEN 'needs_unit_mapping'      THEN 'Needs Unit Mapping'
    WHEN 'needs_equipment_mapping' THEN 'Needs Equipment Mapping'
    WHEN 'conflict'                THEN 'Mapping Conflict'
    WHEN 'resolved'                THEN 'Resolved'
  END                                   AS mapping_label,
  v.expected_parent_kind,
  v.location_raw,
  CASE
    WHEN v.compressor_id     IS NOT NULL THEN 'compressor'::srv_parent_kind
    WHEN v.storage_vessel_id IS NOT NULL THEN 'storage_vessel'::srv_parent_kind
    WHEN v.dispenser_id      IS NOT NULL THEN 'dispenser'::srv_parent_kind
  END                                   AS parent_kind,
  coalesce(v.compressor_id, v.storage_vessel_id, v.dispenser_id) AS parent_id,
  coalesce(c.model, sv.model, d.model)  AS parent_label,
  v.tag_number,
  v.serial_number,
  v.serial_number_raw,
  v.serial_status,
  v.part_number,
  v.manufacturer,
  v.size_type,
  v.inlet_size,
  v.outlet_size,
  v.set_pressure_raw,
  v.pressure_min,
  v.pressure_max,
  v.pressure_unit,
  v.last_calibration_date,
  v.last_calibration_precision,
  cng_date_display(v.last_calibration_date, v.last_calibration_precision, v.last_calibration_raw) AS last_calibration_display,
  v.next_calibration_date,
  v.next_calibration_precision,
  cng_date_display(v.next_calibration_date, v.next_calibration_precision, v.next_calibration_raw) AS next_calibration_display,
  -- Due tracking is INDEPENDENT of mapping: an exact date is sufficient.
  cng_days_left(v.next_calibration_date, v.next_calibration_precision)  AS days_left,
  cng_due_status(v.next_calibration_date, v.next_calibration_precision) AS due_status,
  v.source_status_raw,
  v.needs_review,
  v.notes,
  v.import_batch_id,
  v.source_file,
  v.source_sheet,
  v.source_row,
  v.created_at,
  v.updated_at
FROM installed_relief_valves v
JOIN regions r        ON r.id = v.region_id
LEFT JOIN stations s  ON s.id = v.station_id     -- LEFT: station may be unconfirmed
LEFT JOIN units u            ON u.id  = v.unit_id
LEFT JOIN compressors c      ON c.id  = v.compressor_id
LEFT JOIN storage_vessels sv ON sv.id = v.storage_vessel_id
LEFT JOIN dispensers d       ON d.id  = v.dispenser_id
WHERE v.archived_at IS NULL;

COMMENT ON VIEW v_installed_srv_management IS
  'Every installed SRV, at any lifecycle stage including needs_station_mapping. station_display falls back to the raw source name — no Station is ever fabricated. Due status is computed regardless of mapping state.';

-- The Unit SRV tab. unit_id IS NOT NULL already excludes needs_station_mapping
-- and needs_unit_mapping; the status filter additionally excludes conflict.
CREATE VIEW v_unit_srvs
WITH (security_invoker = true) AS
SELECT *
FROM v_installed_srv_management
WHERE unit_id IS NOT NULL
  AND mapping_status IN ('resolved', 'needs_equipment_mapping');

COMMENT ON VIEW v_unit_srvs IS
  'SRVs shown inside a Unit tab: resolved plus needs_equipment_mapping only. needs_station_mapping, needs_unit_mapping and conflict are never shown inside a Unit.';

-- ---------------------------------------------------------------------------
-- Mapping queue view: what a human has to work, in lifecycle order.
-- ---------------------------------------------------------------------------

CREATE VIEW v_srv_mapping_queue
WITH (security_invoker = true) AS
SELECT
  m.id,
  m.region_id,
  m.region_name,
  m.station_id,
  m.station_display,
  m.source_station_name_raw,
  m.mapping_status,
  m.mapping_label,
  m.expected_parent_kind,
  m.location_raw,
  m.serial_number,
  m.serial_number_raw,
  m.part_number,
  m.manufacturer,
  m.set_pressure_raw,
  m.next_calibration_date,
  m.days_left,
  m.due_status,
  -- Ordering: station-level work first, since nothing below it can proceed.
  CASE m.mapping_status
    WHEN 'needs_station_mapping'   THEN 1
    WHEN 'needs_unit_mapping'      THEN 2
    WHEN 'needs_equipment_mapping' THEN 3
    WHEN 'conflict'                THEN 4
    ELSE 5
  END AS queue_order
FROM v_installed_srv_management m
WHERE m.mapping_status <> 'resolved';

COMMENT ON VIEW v_srv_mapping_queue IS
  'Admin -> Data Quality work list for SRVs, ordered by lifecycle stage: station, then unit, then equipment, then conflicts.';
