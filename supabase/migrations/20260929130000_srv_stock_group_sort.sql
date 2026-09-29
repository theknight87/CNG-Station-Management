-- Warehouse SRVs default order (owner request 2026-09-29).
--
-- Set pressure smallest first (as before), then — within one pressure — each SIZE together, smallest size first
-- (3/4" before 1"), and within one pressure and size: calibrated valves first, then new, then under calibration;
-- the calibrated ones oldest calibration first (July before August, 15 Sept before 30 Sept).
--
-- Three ORDERING KEYS are appended to v_srv_warehouse_stock. They are derived on read, never stored, never
-- displayed, and change no value:
--   inlet_sort_in / outlet_sort_in  the size in inches, read from the recorded text ("3/4\"" -> 0.75,
--                                   "1-1/4\"" -> 1.25, "1 1/2" -> 1.5, "1\"" -> 1). Text that is not a plain
--                                   size gives NULL, which sorts after every size — nothing is guessed.
--   availability_rank               1 calibrated, 2 new, 3 under calibration.
--
-- The deployed definition (20260928150000) is restated verbatim; the new columns are appended, the view stays
-- security_invoker (CREATE OR REPLACE VIEW does not keep reloptions unless restated), and no grant changes.

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
    END AS availability_rank
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

COMMENT ON COLUMN v_srv_warehouse_stock.inlet_sort_in IS 'Ordering key only: inlet size in inches read from inlet_size; NULL when not a plain size. Never displayed.';
COMMENT ON COLUMN v_srv_warehouse_stock.outlet_sort_in IS 'Ordering key only: outlet size in inches read from outlet_size; NULL when not a plain size. Never displayed.';
COMMENT ON COLUMN v_srv_warehouse_stock.availability_rank IS 'Ordering key only: 1 calibrated, 2 new, 3 under calibration. Never displayed.';
