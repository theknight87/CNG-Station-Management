-- Fix for 20260928140000: the Warehouse SRVs tab reads v_srv_warehouse_stock (stock only), not
-- v_warehouse_srv_management, so ordering by pressure_sort_bar failed in production ("column ... does not exist").
-- Restates the deployed definition verbatim (md5 e49900ea...) and appends pressure_sort_bar last.

CREATE OR REPLACE VIEW v_srv_warehouse_stock WITH (security_invoker = true) AS
 SELECT id,
    availability_status,
    warehouse_code,
    serial_number,
    serial_number_raw,
    serial_status,
    part_number,
    manufacturer,
    size_type,
    inlet_size,
    outlet_size,
    set_pressure_raw,
    pressure_min,
    pressure_max,
    pressure_unit,
    target_region_id,
    target_region_name,
    target_station_id,
    target_station_name,
    is_unassigned_stock,
    warehouse_issue_date,
    last_calibration_date,
    last_calibration_precision,
    last_calibration_display,
    next_calibration_date,
    next_calibration_precision,
    next_calibration_display,
    days_left,
    due_status,
    calibration_location,
    source_status_raw,
    needs_review,
    notes,
    created_at,
    updated_at,
    pressure_sort_bar
   FROM v_warehouse_srv_management v
  WHERE ((availability_status = ANY (ARRAY['available_new'::warehouse_availability, 'available_calibrated'::warehouse_availability, 'available_in_store_uc'::warehouse_availability])) AND (NOT (EXISTS ( SELECT 1
           FROM srv_calibration_jobs j
          WHERE ((j.warehouse_valve_id = v.id) AND (j.status <> 'certified'::text) AND (j.archived_at IS NULL))))));
