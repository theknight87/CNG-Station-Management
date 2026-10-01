-- Owner request 2026-10-01 ("خليها اقل من 30 days مش 60 ... على كله"): the "approaching due" / "needs attention"
-- window is 30 days everywhere, not 60 — Stations, Regions, the dashboard, warehouse stock and hoses.
-- (Installed SRVs were moved to 30 days in 20261001110000.)
--
-- Each view below is its current definition with ONE change: 'due_60' removed from the attention / approaching_due
-- status list. The due_60 STATUS itself is unchanged (cng_due_status, reports, alert thresholds still use it), and
-- v_dashboard_due_summary — a per-status distribution, not a window — is untouched.
-- Generated from pg_get_viewdef of a database built from the migrations; no attention list contains 'due_60' (the
-- region view still CLASSIFIES 31–60 days as due_60, it just no longer counts it as approaching).
-- No table, grant or policy changes; security_invoker restated (Prompt 19B).

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
          WHERE u.archived_at IS NULL AND u.station_id = s.id AND u.archived_at IS NULL) AS units,
    (( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND v.station_id = s.id)) + (( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND sv.station_id = s.id)) + (( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND rt.station_id = s.id)) + (( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND g.station_id = s.id)) + (( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND h.station_id = s.id)) + (( SELECT count(*) AS count
           FROM compressors c
          WHERE c.archived_at IS NULL AND c.station_id = s.id)) + (( SELECT count(*) AS count
           FROM dispensers d
          WHERE d.archived_at IS NULL AND d.station_id = s.id)) AS assets,
    (( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND v.station_id = s.id AND cng_due_status(v.next_calibration_date, v.next_calibration_precision) = 'overdue'::due_status)) + (( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND sv.station_id = s.id AND cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = 'overdue'::due_status)) + (( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND rt.station_id = s.id AND cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = 'overdue'::due_status)) + (( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND g.station_id = s.id AND cng_due_status(g.next_calibration_date, g.next_calibration_precision) = 'overdue'::due_status)) + (( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND h.station_id = s.id AND cng_due_status(h.next_test_date, h.next_test_precision) = 'overdue'::due_status)) AS overdue,
    (( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND v.station_id = s.id AND (cng_due_status(v.next_calibration_date, v.next_calibration_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])))) + (( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND sv.station_id = s.id AND (cng_due_status(sv.next_inspection_date, sv.next_inspection_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])))) + (( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND rt.station_id = s.id AND (cng_due_status(rt.next_inspection_date, rt.next_inspection_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])))) + (( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND g.station_id = s.id AND (cng_due_status(g.next_calibration_date, g.next_calibration_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])))) + (( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND h.station_id = s.id AND (cng_due_status(h.next_test_date, h.next_test_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])))) AS approaching_due,
    (( SELECT count(*) AS count
           FROM installed_relief_valves v
          WHERE v.archived_at IS NULL AND v.station_id = s.id AND v.mapping_status <> 'resolved'::srv_mapping_status)) + (( SELECT count(*) AS count
           FROM storage_vessels sv
          WHERE sv.archived_at IS NULL AND sv.station_id = s.id AND sv.mapping_status <> 'resolved'::asset_mapping_status)) + (( SELECT count(*) AS count
           FROM recovery_tanks rt
          WHERE rt.archived_at IS NULL AND rt.station_id = s.id AND rt.mapping_status <> 'resolved'::asset_mapping_status)) + (( SELECT count(*) AS count
           FROM gas_detectors g
          WHERE g.archived_at IS NULL AND g.station_id = s.id AND g.mapping_status <> 'resolved'::asset_mapping_status)) + (( SELECT count(*) AS count
           FROM hoses h
          WHERE h.archived_at IS NULL AND h.station_id = s.id AND h.mapping_status <> 'resolved'::asset_mapping_status)) AS unresolved_mapping
   FROM stations s
     JOIN regions r ON r.id = s.region_id
  WHERE s.archived_at IS NULL;

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
            installed_relief_valves.mapping_status::text AS mapping_status
           FROM installed_relief_valves
          WHERE installed_relief_valves.archived_at IS NULL
        UNION ALL
         SELECT storage_vessels.region_id,
            storage_vessels.next_inspection_date,
            storage_vessels.next_inspection_precision,
            storage_vessels.mapping_status::text AS mapping_status
           FROM storage_vessels
          WHERE storage_vessels.archived_at IS NULL
        UNION ALL
         SELECT recovery_tanks.region_id,
            recovery_tanks.next_inspection_date,
            recovery_tanks.next_inspection_precision,
            recovery_tanks.mapping_status::text AS mapping_status
           FROM recovery_tanks
          WHERE recovery_tanks.archived_at IS NULL
        UNION ALL
         SELECT gas_detectors.region_id,
            gas_detectors.next_calibration_date,
            gas_detectors.next_calibration_precision,
            gas_detectors.mapping_status::text AS mapping_status
           FROM gas_detectors
          WHERE gas_detectors.archived_at IS NULL
        UNION ALL
         SELECT hoses.region_id,
            hoses.next_test_date,
            hoses.next_test_precision,
            hoses.mapping_status::text AS mapping_status
           FROM hoses
          WHERE hoses.archived_at IS NULL
        ), classified_assets AS MATERIALIZED (
         SELECT f.region_id,
            f.mapping_status,
                CASE
                    WHEN f.due_precision <> 'exact_date'::date_precision OR f.due_date IS NULL THEN 'unknown'::due_status
                    WHEN f.due_date < b.today THEN 'overdue'::due_status
                    WHEN f.due_date = b.today THEN 'due_today'::due_status
                    WHEN f.due_date <= (b.today + 7) THEN 'due_7'::due_status
                    WHEN f.due_date <= (b.today + 15) THEN 'due_15'::due_status
                    WHEN f.due_date <= (b.today + 30) THEN 'due_30'::due_status
                    WHEN f.due_date <= (b.today + 60) THEN 'due_60'::due_status
                    ELSE 'valid'::due_status
                END AS due_status
           FROM asset_facts f
             CROSS JOIN business_clock b
        ), asset_counts AS MATERIALIZED (
         SELECT classified_assets.region_id,
            count(*) AS assets,
            count(*) FILTER (WHERE classified_assets.due_status = 'overdue'::due_status) AS overdue,
            count(*) FILTER (WHERE classified_assets.due_status = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])) AS approaching_due,
            count(*) FILTER (WHERE classified_assets.mapping_status <> 'resolved'::text) AS unresolved_mapping
           FROM classified_assets
          GROUP BY classified_assets.region_id
        )
 SELECT r.id AS region_id,
    r.code AS region_code,
    r.name AS region_name,
    r.sort_order,
    COALESCE(sc.stations, 0::bigint) AS stations,
    COALESCE(uc.units, 0::bigint) AS units,
    COALESCE(ac.assets, 0::bigint) AS assets,
    COALESCE(ac.overdue, 0::bigint) AS overdue,
    COALESCE(ac.approaching_due, 0::bigint) AS approaching_due,
    COALESCE(ac.unresolved_mapping, 0::bigint) AS unresolved_mapping
   FROM regions r
     LEFT JOIN station_counts sc ON sc.region_id = r.id
     LEFT JOIN unit_counts uc ON uc.region_id = r.id
     LEFT JOIN asset_counts ac ON ac.region_id = r.id;

