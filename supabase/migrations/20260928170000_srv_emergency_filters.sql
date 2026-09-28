-- Owner request 2026-09-28: the same filters on SRV Emergency (serial, size, manufacturer, pressure range).
-- The view carried the issued valve's pressure only, so this appends the issued valve's serial_number, manufacturer
-- and size columns (the names the shared filter uses). Deployed definition restated verbatim (md5 1ddc0d46...,
-- identical locally and in production); new columns appended last; security_invoker restated.

CREATE OR REPLACE VIEW v_srv_emergency WITH (security_invoker = true) AS
 SELECT e.id,
    e.issued_at,
    e.notes,
    e.region_id,
    r.name AS region_name,
    e.station_id,
    s.station_name,
    e.unit_id,
    u.unit_name,
    e.warehouse_valve_id,
    w.serial_number AS issued_serial,
    w.warehouse_code AS issued_code,
    w.pressure_min,
    w.pressure_max,
    w.pressure_unit,
    w.set_pressure_raw,
    e.replaced_installed_valve_id,
    o.serial_number AS replaced_serial,
    o.warehouse_code AS replaced_code,
    l.id AS log_id,
        CASE
            WHEN (l.id IS NULL) THEN NULL::text
            WHEN (l.returned_at IS NOT NULL) THEN 'returned'::text
            ELSE 'at_station'::text
        END AS replaced_status,
    w.serial_number,
    w.manufacturer,
    w.size_type,
    w.inlet_size,
    w.outlet_size
   FROM ((((((srv_issues e
     JOIN regions r ON ((r.id = e.region_id)))
     JOIN stations s ON ((s.id = e.station_id)))
     JOIN units u ON ((u.id = e.unit_id)))
     JOIN warehouse_relief_valves w ON ((w.id = e.warehouse_valve_id)))
     LEFT JOIN installed_relief_valves o ON ((o.id = e.replaced_installed_valve_id)))
     LEFT JOIN srv_field_log l ON (((l.issue_id = e.id) AND (l.archived_at IS NULL))))
  WHERE (e.is_emergency AND (e.emergency_removed_at IS NULL));
