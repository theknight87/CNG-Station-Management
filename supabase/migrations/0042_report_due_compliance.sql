-- ---------------------------------------------------------------------------
-- 0042 — The Reports module's one new database object (Prompt 20).
--
-- WHAT THE GAP ANALYSIS FOUND, AND WHY THIS IS THE ONLY VIEW ADDED.
--
-- Nearly every report the prompt asks for is already served by a view that
-- exists and is already RLS-bounded, already date-precision-correct, and
-- already the source the Unit workspace and the management modules read:
--
--   SRV report            -> v_installed_srv_management  (+ v_warehouse_srv_management)
--   Vessels report        -> v_vessel_management         (asset_type keeps Storage
--                                                         and Recovery distinct)
--   Gas detector report   -> v_gas_detector_management
--   Hose report           -> v_hose_registry
--   Notification activity -> v_alert_inbox
--   Data quality          -> v_data_quality_queue, v_admin_data_quality,
--                            v_admin_staged_mapping_queue
--
-- Building parallel reporting tables or re-deriving those columns would create
-- a second place for the truth to live. Reports READ those views.
--
-- The ONE thing no existing object provides is a UNIFIED cross-family due and
-- overdue list. `v_dashboard_due_summary` counts; it does not enumerate. So
-- this view — and nothing else — is added.
--
-- IT DERIVES NOTHING OF ITS OWN. `days_left` and `due_status` are taken from
-- the family views, which take them from `cng_days_left()` and
-- `cng_due_status()` — the same functions the alert engine uses, and the only
-- place in this system that computes them. A year-only, unknown or invalid
-- date therefore yields days_left NULL and due_status 'unknown' HERE for the
-- same reason it does in an alert: because the function refuses to produce a
-- number for a date that is not `exact_date`. There is no second
-- interpretation to drift.
--
-- `security_invoker = true` is stated explicitly. CREATE OR REPLACE VIEW does
-- not preserve reloptions (Prompt 19B), and every replacement of this view must
-- restate it. VIEWSEC-* asserts it from the catalog.
-- ---------------------------------------------------------------------------

