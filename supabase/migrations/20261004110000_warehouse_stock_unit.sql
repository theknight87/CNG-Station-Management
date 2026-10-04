-- The store list (Warehouse SRVs tab) reads v_srv_warehouse_stock, which is built on v_warehouse_srv_management.
-- 20261004100000 appended target_unit_id / target_unit_name to the base view but not here, so the tab failed with
-- "column v_srv_warehouse_stock.target_unit_id does not exist" (owner report 2026-10-04). This restates the view
-- exactly as 20261001120000 left it with the two columns appended (security_invoker restated). No DML.

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
    pressure_sort_bar,
    sz.inlet_sort_in,
    sz.outlet_sort_in,
    CASE v.availability_status
      WHEN 'available_calibrated'::warehouse_availability THEN 1
      WHEN 'available_new'::warehouse_availability THEN 2
      WHEN 'available_in_store_uc'::warehouse_availability THEN 3
      ELSE 4
    END AS availability_rank,
    v.target_station_raw,
    v.target_unit_id,
    v.target_unit_name
   FROM v_warehouse_srv_management v
   CROSS JOIN LATERAL (
     SELECT
       CASE
         WHEN i ~ '^\d+(\.\d+)?$' THEN i::numeric
         WHEN i ~ '^\d+/[1-9]\d*$' THEN split_part(i, '/', 1)::numeric / split_part(i, '/', 2)::numeric
         WHEN i ~ '^\d+ \d+/[1-9]\d*$' THEN split_part(i, ' ', 1)::numeric
           + split_part(split_part(i, ' ', 2), '/', 1)::numeric / split_part(split_part(i, ' ', 2), '/', 2)::numeric
       END AS inlet_sort_in,
       CASE
         WHEN o ~ '^\d+(\.\d+)?$' THEN o::numeric
         WHEN o ~ '^\d+/[1-9]\d*$' THEN split_part(o, '/', 1)::numeric / split_part(o, '/', 2)::numeric
         WHEN o ~ '^\d+ \d+/[1-9]\d*$' THEN split_part(o, ' ', 1)::numeric
           + split_part(split_part(o, ' ', 2), '/', 1)::numeric / split_part(split_part(o, ' ', 2), '/', 2)::numeric
       END AS outlet_sort_in
     FROM (
       -- Inch marks and the word inch dropped, "1-1/4" read as "1 1/4", spaces collapsed.
       SELECT btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(v.inlet_size, ''), '["”″'']|inch(es)?', '', 'gi'),
                                                  '(\d)\s*-\s*(\d)', '\1 \2', 'g'), '\s+', ' ', 'g')) AS i,
              btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(v.outlet_size, ''), '["”″'']|inch(es)?', '', 'gi'),
                                                  '(\d)\s*-\s*(\d)', '\1 \2', 'g'), '\s+', ' ', 'g')) AS o
     ) t
   ) sz
  WHERE ((availability_status = ANY (ARRAY['available_new'::warehouse_availability, 'available_calibrated'::warehouse_availability, 'available_in_store_uc'::warehouse_availability])) AND (NOT (EXISTS ( SELECT 1
           FROM srv_calibration_jobs j
          WHERE ((j.warehouse_valve_id = v.id) AND (j.status <> 'certified'::text) AND (j.archived_at IS NULL))))));
