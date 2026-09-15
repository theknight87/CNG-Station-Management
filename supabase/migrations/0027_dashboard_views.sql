-- 0027_dashboard_views.sql
-- Dashboard aggregation, computed in PostgreSQL rather than in the browser.
--
-- WHY THESE EXIST. The dashboard needs counts over thousands of relief valves,
-- vessels and detectors. Fetching those rows to count them in JavaScript would
-- be wasteful at the expected scale (hundreds of stations, thousands of SRVs)
-- and — far worse — it would put the region filter in the client, where it is
-- decoration rather than a boundary. Aggregating here keeps both the work and
-- the authorization in the database.
--
-- SECURITY. Every view is `security_invoker = true`, so the underlying tables
-- are read AS THE CALLER and their RLS policies apply. An engineer authorized
-- for East counts East rows and nothing else; a region they cannot read
-- contributes nothing and does not appear at all. There is no SECURITY DEFINER
-- here, no privileged aggregation endpoint, and no way to widen scope by
-- querying the summary instead of the detail.
--
-- A consequence worth stating: a row a user cannot see is not merely hidden
-- from the list, it is absent from the COUNT. That is the intended behaviour —
-- a total that includes rows you may not read is itself a leak.
--
-- DUE BUCKETS are the ones `cng_due_status()` already defines, and they are
-- MUTUALLY EXCLUSIVE, not cumulative: `due_7` means "within 7 days",
-- `due_15` means "8 to 15 days", and so on. Nothing is counted twice, and
-- `unknown` (no exact date) is never conflated with `valid`.

-- ---------------------------------------------------------------------------
-- 1. Asset counts, by kind
-- ---------------------------------------------------------------------------
-- Installed assets only. Warehouse relief valves are inventory, not station
-- equipment, and are reported separately by `v_dashboard_warehouse_summary`
-- so they can never be added into a station asset total by accident.

CREATE VIEW v_dashboard_asset_counts
WITH (security_invoker = true) AS
SELECT 'station'::text                AS asset_kind, count(*)::bigint AS total FROM stations
UNION ALL SELECT 'unit',                count(*) FROM units
UNION ALL SELECT 'compressor',          count(*) FROM compressors
UNION ALL SELECT 'dispenser',           count(*) FROM dispensers
UNION ALL SELECT 'storage_vessel',      count(*) FROM storage_vessels
UNION ALL SELECT 'recovery_tank',       count(*) FROM recovery_tanks
UNION ALL SELECT 'gas_detector',        count(*) FROM gas_detectors
UNION ALL SELECT 'hose',                count(*) FROM hoses
UNION ALL SELECT 'installed_relief_valve', count(*) FROM installed_relief_valves;

COMMENT ON VIEW v_dashboard_asset_counts IS
  'One row per installed asset kind, counted under the caller''s RLS scope. '
  'Warehouse relief valves are deliberately absent: they are inventory, not '
  'station equipment.';

-- ---------------------------------------------------------------------------
-- 2. Inspection and calibration attention
-- ---------------------------------------------------------------------------
-- Every asset type that carries a due date, bucketed by the SAME function, so
-- an SRV and a hose cannot drift into different definitions of "overdue".

CREATE VIEW v_dashboard_due_summary
WITH (security_invoker = true) AS
SELECT 'installed_relief_valve'::text AS asset_kind,
       cng_due_status(v.next_calibration_date, v.next_calibration_precision) AS due_status,
       count(*)::bigint AS total
  FROM installed_relief_valves v
 GROUP BY 1, 2
UNION ALL
SELECT 'storage_vessel',
       cng_due_status(sv.next_inspection_date, sv.next_inspection_precision),
       count(*)
  FROM storage_vessels sv
 GROUP BY 1, 2
UNION ALL
SELECT 'recovery_tank',
       cng_due_status(rt.next_inspection_date, rt.next_inspection_precision),
       count(*)
  FROM recovery_tanks rt
 GROUP BY 1, 2
UNION ALL
SELECT 'gas_detector',
       cng_due_status(g.next_calibration_date, g.next_calibration_precision),
       count(*)
  FROM gas_detectors g
 GROUP BY 1, 2
UNION ALL
SELECT 'hose',
       cng_due_status(h.next_test_date, h.next_test_precision),
       count(*)
  FROM hoses h
 GROUP BY 1, 2;

COMMENT ON VIEW v_dashboard_due_summary IS
  'Asset kind x due bucket. Buckets are mutually exclusive, so totals sum '
  'without double counting. A year-only or invalid date lands in `unknown`, '
  'never in `valid` and never in a day-count bucket.';

-- ---------------------------------------------------------------------------
-- 3. Region overview
-- ---------------------------------------------------------------------------
-- Driven FROM `regions`, whose own RLS decides which regions the caller sees.
-- A region outside the caller's scope produces no row at all, so an engineer
-- cannot infer the size of a region they are not authorized for.