CREATE VIEW v_report_due_compliance
WITH (security_invoker = true) AS
WITH families AS (
  -- ---- Installed SRV calibration -----------------------------------------
  -- The only family with an equipment parent, and the only one whose Station
  -- may be unconfirmed (station_id is nullable on installed_relief_valves).
  SELECT
    'srv_calibration'::alert_subject       AS subject,
    'installed_relief_valve'::asset_type   AS asset_type,
    v.id                                   AS asset_id,
    v.region_id, v.region_name,
    v.station_id, v.station_name, v.source_station_name_raw, v.station_display,
    v.unit_id, v.unit_name,
    v.parent_kind::text                    AS parent_kind,
    v.parent_label,
    v.serial_number, v.serial_number_raw, v.serial_status,
    v.part_number,
    v.manufacturer,
    -- installed_relief_valves has no `model` column. NULL is the fact, not a gap.
    NULL::text                             AS model,
    v.set_pressure_raw                     AS pressure_raw,
    v.last_calibration_date                AS last_done_date,
    v.last_calibration_precision           AS last_done_precision,
    v.last_calibration_display             AS last_done_display,
    v.next_calibration_date                AS next_due_date,
    v.next_calibration_precision           AS next_due_precision,
    v.next_calibration_display             AS next_due_display,
    v.days_left, v.due_status,
    v.mapping_status::text                 AS mapping_status,
    v.needs_mapping,
    v.source_status_raw, v.needs_review
  FROM v_installed_srv_management v

  UNION ALL
  -- ---- Storage vessel and Recovery tank -----------------------------------
  -- ONE branch, but never one entity: `asset_type` comes from the view and
  -- keeps them distinct, and the subject differs per row for the same reason.
  SELECT
    CASE v.asset_type
      WHEN 'storage_vessel' THEN 'storage_inspection'::alert_subject
      ELSE 'recovery_tank_inspection'
    END,
    v.asset_type,
    v.id,
    v.region_id, v.region_name,
    v.station_id, v.station_name, NULL::text, v.station_name,
    v.unit_id, v.unit_name,
    NULL::text, NULL::text,
    v.serial_number, v.serial_number_raw, v.serial_status,
    NULL::text,
    v.manufacturer, v.model,
    NULL::text,
    v.last_inspection_date, v.last_inspection_precision, v.last_inspection_display,
    v.next_inspection_date, v.next_inspection_precision, v.next_inspection_display,
    v.days_left, v.due_status,
    v.mapping_status::text, v.needs_mapping,
    v.source_status_raw, v.needs_review
  FROM v_vessel_management v

  UNION ALL
  -- ---- Gas detector calibration -------------------------------------------
  -- `v_gas_detector_management` UNIONs installed detectors with recorded
  -- ABSENCE. Recorded absence is evidence, not a device, and it has no
  -- calibration to be due — so only installed detectors appear here.
  SELECT
    'gas_detector_calibration'::alert_subject,
    'gas_detector'::asset_type,
    v.detector_id,
    v.region_id, v.region_name,
    v.station_id, v.station_name, NULL::text, v.station_name,
    v.unit_id, v.unit_name,
    NULL::text, NULL::text,
    v.serial_number, v.serial_number_raw, v.serial_status,
    NULL::text,
    v.manufacturer, v.model,
    NULL::text,
    v.last_calibration_date, v.last_calibration_precision, v.last_calibration_display,
    v.next_calibration_date, v.next_calibration_precision, v.next_calibration_display,
    v.days_left, v.due_status,
    v.mapping_status::text, v.needs_mapping,
    v.source_status_raw, v.needs_review
  FROM v_gas_detector_management v
  WHERE v.detector_id IS NOT NULL

  UNION ALL
  -- ---- Hose hydrotest ------------------------------------------------------
  -- A hose has no `model` column and its parent is a Dispenser, not equipment
  -- in the SRV sense. Its Unit may legitimately be NULL.
  SELECT
    'hose_hydrotest'::alert_subject,
    'hose'::asset_type,
    v.id,
    v.region_id, v.region_name,
    v.station_id, v.station_name, NULL::text, v.station_name,
    v.unit_id, v.unit_name,
    CASE WHEN v.dispenser_id IS NOT NULL THEN 'dispenser' END,
    v.dispenser_name,
    v.serial_number, v.serial_number_raw, v.serial_status,
    NULL::text,
    NULL::text, NULL::text,
    v.test_pressure_raw,
    v.last_test_date, v.last_test_precision, v.last_test_display,
    v.next_test_date, v.next_test_precision, v.next_test_display,
    v.days_left, v.due_status,
    v.mapping_status::text, v.needs_mapping,
    v.source_status_raw, v.needs_review
  FROM v_hose_registry v
)
SELECT
  f.*,
  -- Job Number exists ONLY on `units` and `compressors` in this schema. It is
  -- therefore the UNIT's job number, labelled as such in the UI, and never a
  -- per-asset identifier invented to fill a column.
  u.job_number AS unit_job_number
FROM families f
LEFT JOIN units u ON u.id = f.unit_id;

COMMENT ON VIEW v_report_due_compliance IS
  'Unified cross-family due/overdue report. Built ON TOP of the existing management views, so days_left and due_status come from cng_days_left()/cng_due_status() — the alert engine''s own functions — and are never re-derived. A non-exact date yields days_left NULL and due_status unknown, exactly as it does for an alert. security_invoker: RLS bounds the caller to their authorized Regions, and a Station-unconfirmed SRV stays admin/manager only.';

GRANT SELECT ON v_report_due_compliance TO authenticated;

-- ---------------------------------------------------------------------------
-- NO NEW INDEXES.
--
-- Every predicate and ordering the Reports module issues is already covered:
--
--   region_id        -> {irv,storage_vessels,recovery_tanks,gas_detectors,hoses}_region_idx
--   station_id       -> *_station_idx (partial, archived_at IS NULL)
--   unit_id          -> *_unit_idx
--   serial_number    -> *_serial_idx (partial, serial_number IS NOT NULL)
--   mapping_status   -> *_mapping_idx / irv_mapping_idx
--   next due date    -> *_due_idx, partial on precision = 'exact_date'
--                       — which is exactly the predicate a due report uses,
--                         because only an exact date may be classified
--   alerts by state/region/station/date -> alerts_open_idx, alerts_region_idx,
--                       alerts_station_idx, alerts_asset_idx
--
-- Adding more would be speculative. The report's secondary sort key is the
-- primary key, which every table already indexes. If a real query plan later
-- shows a gap, that is the moment to add an index and say which query it is for.
-- ---------------------------------------------------------------------------
