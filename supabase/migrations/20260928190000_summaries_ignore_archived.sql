-- Owner report 2026-09-28: شبرا 3 and شبرا 4 showed 7 overdue each; the real figure is 4 (3 valves + 1 vessel).
-- Cause: the summary views counted ARCHIVED records — relief valves replaced at an issue or removed by an admin are
-- archived (never deleted, CLAUDE.md §10), and 402 such valves are archived in production. Every count in the Unit,
-- Station, Region and dashboard summaries and in the data-quality queue now ignores archived rows, for every asset
-- table (only relief valves have archived rows today; the others are covered so a future archive cannot bring the
-- defect back). Definitions are the deployed ones (pg_get_viewdef, identical locally and in production), each FROM of
-- an asset table given `archived_at IS NULL`; columns unchanged; security_invoker restated.

CREATE OR REPLACE VIEW v_unit_summary WITH (security_invoker = true) AS
 SELECT u.id AS unit_id,
    u.unit_name,
    u.normalized_name,
    u.station_id,
    s.station_name,
    u.region_id,
    r.code AS region_code,
    r.name AS region_name,
    u.job_number,
    u.job_number_raw,
    u.dispenser_count_reported,
    u.hose_count_reported,
    u.storage_count_reported,
    u.notes,
    u.needs_review,
    u.archived_at,
    ( SELECT count(*) AS count
           FROM compressors c
          WHERE c.archived_at IS NULL AND ((c.unit_id = u.id))) AS compressors,
    ( SELECT count(*) AS count
           FROM dispensers d
          WHERE d.archived_at IS NULL AND ((d.unit_id = u.id))) AS dispensers,
    ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND ((sv.unit_id = u.id))) AS storage_vessels,
    ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND ((rt.unit_id = u.id))) AS recovery_tanks,
    ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND ((g.unit_id = u.id))) AS gas_detectors,
    ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND ((h.unit_id = u.id))) AS hoses,
    ( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND ((v.unit_id = u.id))) AS installed_srvs,
    ((((( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND (((v.unit_id = u.id) AND (cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue'::due_status)))) + ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND (((sv.unit_id = u.id) AND (cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND (((rt.unit_id = u.id) AND (cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND (((g.unit_id = u.id) AND (cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND (((h.unit_id = u.id) AND (cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue'::due_status))))) AS overdue
   FROM ((units u
     JOIN stations s ON ((s.id = u.station_id)))
     JOIN regions r ON ((r.id = u.region_id)))
  WHERE (u.archived_at IS NULL);

CREATE OR REPLACE VIEW v_station_summary WITH (security_invoker = true) AS
 SELECT s.id AS station_id,
    s.station_name,
    s.normalized_name,
    s.region_id,
    r.code AS region_code,
    r.name AS region_name,
    r.sort_order AS region_sort_order,
    s.bay_status,
    s.bay_status_raw,
    s.notes,
    s.needs_review,
    s.review_reason,
    s.archived_at,
    ( SELECT count(*) AS count
           FROM units u
          WHERE u.archived_at IS NULL AND (((u.station_id = s.id) AND (u.archived_at IS NULL)))) AS units,
    ((((((( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND ((v.station_id = s.id))) + ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND ((sv.station_id = s.id)))) + ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND ((rt.station_id = s.id)))) + ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND ((g.station_id = s.id)))) + ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND ((h.station_id = s.id)))) + ( SELECT count(*) AS count
           FROM compressors c
          WHERE c.archived_at IS NULL AND ((c.station_id = s.id)))) + ( SELECT count(*) AS count
           FROM dispensers d
          WHERE d.archived_at IS NULL AND ((d.station_id = s.id)))) AS assets,
    ((((( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND (((v.station_id = s.id) AND (cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue'::due_status)))) + ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND (((sv.station_id = s.id) AND (cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND (((rt.station_id = s.id) AND (cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND (((g.station_id = s.id) AND (cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue'::due_status))))) + ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND (((h.station_id = s.id) AND (cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue'::due_status))))) AS overdue,
    ((((( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND (((v.station_id = s.id) AND (cng_due_status(v.next_calibration_date, v.next_calibration_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status]))))) + ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND (((sv.station_id = s.id) AND (cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status])))))) + ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND (((rt.station_id = s.id) AND (cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status])))))) + ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND (((g.station_id = s.id) AND (cng_due_status(g.next_calibration_date, g.next_calibration_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status])))))) + ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND (((h.station_id = s.id) AND (cng_due_status(h.next_test_date, h.next_test_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status])))))) AS approaching_due,
    ((((( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND (((v.station_id = s.id) AND (v.mapping_status <> 'resolved'::srv_mapping_status)))) + ( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND (((sv.station_id = s.id) AND (sv.mapping_status <> 'resolved'::asset_mapping_status))))) + ( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND (((rt.station_id = s.id) AND (rt.mapping_status <> 'resolved'::asset_mapping_status))))) + ( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND (((g.station_id = s.id) AND (g.mapping_status <> 'resolved'::asset_mapping_status))))) + ( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND (((h.station_id = s.id) AND (h.mapping_status <> 'resolved'::asset_mapping_status))))) AS unresolved_mapping
   FROM (stations s
     JOIN regions r ON ((r.id = s.region_id)))
  WHERE (s.archived_at IS NULL);

