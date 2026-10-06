-- 20261006110000_srv_issue_sheet_transfer_as_issued.sql — a moved valve reads on the issue sheet as if it had been issued
-- straight to the Station it went to (owner ruling 2026-10-06: "عايزه يتغير المحطة علطول ... كأن الصرف من البداية لشطا").
--
-- 20261006090000 kept the issue at A on its sheet and wrote "محول إلى <B>" in the return-date column. The owner wants
-- no note: the row stays where it is (the day and Region it left the warehouse), but its Station, Stage/Storage, the
-- valve it replaced and that valve's return date are those of the FINAL issue in the move chain (A -> B -> C ... ends
-- at the live or undone issue). The issue at A's own replaced valve went back to its position and is not on the sheet.
-- If the final issue was undone, the row is marked cancelled as any undone issue is.
--
-- v_srv_issue_sheet restated: same columns, same order (transferred_to / transferred_at still filled), only the
-- place-side expressions now read the final issue. security_invoker restated. No table, grant or policy change;
-- cng_srv_issue_sheet_assign is unchanged (it places the issue at A, never a move).

CREATE OR REPLACE VIEW v_srv_issue_sheet WITH (security_invoker = true) AS
WITH RECURSIVE chain AS (
  SELECT i.id AS origin, i.id AS cur, 0 AS depth FROM srv_issues i WHERE i.transferred_from_issue_id IS NULL
  UNION ALL
  SELECT c.origin, t.id, c.depth + 1 FROM chain c JOIN srv_issues t ON t.transferred_from_issue_id = c.cur
), final AS (
  SELECT DISTINCT ON (origin) origin, cur FROM chain ORDER BY origin, depth DESC
)
SELECT e.id,
       e.issued_at,
       (e.issued_at AT TIME ZONE 'Africa/Cairo')::date AS issue_day,
       e.region_id, r.name AS region_name,
       e.sheet_id, sh.seq AS sheet_seq, sh.exported_at AS sheet_exported_at,
       e.is_emergency,
       s.station_name, u.unit_name,
       CASE WHEN nv.id IS NOT NULL AND nv.unit_id IS NULL THEN s.station_name ELSE u.unit_name END AS place_name,
       COALESCE(nullif(btrim(nv.location_raw), ''),
                CASE WHEN nv.storage_vessel_id IS NOT NULL OR nv.expected_parent_kind = 'storage_vessel' THEN 'Storage'
                     WHEN nv.compressor_id IS NOT NULL OR nv.expected_parent_kind = 'compressor' THEN 'Stage' END) AS location,
       e.warehouse_valve_id,
       w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.manufacturer, w.size_type, w.inlet_size, w.outlet_size,
       w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       f.replaced_installed_valve_id, o.serial_number AS replaced_serial,
       l.returned_at AS replaced_returned_at,
       (f.cancel_action = 'await_return' OR (f.id <> e.id AND f.cancel_action = 'to_stock')) IS TRUE AS is_cancelled,
       CASE WHEN f.cancel_action IN ('await_return', 'to_stock') THEN f.cancelled_at END AS cancelled_at,
       ul.returned_at AS cancelled_returned_at,
       CASE WHEN f.id <> e.id THEN CASE WHEN nv.id IS NOT NULL AND nv.unit_id IS NULL THEN s.station_name ELSE u.unit_name END END AS transferred_to,
       CASE WHEN f.id <> e.id THEN e.cancelled_at END AS transferred_at
  FROM srv_issues e
  JOIN final fi ON fi.origin = e.id
  JOIN srv_issues f ON f.id = fi.cur
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = f.station_id
  JOIN units u ON u.id = f.unit_id
  JOIN warehouse_relief_valves w ON w.id = e.warehouse_valve_id
  LEFT JOIN installed_relief_valves nv ON nv.id = f.new_installed_valve_id
  LEFT JOIN installed_relief_valves o ON o.id = f.replaced_installed_valve_id
  LEFT JOIN srv_issue_sheets sh ON sh.id = e.sheet_id
  LEFT JOIN srv_field_log l ON l.issue_id = f.id AND l.reason = 'replaced_on_issue'
                           AND l.installed_valve_id = f.replaced_installed_valve_id AND l.archived_at IS NULL
  LEFT JOIN srv_field_log ul ON ul.issue_id = f.id AND ul.reason = 'issue_undone' AND ul.archived_at IS NULL
 WHERE (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
   AND e.transferred_from_issue_id IS NULL;
COMMENT ON VIEW v_srv_issue_sheet IS
  'Rows of the warehouse issue workbook: every SRV issue that left the warehouse (live, undone as await_return and marked cancelled, or moved on to other Stations), on the day and Region it left. A moved valve reads as issued straight to the place it ended up: Station, Stage/Storage, replaced valve and its return date come from the last issue of the move chain (transferred_to names it).';
GRANT SELECT ON v_srv_issue_sheet TO authenticated;
REVOKE ALL ON v_srv_issue_sheet FROM anon;