CREATE VIEW v_dashboard_region_summary
WITH (security_invoker = true) AS
SELECT
  r.id   AS region_id,
  r.code AS region_code,
  r.name AS region_name,
  r.sort_order,
  (SELECT count(*) FROM stations s WHERE s.region_id = r.id)::bigint AS stations,
  (SELECT count(*) FROM units u WHERE u.region_id = r.id)::bigint    AS units,
  (
    (SELECT count(*) FROM installed_relief_valves v WHERE v.region_id = r.id) +
    (SELECT count(*) FROM storage_vessels sv WHERE sv.region_id = r.id) +
    (SELECT count(*) FROM recovery_tanks rt WHERE rt.region_id = r.id) +
    (SELECT count(*) FROM gas_detectors g WHERE g.region_id = r.id) +
    (SELECT count(*) FROM hoses h WHERE h.region_id = r.id)
  )::bigint AS assets,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.region_id = r.id
        AND cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.region_id = r.id
        AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.region_id = r.id
        AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.region_id = r.id
        AND cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM hoses h
      WHERE h.region_id = r.id
        AND cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue')
  )::bigint AS overdue,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.region_id = r.id
        AND cng_due_status(v.next_calibration_date, v.next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.region_id = r.id
        AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.region_id = r.id
        AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.region_id = r.id
        AND cng_due_status(g.next_calibration_date, g.next_calibration_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')) +
    (SELECT count(*) FROM hoses h
      WHERE h.region_id = r.id
        AND cng_due_status(h.next_test_date, h.next_test_precision)
            IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60'))
  )::bigint AS approaching_due,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.region_id = r.id AND v.mapping_status <> 'resolved') +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.region_id = r.id AND sv.mapping_status <> 'resolved') +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.region_id = r.id AND rt.mapping_status <> 'resolved') +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.region_id = r.id AND g.mapping_status <> 'resolved') +
    (SELECT count(*) FROM hoses h
      WHERE h.region_id = r.id AND h.mapping_status <> 'resolved')
  )::bigint AS unresolved_mapping
FROM regions r;

COMMENT ON VIEW v_dashboard_region_summary IS
  'One row per region the caller may read. A region outside the caller''s '
  'scope produces NO row, so its size cannot be inferred from the dashboard.';

-- ---------------------------------------------------------------------------
-- 4. Data quality: unresolved mapping work
-- ---------------------------------------------------------------------------
-- Unresolved records are surfaced, never hidden. An unresolved mapping is
-- missing evidence, not a fault, and it is the queue Admin -> Data Quality
-- exists to work.
--
-- These are LIVE production counts. The Prompt 6 dry-run figures are facts
-- about the source workbooks, not about this database, and are deliberately
-- not embedded anywhere.

CREATE VIEW v_dashboard_mapping_summary
WITH (security_invoker = true) AS
SELECT asset_type::text AS asset_kind, mapping_status, count(*)::bigint AS total
  FROM v_data_quality_queue
 WHERE mapping_status IS NOT NULL
 GROUP BY 1, 2;

COMMENT ON VIEW v_dashboard_mapping_summary IS
  'Live unresolved-mapping counts under the caller''s RLS scope. Never '
  'pre-seeded with Prompt 6 dry-run figures, which describe the source files.';

-- ---------------------------------------------------------------------------
-- 5. Warehouse inventory — reported separately, on purpose
-- ---------------------------------------------------------------------------

CREATE VIEW v_dashboard_warehouse_summary
WITH (security_invoker = true) AS
SELECT
  count(*)::bigint AS total,
  count(*) FILTER (
    WHERE cng_due_status(w.next_calibration_date, w.next_calibration_precision) = 'overdue'
  )::bigint AS overdue,
  count(*) FILTER (
    WHERE cng_due_status(w.next_calibration_date, w.next_calibration_precision)
          IN ('due_today', 'due_7', 'due_15', 'due_30', 'due_60')
  )::bigint AS approaching_due
FROM warehouse_relief_valves w;

COMMENT ON VIEW v_dashboard_warehouse_summary IS
  'Warehouse stock. Separate from every installed-asset figure: these valves '
  'belong to no Unit, carry no mapping lifecycle, and must never be added into '
  'a station asset count.';

-- ---------------------------------------------------------------------------
-- 6. Grants — read-only, authenticated only
-- ---------------------------------------------------------------------------
-- `anon` gets nothing, consistent with every other object in this schema.

GRANT SELECT ON v_dashboard_asset_counts     TO authenticated;
GRANT SELECT ON v_dashboard_due_summary      TO authenticated;
GRANT SELECT ON v_dashboard_region_summary   TO authenticated;
GRANT SELECT ON v_dashboard_mapping_summary  TO authenticated;
GRANT SELECT ON v_dashboard_warehouse_summary TO authenticated;
