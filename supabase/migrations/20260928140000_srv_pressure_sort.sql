-- Owner request 2026-09-28: every SRV table column sortable; warehouse default = set pressure ascending;
-- installed default = Region, Station, then set pressure ascending.
-- Pressures are stored in BAR or PSI, so ordering by the raw number would put 400 PSI after 90 BAR. This appends ONE
-- derived column, pressure_sort_bar (PSI x 0.0689476, BAR as is, anything else NULL), used ONLY for ordering; the
-- displayed pressure and its unit are unchanged. The existing column list is restated verbatim (pg_get_viewdef of the
-- deployed views, md5 198d974f.../1d0e3001... identical locally and in production); the new column is appended last so
-- dependent views keep working. security_invoker is restated because CREATE OR REPLACE VIEW does not keep reloptions.

CREATE OR REPLACE VIEW v_installed_srv_management WITH (security_invoker = true) AS
 SELECT v.id,
    r.id AS region_id,
    r.name AS region_name,
    v.station_id,
    s.station_name,
    v.source_station_name_raw,
    COALESCE(s.station_name, v.source_station_name_raw) AS station_display,
    (v.station_id IS NULL) AS needs_station_mapping,
    u.id AS unit_id,
    u.unit_name,
    v.mapping_status,
    (v.mapping_status <> 'resolved'::srv_mapping_status) AS needs_mapping,
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
            WHEN (v.compressor_id IS NOT NULL) THEN 'compressor'::srv_parent_kind
            WHEN (v.storage_vessel_id IS NOT NULL) THEN 'storage_vessel'::srv_parent_kind
            WHEN (v.dispenser_id IS NOT NULL) THEN 'dispenser'::srv_parent_kind
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
            WHEN (v.warehouse_code IS NOT NULL) THEN 'recorded'::text
            WHEN (wm.warehouse_code IS NOT NULL) THEN 'serial_match'::text
            ELSE NULL::text
        END AS warehouse_code_source,
        CASE v.pressure_unit::text
            WHEN 'BAR'::text THEN v.pressure_max
            WHEN 'PSI'::text THEN round(v.pressure_max * 0.0689476, 3)
            ELSE NULL::numeric
        END AS pressure_sort_bar
   FROM (((((((installed_relief_valves v
     JOIN regions r ON ((r.id = v.region_id)))
     LEFT JOIN stations s ON ((s.id = v.station_id)))
     LEFT JOIN units u ON ((u.id = v.unit_id)))
     LEFT JOIN compressors c ON ((c.id = v.compressor_id)))
     LEFT JOIN storage_vessels sv ON ((sv.id = v.storage_vessel_id)))
     LEFT JOIN dispensers d ON ((d.id = v.dispenser_id)))
     LEFT JOIN LATERAL ( SELECT min(w.warehouse_code) AS warehouse_code
           FROM warehouse_relief_valves w
          WHERE ((w.serial_number = v.serial_number) AND (w.archived_at IS NULL))
         HAVING (count(*) = 1)) wm ON ((v.serial_number IS NOT NULL)))
  WHERE (v.archived_at IS NULL);

CREATE OR REPLACE VIEW v_warehouse_srv_management WITH (security_invoker = true) AS
 SELECT w.id,
    w.availability_status,
    w.warehouse_code,
    w.serial_number,
    w.serial_number_raw,
    w.serial_status,
    w.part_number,
    w.manufacturer,
    w.size_type,
    w.inlet_size,
    w.outlet_size,
    w.set_pressure_raw,
    w.pressure_min,
    w.pressure_max,
    w.pressure_unit,
    r.id AS target_region_id,
    r.name AS target_region_name,
    s.id AS target_station_id,
    s.station_name AS target_station_name,
    (w.target_station_id IS NULL) AS is_unassigned_stock,
    w.warehouse_issue_date,
    w.last_calibration_date,
    w.last_calibration_precision,
    cng_date_display(w.last_calibration_date, w.last_calibration_precision, w.last_calibration_raw) AS last_calibration_display,
    w.next_calibration_date,
    w.next_calibration_precision,
    cng_date_display(w.next_calibration_date, w.next_calibration_precision, w.next_calibration_raw) AS next_calibration_display,
    cng_days_left(w.next_calibration_date, w.next_calibration_precision) AS days_left,
    cng_due_status(w.next_calibration_date, w.next_calibration_precision) AS due_status,
    w.calibration_location,
    w.source_status_raw,
    w.needs_review,
    w.notes,
    w.created_at,
    w.updated_at,
        CASE w.pressure_unit::text
            WHEN 'BAR'::text THEN w.pressure_max
            WHEN 'PSI'::text THEN round(w.pressure_max * 0.0689476, 3)
            ELSE NULL::numeric
        END AS pressure_sort_bar
   FROM ((warehouse_relief_valves w
     LEFT JOIN regions r ON ((r.id = w.target_region_id)))
     LEFT JOIN stations s ON ((s.id = w.target_station_id)))
  WHERE (w.archived_at IS NULL);

COMMENT ON COLUMN v_installed_srv_management.pressure_sort_bar IS 'Ordering key only: set pressure (max) in BAR; PSI converted. Never displayed.';
COMMENT ON COLUMN v_warehouse_srv_management.pressure_sort_bar IS 'Ordering key only: set pressure (max) in BAR; PSI converted. Never displayed.';