CREATE OR REPLACE VIEW v_dashboard_warehouse_summary WITH (security_invoker = true) AS
 SELECT count(*) AS total,
    count(*) FILTER (WHERE cng_due_status(next_calibration_date, next_calibration_precision) = 'overdue'::due_status) AS overdue,
    count(*) FILTER (WHERE cng_due_status(next_calibration_date, next_calibration_precision) = ANY (ARRAY['due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status])) AS approaching_due
   FROM warehouse_relief_valves w;

CREATE OR REPLACE VIEW v_hose_summary WITH (security_invoker = true) AS
 WITH classified AS (
         SELECT h.id,
            h.mapping_status,
            h.serial_number,
            count(*) FILTER (WHERE h.serial_number IS NOT NULL) OVER (PARTITION BY h.serial_number) > 1 AS serial_duplicate,
            cng_due_status(h.next_test_date, h.next_test_precision) AS due_status
           FROM hoses h
          WHERE h.archived_at IS NULL
        )
 SELECT count(*)::integer AS total,
    count(*) FILTER (WHERE due_status = 'overdue'::due_status)::integer AS overdue,
    count(*) FILTER (WHERE due_status = ANY (ARRAY['overdue'::due_status, 'due_today'::due_status, 'due_7'::due_status, 'due_15'::due_status, 'due_30'::due_status]))::integer AS attention,
    count(*) FILTER (WHERE mapping_status = 'needs_unit_mapping'::asset_mapping_status)::integer AS needs_unit_mapping,
    count(*) FILTER (WHERE due_status = 'unknown'::due_status)::integer AS unknown_date,
    count(*) FILTER (WHERE serial_number IS NULL)::integer AS serial_missing,
    count(*) FILTER (WHERE serial_number IS NOT NULL AND serial_duplicate)::integer AS serial_duplicate
   FROM classified;
