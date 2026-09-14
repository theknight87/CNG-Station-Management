-- 0011_management_views.sql
-- Read-only management views. These are VIEWS OVER THE SAME RECORDS: they own
-- nothing, duplicate nothing, and do not alter the physical hierarchy.
--
-- Every view derives Days Left and status through cng_days_left/cng_due_status,
-- so date precision is honoured in exactly one place.
--
-- security_invoker = true is essential: without it a view would run with the
-- definer's rights and quietly bypass RLS on its base tables. With it, every row
-- returned is still filtered by the caller's own policies.

-- ---------------------------------------------------------------------------
-- v_installed_srv_management — every installed SRV, resolved or not.
-- Used by BOTH the global SRV Management module and the Unit SRVs tab; they
-- differ only by WHERE clause, which is what keeps them from diverging.
-- ---------------------------------------------------------------------------

CREATE VIEW v_installed_srv_management
WITH (security_invoker = true) AS
SELECT
  v.id,
  r.id   AS region_id,
  r.name AS region_name,
  s.id   AS station_id,
  s.station_name,
  u.id   AS unit_id,
  u.unit_name,
  v.mapping_status,
  (v.mapping_status <> 'resolved')                AS needs_mapping,
  v.expected_parent_kind,
  v.location_raw,
  -- Resolved parent, flattened for display.
  CASE
    WHEN v.compressor_id     IS NOT NULL THEN 'compressor'::srv_parent_kind
    WHEN v.storage_vessel_id IS NOT NULL THEN 'storage_vessel'::srv_parent_kind
    WHEN v.dispenser_id      IS NOT NULL THEN 'dispenser'::srv_parent_kind
  END                                             AS parent_kind,
  coalesce(v.compressor_id, v.storage_vessel_id, v.dispenser_id) AS parent_id,
  coalesce(c.model, sv.model, d.model)             AS parent_label,
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
  cng_days_left(v.next_calibration_date, v.next_calibration_precision)  AS days_left,
  cng_due_status(v.next_calibration_date, v.next_calibration_precision) AS due_status,
  v.source_status_raw,
  v.needs_review,
  v.notes,
  v.import_batch_id,
  v.created_at,
  v.updated_at
FROM installed_relief_valves v
JOIN regions  r  ON r.id = v.region_id
JOIN stations s  ON s.id = v.station_id
LEFT JOIN units u            ON u.id  = v.unit_id
LEFT JOIN compressors c      ON c.id  = v.compressor_id
LEFT JOIN storage_vessels sv ON sv.id = v.storage_vessel_id
LEFT JOIN dispensers d       ON d.id  = v.dispenser_id
WHERE v.archived_at IS NULL;

COMMENT ON VIEW v_installed_srv_management IS
  'All installed SRVs with region/station/unit/parent and derived due status. '
  'Unit SRV tab filters: unit_id = :unit AND mapping_status IN (resolved, needs_equipment_mapping) — '
  'needs_unit_mapping and conflict are never shown inside a unit (prompt §29).';

-- ---------------------------------------------------------------------------
-- v_unit_srvs — the Unit SRV tab, with the §29 rule applied in the database so
-- a UI mistake cannot show an unmapped valve inside a unit it may not belong to.
-- ---------------------------------------------------------------------------

CREATE VIEW v_unit_srvs
WITH (security_invoker = true) AS
SELECT *
FROM v_installed_srv_management
WHERE unit_id IS NOT NULL
  AND mapping_status IN ('resolved', 'needs_equipment_mapping');

COMMENT ON VIEW v_unit_srvs IS
  'SRVs shown inside a Unit tab: resolved, plus needs_equipment_mapping (unit confirmed, parent not). Never needs_unit_mapping or conflict.';

-- ---------------------------------------------------------------------------
-- v_warehouse_srv_management
-- ---------------------------------------------------------------------------

CREATE VIEW v_warehouse_srv_management
WITH (security_invoker = true) AS
SELECT
  w.id,
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
  r.id   AS target_region_id,
  r.name AS target_region_name,
  s.id   AS target_station_id,
  s.station_name AS target_station_name,
  (w.target_station_id IS NULL) AS is_unassigned_stock,
  w.warehouse_issue_date,
  w.last_calibration_date,
  w.last_calibration_precision,
  cng_date_display(w.last_calibration_date, w.last_calibration_precision, w.last_calibration_raw) AS last_calibration_display,
  w.next_calibration_date,
  w.next_calibration_precision,
  cng_date_display(w.next_calibration_date, w.next_calibration_precision, w.next_calibration_raw) AS next_calibration_display,
  cng_days_left(w.next_calibration_date, w.next_calibration_precision)  AS days_left,
  cng_due_status(w.next_calibration_date, w.next_calibration_precision) AS due_status,
  w.calibration_location,
  w.source_status_raw,
  w.needs_review,
  w.notes,
  w.created_at,
  w.updated_at
FROM warehouse_relief_valves w
LEFT JOIN regions  r ON r.id = w.target_region_id
LEFT JOIN stations s ON s.id = w.target_station_id
WHERE w.archived_at IS NULL;

