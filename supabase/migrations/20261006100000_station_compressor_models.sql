-- 20261006100000_station_compressor_models.sql — filter Stations by compressor type (owner request 2026-10-06).
--
-- v_station_summary restated verbatim (production md5 c9d33dd1..., identical to 20261001130000) with ONE column
-- APPENDED: compressor_models text[] — the distinct compressor models of the Station's live compressors, trimmed and
-- upper-cased, so spellings that differ only in letter case ("KWANGSHIN", "kwangshin") are one value. That fold is the
-- only normalization: different words ("GALILEO", "GALLILEO", "GRAF MOTOR") stay different. A compressor with no
-- model adds nothing; a Station with none has an empty array (never NULL), so "all except" keeps it.
-- No table, grant or policy changes; security_invoker restated (CREATE OR REPLACE VIEW does not keep reloptions).

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
          WHERE h.archived_at IS NULL AND h.station_id = s.id AND h.mapping_status <> 'resolved'::asset_mapping_status)) AS unresolved_mapping,
    COALESCE(( SELECT array_agg(DISTINCT upper(btrim(c.model)) ORDER BY upper(btrim(c.model)))
           FROM compressors c
          WHERE c.archived_at IS NULL AND c.station_id = s.id AND NULLIF(btrim(c.model), '') IS NOT NULL), '{}'::text[]) AS compressor_models
   FROM stations s
     JOIN regions r ON r.id = s.region_id
  WHERE s.archived_at IS NULL;

COMMENT ON COLUMN v_station_summary.compressor_models IS 'Distinct models of the Station''s live compressors, trimmed and upper-cased (case is the only fold); empty when none is recorded.';