CREATE OR REPLACE VIEW v_dashboard_region_summary WITH (security_invoker = true) AS
 WITH business_clock AS MATERIALIZED (
         SELECT cng_business_date() AS today
        ), station_counts AS MATERIALIZED (
         SELECT stations.region_id,
            count(*) AS stations
           FROM stations
           WHERE stations.archived_at IS NULL
          GROUP BY stations.region_id
        ), unit_counts AS MATERIALIZED (
         SELECT units.region_id,
            count(*) AS units
           FROM units
           WHERE units.archived_at IS NULL
          GROUP BY units.region_id
        ), asset_facts AS MATERIALIZED (
         SELECT installed_relief_valves.region_id,
            installed_relief_valves.next_calibration_date AS due_date,
            installed_relief_valves.next_calibration_precision AS due_precision,
            (installed_relief_valves.mapping_status)::text AS mapping_status
           FROM installed_relief_valves
           WHERE installed_relief_valves.archived_at IS NULL
        UNION ALL
         SELECT storage_vessels.region_id,
            storage_vessels.next_inspection_date,
            storage_vessels.next_inspection_precision,
            (storage_vessels.mapping_status)::text AS mapping_status
           FROM storage_vessels
           WHERE storage_vessels.archived_at IS NULL
        UNION ALL
         SELECT recovery_tanks.region_id,
            recovery_tanks.next_inspection_date,
            recovery_tanks.next_inspection_precision,
            (recovery_tanks.mapping_status)::text AS mapping_status
           FROM recovery_tanks
           WHERE recovery_tanks.archived_at IS NULL
        UNION ALL
         SELECT gas_detectors.region_id,
            gas_detectors.next_calibration_date,
            gas_detectors.next_calibration_precision,
            (gas_detectors.mapping_status)::text AS mapping_status
           FROM gas_detectors
           WHERE gas_detectors.archived_at IS NULL
        UNION ALL
         SELECT hoses.region_id,
            hoses.next_test_date,
            hoses.next_test_precision,
            (hoses.mapping_status)::text AS mapping_status
           FROM hoses
           WHERE hoses.archived_at IS NULL
        ), classified_assets AS MATERIALIZED (
         SELECT f.region_id,
            f.mapping_status,
                CASE
                    WHEN ((f.due_precision <> 'exact_date'::date_precision) OR (f.due_date IS NULL)) THEN 'unknown'::due_status
                    WHEN (f.due_date < b.today) THEN 'overdue'::due_status
                    WHEN (f.due_date = b.today) THEN 'due_today'::due_status
                    WHEN (f.due_date <= (b.today + 7)) THEN 'due_7'::due_status
                    WHEN (f.due_date <= (b.today + 15)) THEN 'due_15'::due_status
                    WHEN (f.due_date <= (b.today + 30)) THEN 'due_30'::due_status
                    WHEN (f.due_date <= (b.today + 60)) THEN 'due_60'::due_status
                    ELSE 'valid'::due_status
                END AS due_status
           FROM (asset_facts f
             CROSS JOIN business_clock b)
        ), asset_counts AS MATERIALIZED (
         SELECT classified_assets.region_id,
            count(*) AS assets,
            count(*) FILTER (WHERE (classified_assets.due_status = 'overdue'::due_status)) AS overdue,
            count(*) FILTER (WHERE (classified_assets.due_status = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status, 'due_60'::due_status]))) AS approaching_due,
            count(*) FILTER (WHERE (classified_assets.mapping_status <> 'resolved'::text)) AS unresolved_mapping
           FROM classified_assets
          GROUP BY classified_assets.region_id
        )
 SELECT r.id AS region_id,
    r.code AS region_code,
    r.name AS region_name,
    r.sort_order,
    COALESCE(sc.stations, (0)::bigint) AS stations,
    COALESCE(uc.units, (0)::bigint) AS units,
    COALESCE(ac.assets, (0)::bigint) AS assets,
    COALESCE(ac.overdue, (0)::bigint) AS overdue,
    COALESCE(ac.approaching_due, (0)::bigint) AS approaching_due,
    COALESCE(ac.unresolved_mapping, (0)::bigint) AS unresolved_mapping
   FROM (((regions r
     LEFT JOIN station_counts sc ON ((sc.region_id = r.id)))
     LEFT JOIN unit_counts uc ON ((uc.region_id = r.id)))
     LEFT JOIN asset_counts ac ON ((ac.region_id = r.id)));

