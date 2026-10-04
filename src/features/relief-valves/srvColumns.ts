/**
 * The columns the Installed and Warehouse SRV lists ask the database for. Dependency-free on purpose: the gate's
 * contract check (scripts/verify-report-contract.mjs) loads this file under Node and compares every name with the view
 * it is read from — the check that would have caught v_srv_warehouse_stock lacking target_unit_id (owner report 2026-10-04).
 */
export const INSTALLED_COLUMNS =
  'id, region_id, region_name, station_id, station_name, source_station_name_raw, station_display, ' +
  'needs_station_mapping, unit_id, unit_name, mapping_status, needs_mapping, mapping_label, ' +
  'expected_parent_kind, location_raw, parent_kind, parent_id, parent_label, tag_number, serial_number, ' +
  'serial_number_raw, serial_status, part_number, manufacturer, size_type, inlet_size, outlet_size, ' +
  'set_pressure_raw, pressure_min, pressure_max, pressure_unit, last_calibration_date, ' +
  'last_calibration_precision, last_calibration_display, next_calibration_date, ' +
  'next_calibration_precision, next_calibration_display, days_left, due_status, source_status_raw, ' +
  'needs_review, notes, source_file, source_sheet, source_row, warehouse_code, warehouse_code_source'

export const WAREHOUSE_COLUMNS =
  'id, availability_status, warehouse_code, serial_number, serial_number_raw, serial_status, part_number, ' +
  'manufacturer, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, ' +
  'pressure_unit, target_region_id, target_region_name, target_station_id, target_station_name, ' +
  'is_unassigned_stock, updated_at, warehouse_issue_date, last_calibration_date, last_calibration_precision, ' +
  'last_calibration_display, next_calibration_date, next_calibration_precision, ' +
  'next_calibration_display, days_left, due_status, calibration_location, source_status_raw, ' +
  'needs_review, notes, target_station_raw, target_unit_id, target_unit_name'

/** Each list and the view it reads. */
export const SRV_LIST_SOURCES = [
  { name: 'Installed SRVs', view: 'v_installed_srv_management', columns: INSTALLED_COLUMNS },
  { name: 'Warehouse SRVs', view: 'v_srv_warehouse_stock', columns: WAREHOUSE_COLUMNS },
] as const
