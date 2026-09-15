-- 0029_hierarchy_views.sql
-- Station and Unit summaries for the hierarchy browser.
--
-- WHY. The Stations list needs, per station, its unit count, asset count and
-- attention counts. Fetching every asset row to count them in the browser would
-- be N+1 at ~300 stations and thousands of assets — and would put the region
-- filter in the client, where it is decoration rather than a boundary.
--
-- SECURITY. `security_invoker = true`, so base tables are read AS THE CALLER and
-- their RLS applies. A station in a region the caller cannot read produces no
-- row: not a zero row, not a redacted row — no row. Its name, its unit count and
-- its existence are all unavailable, including through search, sorting and
-- pagination counts. No SECURITY DEFINER, no service_role, nothing granted to
-- `anon`.
--
-- Due status reuses `cng_due_status()`, the same function the dashboard and the
-- asset screens use, so "overdue" cannot mean three different things in three
-- places. Warehouse relief valves are absent by construction: they belong to no
-- station and must never be counted as station assets.

-- ---------------------------------------------------------------------------
-- 1. Station summary
-- ---------------------------------------------------------------------------

CREATE VIEW v_station_summary
WITH (security_invoker = true) AS
SELECT
  s.id            AS station_id,
  s.station_name,
  -- The folded form, exposed so search can match `الماظه` against `الماظة`
  -- without the client reimplementing the folding rules.
  s.normalized_name,
  s.region_id,
  r.code          AS region_code,
  r.name          AS region_name,
  r.sort_order    AS region_sort_order,
  s.bay_status,
  s.bay_status_raw,
  s.notes,
  s.needs_review,
  s.review_reason,
  s.archived_at,
  (SELECT count(*) FROM units u
    WHERE u.station_id = s.id AND u.archived_at IS NULL)::bigint AS units,
  (
    (SELECT count(*) FROM installed_relief_valves v WHERE v.station_id = s.id) +
    (SELECT count(*) FROM storage_vessels sv WHERE sv.station_id = s.id) +
    (SELECT count(*) FROM recovery_tanks rt WHERE rt.station_id = s.id) +
    (SELECT count(*) FROM gas_detectors g WHERE g.station_id = s.id) +
    (SELECT count(*) FROM hoses h WHERE h.station_id = s.id) +
    (SELECT count(*) FROM compressors c WHERE c.station_id = s.id) +
    (SELECT count(*) FROM dispensers d WHERE d.station_id = s.id)
  )::bigint AS assets,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.station_id = s.id
        AND cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.station_id = s.id
        AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.station_id = s.id
        AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.station_id = s.id
        AND cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM hoses h
      WHERE h.station_id = s.id
        AND cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue')
  )::bigint AS overdue,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.station_id = s.id
        AND cng_due_status(v.next_calibration_date, v.next_calibration_precision)
            IN ('due_today','due_7','due_15','due_30','due_60')) +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.station_id = s.id
        AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision)
            IN ('due_today','due_7','due_15','due_30','due_60')) +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.station_id = s.id
        AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision)
            IN ('due_today','due_7','due_15','due_30','due_60')) +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.station_id = s.id
        AND cng_due_status(g.next_calibration_date, g.next_calibration_precision)
            IN ('due_today','due_7','due_15','due_30','due_60')) +
    (SELECT count(*) FROM hoses h
      WHERE h.station_id = s.id
        AND cng_due_status(h.next_test_date, h.next_test_precision)
            IN ('due_today','due_7','due_15','due_30','due_60'))
  )::bigint AS approaching_due,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.station_id = s.id AND v.mapping_status <> 'resolved') +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.station_id = s.id AND sv.mapping_status <> 'resolved') +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.station_id = s.id AND rt.mapping_status <> 'resolved') +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.station_id = s.id AND g.mapping_status <> 'resolved') +
    (SELECT count(*) FROM hoses h
      WHERE h.station_id = s.id AND h.mapping_status <> 'resolved')
  )::bigint AS unresolved_mapping
FROM stations s
JOIN regions r ON r.id = s.region_id
WHERE s.archived_at IS NULL;

COMMENT ON VIEW v_station_summary IS
  'One row per station the caller may read, with its unit, asset and attention '
  'counts. A station outside the caller''s region scope produces NO row, so its '
  'name and size cannot be inferred through search, sorting or pagination.';

-- ---------------------------------------------------------------------------
-- 2. Unit summary
-- ---------------------------------------------------------------------------
-- Equipment models are NOT copied onto the unit. A unit has a compressor
-- record; it does not have a "compressor model" field of its own, and inventing
-- one here would duplicate equipment data onto the wrong entity.

CREATE VIEW v_unit_summary
WITH (security_invoker = true) AS
SELECT
  u.id          AS unit_id,
  u.unit_name,
  u.normalized_name,
  u.station_id,
  s.station_name,
  u.region_id,
  r.code        AS region_code,
  r.name        AS region_name,
  u.job_number,
  u.job_number_raw,
  u.dispenser_count_reported,
  u.hose_count_reported,
  u.storage_count_reported,
  u.notes,
  u.needs_review,
  u.archived_at,
  (SELECT count(*) FROM compressors c WHERE c.unit_id = u.id)::bigint      AS compressors,
  (SELECT count(*) FROM dispensers d WHERE d.unit_id = u.id)::bigint       AS dispensers,
  (SELECT count(*) FROM storage_vessels sv WHERE sv.unit_id = u.id)::bigint AS storage_vessels,
  (SELECT count(*) FROM recovery_tanks rt WHERE rt.unit_id = u.id)::bigint  AS recovery_tanks,
  (SELECT count(*) FROM gas_detectors g WHERE g.unit_id = u.id)::bigint     AS gas_detectors,
  (SELECT count(*) FROM hoses h WHERE h.unit_id = u.id)::bigint             AS hoses,
  -- Only SRVs whose UNIT is confirmed. An unresolved SRV is never attributed to
  -- a unit it has not been proven to belong to (CLAUDE.md §4).
  (SELECT count(*) FROM installed_relief_valves v WHERE v.unit_id = u.id)::bigint AS installed_srvs,
  (
    (SELECT count(*) FROM installed_relief_valves v
      WHERE v.unit_id = u.id
        AND cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM storage_vessels sv
      WHERE sv.unit_id = u.id
        AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM recovery_tanks rt
      WHERE rt.unit_id = u.id
        AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue') +
    (SELECT count(*) FROM gas_detectors g
      WHERE g.unit_id = u.id
        AND cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue') +
    (SELECT count(*) FROM hoses h
      WHERE h.unit_id = u.id
        AND cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue')
  )::bigint AS overdue
FROM units u
JOIN stations s ON s.id = u.station_id
JOIN regions r  ON r.id = u.region_id
WHERE u.archived_at IS NULL;

COMMENT ON VIEW v_unit_summary IS
  'One row per unit the caller may read. Equipment models are deliberately not '
  'copied onto the unit; a unit owns equipment records, it does not carry their '
  'fields. SRV counts include only unit-confirmed valves.';

GRANT SELECT ON v_station_summary TO authenticated;
GRANT SELECT ON v_unit_summary    TO authenticated;