CREATE OR REPLACE VIEW v_dashboard_due_summary WITH (security_invoker = true) AS
 WITH business_clock AS MATERIALIZED (
         SELECT cng_business_date() AS today
        ), due_facts AS MATERIALIZED (
         SELECT 'installed_relief_valve'::text AS asset_kind,
            installed_relief_valves.next_calibration_date AS due_date,
            installed_relief_valves.next_calibration_precision AS due_precision
           FROM installed_relief_valves
           WHERE installed_relief_valves.archived_at IS NULL
        UNION ALL
         SELECT 'storage_vessel'::text,
            storage_vessels.next_inspection_date,
            storage_vessels.next_inspection_precision
           FROM storage_vessels
           WHERE storage_vessels.archived_at IS NULL
        UNION ALL
         SELECT 'recovery_tank'::text,
            recovery_tanks.next_inspection_date,
            recovery_tanks.next_inspection_precision
           FROM recovery_tanks
           WHERE recovery_tanks.archived_at IS NULL
        UNION ALL
         SELECT 'gas_detector'::text,
            gas_detectors.next_calibration_date,
            gas_detectors.next_calibration_precision
           FROM gas_detectors
           WHERE gas_detectors.archived_at IS NULL
        UNION ALL
         SELECT 'hose'::text,
            hoses.next_test_date,
            hoses.next_test_precision
           FROM hoses
           WHERE hoses.archived_at IS NULL
        ), classified AS (
         SELECT f.asset_kind,
                CASE
                    WHEN ((f.due_precision <> 'exact_date'::date_precision) OR (f.due_date IS NULL)) THEN 'unknown'::due_status
                    WHEN (f.due_date < b.today) THEN 'overdue'::due_status
                    WHEN (f.due_date = b.today) THEN 'due_today'::due_status
                    WHEN (f.due_date <= (b.today + 7)) THEN 'due_7'::due_status
                    WHEN (f.due_date <= (b.today + 15)) THEN 'due_15'::due_status
                    WHEN (f.due_date <= (b.today + 30)) THEN 'due_30'::due_status
                    WHEN (f.due_date <= (b.today + 60)) THEN 'due_60'::due_status
                    ELSE 'valid'::due_status
                END AS due_status
           FROM (due_facts f
             CROSS JOIN business_clock b)
        )
 SELECT asset_kind,
    due_status,
    count(*) AS total
   FROM classified
  GROUP BY asset_kind, due_status;

CREATE OR REPLACE VIEW v_dashboard_asset_counts WITH (security_invoker = true) AS
 SELECT 'station'::text AS asset_kind,
    count(*) AS total
   FROM stations
   WHERE stations.archived_at IS NULL
UNION ALL
 SELECT 'unit'::text AS asset_kind,
    count(*) AS total
   FROM units
   WHERE units.archived_at IS NULL
UNION ALL
 SELECT 'compressor'::text AS asset_kind,
    count(*) AS total
   FROM compressors
   WHERE compressors.archived_at IS NULL
UNION ALL
 SELECT 'dispenser'::text AS asset_kind,
    count(*) AS total
   FROM dispensers
   WHERE dispensers.archived_at IS NULL