-- ---------------------------------------------------------------------------
-- v_vessel_management — Storage + Recovery combined FOR REPORTING ONLY.
-- The physical tables stay separate; asset_type distinguishes them.
-- ---------------------------------------------------------------------------

CREATE VIEW v_vessel_management
WITH (security_invoker = true) AS
SELECT
  'storage_vessel'::asset_type AS asset_type,
  sv.id,
  r.id AS region_id, r.name AS region_name,
  s.id AS station_id, s.station_name,
  u.id AS unit_id,   u.unit_name,
  sv.mapping_status,
  (sv.mapping_status <> 'resolved') AS needs_mapping,
  sv.manufacturer, sv.model, sv.serial_number, sv.serial_number_raw, sv.serial_status,
  sv.compressor_type_raw,
  sv.last_inspection_date AS last_inspection_date,
  sv.last_inspection_precision AS last_inspection_precision,
  cng_date_display(sv.last_inspection_date, sv.last_inspection_precision, sv.last_inspection_raw) AS last_inspection_display,
  sv.next_inspection_date AS next_inspection_date,
  sv.next_inspection_precision AS next_inspection_precision,
  cng_date_display(sv.next_inspection_date, sv.next_inspection_precision, sv.next_inspection_raw) AS next_inspection_display,
  cng_days_left(sv.next_inspection_date, sv.next_inspection_precision)  AS days_left,
  cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) AS due_status,
  sv.source_status_raw, sv.needs_review, sv.notes, sv.created_at, sv.updated_at
FROM storage_vessels sv
JOIN regions r  ON r.id = sv.region_id
JOIN stations s ON s.id = sv.station_id
LEFT JOIN units u ON u.id = sv.unit_id
WHERE sv.archived_at IS NULL

UNION ALL

SELECT
  'recovery_tank'::asset_type AS asset_type,
  rt.id,
  r.id, r.name,
  s.id, s.station_name,
  u.id, u.unit_name,
  rt.mapping_status,
  (rt.mapping_status <> 'resolved'),
  rt.manufacturer, rt.model, rt.serial_number, rt.serial_number_raw, rt.serial_status,
  rt.compressor_type_raw,
  rt.last_inspection_date,
  rt.last_inspection_precision,
  cng_date_display(rt.last_inspection_date, rt.last_inspection_precision, rt.last_inspection_raw),
  rt.next_inspection_date,
  rt.next_inspection_precision,
  cng_date_display(rt.next_inspection_date, rt.next_inspection_precision, rt.next_inspection_raw),
  cng_days_left(rt.next_inspection_date, rt.next_inspection_precision),
  cng_due_status(rt.next_inspection_date, rt.next_inspection_precision),
  rt.source_status_raw, rt.needs_review, rt.notes, rt.created_at, rt.updated_at
FROM recovery_tanks rt
JOIN regions r  ON r.id = rt.region_id
JOIN stations s ON s.id = rt.station_id
LEFT JOIN units u ON u.id = rt.unit_id
WHERE rt.archived_at IS NULL;

COMMENT ON VIEW v_vessel_management IS
  'Storage vessels and recovery tanks unioned for the global Vessels module. Their physical tables are NOT merged — asset_type distinguishes two different equipment entities.';

-- ---------------------------------------------------------------------------
-- v_gas_detector_management — installed assets AND explicit not-installed
-- evidence, in one list, without fabricating a detector record for absence.
-- ---------------------------------------------------------------------------

CREATE VIEW v_gas_detector_management
WITH (security_invoker = true) AS
SELECT
  g.id                       AS detector_id,
  'installed'::presence_state AS detector_presence,
  r.id AS region_id, r.name AS region_name,
  s.id AS station_id, s.station_name,
  u.id AS unit_id,   u.unit_name,
  p.area_type, p.area_type_raw,
  g.mapping_status,
  (g.mapping_status <> 'resolved') AS needs_mapping,
  g.manufacturer, g.model, g.serial_number, g.serial_number_raw, g.serial_status,
  g.last_calibration_date, g.last_calibration_precision,
  cng_date_display(g.last_calibration_date, g.last_calibration_precision, g.last_calibration_raw) AS last_calibration_display,
  g.next_calibration_date, g.next_calibration_precision,
  cng_date_display(g.next_calibration_date, g.next_calibration_precision, g.next_calibration_raw) AS next_calibration_display,
  cng_days_left(g.next_calibration_date, g.next_calibration_precision)  AS days_left,
  cng_due_status(g.next_calibration_date, g.next_calibration_precision) AS due_status,
  g.source_status_raw, g.needs_review, g.notes
FROM gas_detectors g
JOIN regions r  ON r.id = g.region_id
JOIN stations s ON s.id = g.station_id
LEFT JOIN units u ON u.id = g.unit_id
LEFT JOIN gas_detector_presence p
       ON p.station_id = g.station_id
      AND (p.unit_id = g.unit_id OR (p.unit_id IS NULL AND g.unit_id IS NULL))
WHERE g.archived_at IS NULL

UNION ALL

