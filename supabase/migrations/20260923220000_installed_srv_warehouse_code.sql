-- Warehouse code for installed SRVs (owner request 2026-09-23: "add warehouse code for all srv and it must be shown
-- in the table").
--
-- Warehouse stock already carries `warehouse_code` from the source (2,188 of 2,188). Installed valves have no code in
-- any source file, so:
--   * `installed_relief_valves.warehouse_code` is a NEW, NULLABLE column for a code recorded by an administrator.
--     Nothing is back-filled into it.
--   * the view shows `warehouse_code_by_serial`: the code of the warehouse record with the SAME serial, only when
--     exactly ONE warehouse record carries that serial (a repeated serial is not evidence, principle 16).
--   * `warehouse_code` = the recorded code, else the serial match; `warehouse_code_source` says which
--     ('recorded' | 'serial_match' | NULL), so the screen can label a looked-up code as a lookup.
-- The view is replaced by APPENDING columns only (its four dependents keep working) and `security_invoker` is
-- restated because CREATE OR REPLACE VIEW does not preserve reloptions (the Prompt 19B defect). The warehouse lookup
-- runs under the caller's RLS like the rest of the view.

ALTER TABLE installed_relief_valves ADD COLUMN IF NOT EXISTS warehouse_code text NULL;
COMMENT ON COLUMN installed_relief_valves.warehouse_code IS
  'Warehouse code recorded by an administrator. NULL = not recorded. Never back-filled from a serial match.';
CREATE INDEX IF NOT EXISTS irv_serial_idx ON installed_relief_valves (serial_number) WHERE serial_number IS NOT NULL;

CREATE OR REPLACE VIEW v_installed_srv_management WITH (security_invoker = true) AS
SELECT v.id,
    r.id AS region_id,
    r.name AS region_name,
    v.station_id,
    s.station_name,
    v.source_station_name_raw,
    COALESCE(s.station_name, v.source_station_name_raw) AS station_display,
    v.station_id IS NULL AS needs_station_mapping,
    u.id AS unit_id,
    u.unit_name,
    v.mapping_status,
    v.mapping_status <> 'resolved'::srv_mapping_status AS needs_mapping,
        CASE v.mapping_status
            WHEN 'needs_station_mapping'::srv_mapping_status THEN 'Needs Station Mapping'::text
            WHEN 'needs_unit_mapping'::srv_mapping_status THEN 'Needs Unit Mapping'::text
            WHEN 'needs_equipment_mapping'::srv_mapping_status THEN 'Needs Equipment Mapping'::text
            WHEN 'conflict'::srv_mapping_status THEN 'Mapping Conflict'::text
            WHEN 'resolved'::srv_mapping_status THEN 'Resolved'::text
            ELSE NULL::text
        END AS mapping_label,
    v.expected_parent_kind,
    v.location_raw,
        CASE
            WHEN v.compressor_id IS NOT NULL THEN 'compressor'::srv_parent_kind
            WHEN v.storage_vessel_id IS NOT NULL THEN 'storage_vessel'::srv_parent_kind
            WHEN v.dispenser_id IS NOT NULL THEN 'dispenser'::srv_parent_kind
            ELSE NULL::srv_parent_kind
        END AS parent_kind,
    COALESCE(v.compressor_id, v.storage_vessel_id, v.dispenser_id) AS parent_id,
    COALESCE(c.model, sv.model, d.model) AS parent_label,
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
    cng_days_left(v.next_calibration_date, v.next_calibration_precision) AS days_left,
    cng_due_status(v.next_calibration_date, v.next_calibration_precision) AS due_status,
    v.source_status_raw,
    v.needs_review,
    v.notes,
    v.import_batch_id,
    v.source_file,
    v.source_sheet,
    v.source_row,
    v.created_at,
    v.updated_at,
    v.warehouse_code AS warehouse_code_recorded,
    wm.warehouse_code AS warehouse_code_by_serial,
    COALESCE(v.warehouse_code, wm.warehouse_code) AS warehouse_code,
        CASE
            WHEN v.warehouse_code IS NOT NULL THEN 'recorded'::text
            WHEN wm.warehouse_code IS NOT NULL THEN 'serial_match'::text
            ELSE NULL::text
        END AS warehouse_code_source
   FROM installed_relief_valves v
     JOIN regions r ON r.id = v.region_id
     LEFT JOIN stations s ON s.id = v.station_id
     LEFT JOIN units u ON u.id = v.unit_id
     LEFT JOIN compressors c ON c.id = v.compressor_id
     LEFT JOIN storage_vessels sv ON sv.id = v.storage_vessel_id
     LEFT JOIN dispensers d ON d.id = v.dispenser_id
     LEFT JOIN LATERAL ( SELECT min(w.warehouse_code) AS warehouse_code
           FROM warehouse_relief_valves w
          WHERE w.serial_number = v.serial_number AND w.archived_at IS NULL
         HAVING count(*) = 1) wm ON v.serial_number IS NOT NULL
  WHERE v.archived_at IS NULL;

COMMENT ON COLUMN v_installed_srv_management.warehouse_code_by_serial IS
  'Code of the single warehouse record with the same serial; NULL when none or several share it. A lookup, not a record.';