UNION ALL
 SELECT 'storage_vessel'::text AS asset_kind,
    count(*) AS total
   FROM storage_vessels
   WHERE storage_vessels.archived_at IS NULL
UNION ALL
 SELECT 'recovery_tank'::text AS asset_kind,
    count(*) AS total
   FROM recovery_tanks
   WHERE recovery_tanks.archived_at IS NULL
UNION ALL
 SELECT 'gas_detector'::text AS asset_kind,
    count(*) AS total
   FROM gas_detectors
   WHERE gas_detectors.archived_at IS NULL
UNION ALL
 SELECT 'hose'::text AS asset_kind,
    count(*) AS total
   FROM hoses
   WHERE hoses.archived_at IS NULL
UNION ALL
 SELECT 'installed_relief_valve'::text AS asset_kind,
    count(*) AS total
   FROM installed_relief_valves
   WHERE installed_relief_valves.archived_at IS NULL;

CREATE OR REPLACE VIEW v_data_quality_queue WITH (security_invoker = true) AS
 SELECT 'installed_relief_valve'::asset_type AS asset_type,
    v.id AS asset_id,
    v.region_id,
    v.station_id,
    v.unit_id,
    (v.mapping_status)::text AS mapping_status,
    v.needs_review,
    v.review_reason,
    v.updated_at
   FROM installed_relief_valves v
  WHERE v.archived_at IS NULL AND (((v.mapping_status <> 'resolved'::srv_mapping_status) OR v.needs_review))
UNION ALL
 SELECT 'storage_vessel'::asset_type AS asset_type,
    sv.id AS asset_id,
    sv.region_id,
    sv.station_id,
    sv.unit_id,
    (sv.mapping_status)::text AS mapping_status,
    sv.needs_review,
    sv.review_reason,
    sv.updated_at
   FROM storage_vessels sv
  WHERE sv.archived_at IS NULL AND (((sv.mapping_status <> 'resolved'::asset_mapping_status) OR sv.needs_review))
UNION ALL
 SELECT 'recovery_tank'::asset_type AS asset_type,
    rt.id AS asset_id,
    rt.region_id,
    rt.station_id,
    rt.unit_id,
    (rt.mapping_status)::text AS mapping_status,
    rt.needs_review,
    rt.review_reason,
    rt.updated_at
   FROM recovery_tanks rt
  WHERE rt.archived_at IS NULL AND (((rt.mapping_status <> 'resolved'::asset_mapping_status) OR rt.needs_review))
UNION ALL
 SELECT 'gas_detector'::asset_type AS asset_type,
    g.id AS asset_id,
    g.region_id,
    g.station_id,
    g.unit_id,
    (g.mapping_status)::text AS mapping_status,
    g.needs_review,
    g.review_reason,
    g.updated_at
   FROM gas_detectors g
  WHERE g.archived_at IS NULL AND (((g.mapping_status <> 'resolved'::asset_mapping_status) OR g.needs_review))
UNION ALL
 SELECT 'hose'::asset_type AS asset_type,
    h.id AS asset_id,
    h.region_id,
    h.station_id,
    h.unit_id,
    (h.mapping_status)::text AS mapping_status,
    h.needs_review,
    h.review_reason,
    h.updated_at
   FROM hoses h
  WHERE h.archived_at IS NULL AND (((h.mapping_status <> 'resolved'::asset_mapping_status) OR h.needs_review))
UNION ALL
 SELECT 'compressor'::asset_type AS asset_type,
    c.id AS asset_id,
    c.region_id,
    c.station_id,
    c.unit_id,
    (c.mapping_status)::text AS mapping_status,
    c.needs_review,
    c.review_reason,
    c.updated_at
   FROM compressors c
  WHERE c.archived_at IS NULL AND (((c.mapping_status <> 'resolved'::asset_mapping_status) OR c.needs_review))
UNION ALL
 SELECT 'dispenser'::asset_type AS asset_type,
    dd.id AS asset_id,
    dd.region_id,
    dd.station_id,
    dd.unit_id,
    (dd.mapping_status)::text AS mapping_status,
    dd.needs_review,
    dd.review_reason,
    dd.updated_at
   FROM dispensers dd
  WHERE dd.archived_at IS NULL AND (((dd.mapping_status <> 'resolved'::asset_mapping_status) OR dd.needs_review));