-- Presence evidence where no detector asset exists. No serial, no dates: there
-- is no device. 'Closed Area + not_installed' is filterable but is NOT declared
-- a compliance violation here — that judgement belongs to an engineer.
SELECT
  NULL::uuid                 AS detector_id,
  p.detector_presence,
  r.id, r.name,
  s.id, s.station_name,
  u.id, u.unit_name,
  p.area_type, p.area_type_raw,
  NULL::asset_mapping_status, false,
  NULL, NULL, NULL, NULL, NULL::serial_status,
  NULL::date, NULL::date_precision, NULL,
  NULL::date, NULL::date_precision, NULL,
  NULL::integer, 'unknown'::due_status,
  p.presence_raw, false, p.notes
FROM gas_detector_presence p
JOIN regions r  ON r.id = p.region_id
JOIN stations s ON s.id = p.station_id
LEFT JOIN units u ON u.id = p.unit_id
WHERE p.detector_presence <> 'installed';

COMMENT ON VIEW v_gas_detector_management IS
  'Installed detectors plus explicit not-installed / unknown presence evidence. Absence rows carry detector_id = NULL: no fake asset is ever created (prompt §31).';

-- ---------------------------------------------------------------------------
-- v_hose_management
-- ---------------------------------------------------------------------------

CREATE VIEW v_hose_management
WITH (security_invoker = true) AS
SELECT
  h.id,
  r.id AS region_id, r.name AS region_name,
  s.id AS station_id, s.station_name,
  u.id AS unit_id,   u.unit_name,
  h.dispenser_id, d.dispenser_name,
  h.mapping_status,
  (h.mapping_status <> 'resolved') AS needs_mapping,
  h.description,
  h.serial_number, h.serial_number_raw, h.serial_status,
  h.working_pressure_raw, h.working_pressure_value, h.working_pressure_unit,
  h.test_pressure_raw,    h.test_pressure_value,    h.test_pressure_unit,
  h.last_test_date, h.last_test_precision,
  cng_date_display(h.last_test_date, h.last_test_precision, h.last_test_raw) AS last_test_display,
  h.next_test_date, h.next_test_precision,
  cng_date_display(h.next_test_date, h.next_test_precision, h.next_test_raw) AS next_test_display,
  cng_days_left(h.next_test_date, h.next_test_precision)  AS days_left,
  cng_due_status(h.next_test_date, h.next_test_precision) AS due_status,
  h.source_status_raw, h.needs_review, h.notes
FROM hoses h
JOIN regions r  ON r.id = h.region_id
JOIN stations s ON s.id = h.station_id
LEFT JOIN units u      ON u.id = h.unit_id
LEFT JOIN dispensers d ON d.id = h.dispenser_id
WHERE h.archived_at IS NULL;

-- ---------------------------------------------------------------------------
-- v_data_quality_queue — one list of everything awaiting a human, across types.
-- ---------------------------------------------------------------------------

CREATE VIEW v_data_quality_queue
WITH (security_invoker = true) AS
SELECT 'installed_relief_valve'::asset_type AS asset_type, v.id AS asset_id,
       v.region_id, v.station_id, v.unit_id,
       v.mapping_status::text AS mapping_status, v.needs_review, v.review_reason, v.updated_at
FROM installed_relief_valves v WHERE v.mapping_status <> 'resolved' OR v.needs_review
UNION ALL
SELECT 'storage_vessel', sv.id, sv.region_id, sv.station_id, sv.unit_id,
       sv.mapping_status::text, sv.needs_review, sv.review_reason, sv.updated_at
FROM storage_vessels sv WHERE sv.mapping_status <> 'resolved' OR sv.needs_review
UNION ALL
SELECT 'recovery_tank', rt.id, rt.region_id, rt.station_id, rt.unit_id,
       rt.mapping_status::text, rt.needs_review, rt.review_reason, rt.updated_at
FROM recovery_tanks rt WHERE rt.mapping_status <> 'resolved' OR rt.needs_review
UNION ALL
SELECT 'gas_detector', g.id, g.region_id, g.station_id, g.unit_id,
       g.mapping_status::text, g.needs_review, g.review_reason, g.updated_at
FROM gas_detectors g WHERE g.mapping_status <> 'resolved' OR g.needs_review
UNION ALL
SELECT 'hose', h.id, h.region_id, h.station_id, h.unit_id,
       h.mapping_status::text, h.needs_review, h.review_reason, h.updated_at
FROM hoses h WHERE h.mapping_status <> 'resolved' OR h.needs_review
UNION ALL
SELECT 'compressor', c.id, c.region_id, c.station_id, c.unit_id,
       c.mapping_status::text, c.needs_review, c.review_reason, c.updated_at
FROM compressors c WHERE c.mapping_status <> 'resolved' OR c.needs_review
UNION ALL
SELECT 'dispenser', dd.id, dd.region_id, dd.station_id, dd.unit_id,
       dd.mapping_status::text, dd.needs_review, dd.review_reason, dd.updated_at
FROM dispensers dd WHERE dd.mapping_status <> 'resolved' OR dd.needs_review;

COMMENT ON VIEW v_data_quality_queue IS 'Everything awaiting human resolution, across all asset types.';
