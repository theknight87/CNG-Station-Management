-- Warehouse SRVs: show the destination Station exactly as the warehouse sheet names it.
--
-- Owner request 2026-10-01: the Warehouse SRV page must match sheet "رصيد المخزن" exactly. The view
-- showed a destination only through target_station_id, so a valve sent to a Station whose name does not
-- resolve to exactly one canonical Station showed no destination at all, and was counted as
-- "unassigned stock" although the sheet names where it went.
--
-- This replaces v_warehouse_srv_management with:
--   * target_station_raw (appended) — the sheet's Station text, trimmed, from source_raw. Evidence for
--     display only: it never sets target_station_id and is never matched by similarity (§8).
--   * is_unassigned_stock — true only when the sheet names no Station AND none is linked.
-- No table, column, grant or policy changes. security_invoker is restated (CREATE OR REPLACE VIEW does not
-- keep reloptions unless restated — Prompt 19B).

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
    (w.target_station_id IS NULL AND nullif(btrim(w.source_raw->>'Station'), '') IS NULL) AS is_unassigned_stock,
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
        END AS pressure_sort_bar,
    nullif(btrim(w.source_raw->>'Station'), '') AS target_station_raw
   FROM ((warehouse_relief_valves w
     LEFT JOIN regions r ON ((r.id = w.target_region_id)))
     LEFT JOIN stations s ON ((s.id = w.target_station_id)))
  WHERE (w.archived_at IS NULL);

COMMENT ON COLUMN v_warehouse_srv_management.pressure_sort_bar IS 'Ordering key only: set pressure (max) in BAR; PSI converted. Never displayed.';
COMMENT ON COLUMN v_warehouse_srv_management.target_station_raw IS 'Destination Station exactly as the warehouse sheet names it (source_raw). Display evidence only — never a link.';

-- The Warehouse page reads v_srv_warehouse_stock (stock in store), which selects named columns from the view
-- above; it is recreated unchanged except for target_station_raw appended at the end.
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
    v.target_station_raw
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
COMMENT ON COLUMN v_srv_warehouse_stock.target_station_raw IS 'Destination Station exactly as the warehouse sheet names it (source_raw). Display evidence only — never a link.';
