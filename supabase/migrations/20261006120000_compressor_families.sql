-- 20261006120000_compressor_families.sql — compressor families for the Stations filter (owner ruling 2026-10-06).
--
-- "عايز اوحد الانواع": the Compressor filter offers one choice per FAMILY, all in capitals. The owner's rulings, exactly:
--   FORNOVO  — every FORNOVO model (FORNOVO, FORNOVO 3 BAR, FORNOVO 30 BAR …) is one family;
--   CUBO     — CUBOGAS is CUBO;
--   GRAF     — every GRAF model (GRAF, GRAF MOTOR, GRAF ENGINE, GRAF ELEC. MOTOR …) is one family;
--   GALILEO  — GALLILEO is GALILEO;
--   anything else is its own family, trimmed and upper-cased.
-- The recorded models are NOT changed: compressors.model keeps every spelling and v_station_summary.compressor_models
-- (the Stations table's Compressor column) still lists them. Only the filter groups them.
--
-- (1) cng_compressor_family(text): IMMUTABLE SQL, no table access, no SET (so it inlines); NULL/blank -> NULL.
-- (2) v_station_summary restated verbatim from 20261006100000 with ONE column APPENDED: compressor_families text[]
--     (distinct families of the Station's live compressors; '{}' when none). security_invoker restated.

CREATE OR REPLACE FUNCTION cng_compressor_family(p_model text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT CASE
           WHEN m IS NULL THEN NULL
           WHEN m LIKE 'FORNOVO%' THEN 'FORNOVO'
           WHEN m LIKE 'GRAF%' THEN 'GRAF'
           WHEN m IN ('CUBO', 'CUBOGAS') THEN 'CUBO'
           WHEN m IN ('GALILEO', 'GALLILEO') THEN 'GALILEO'
           ELSE m
         END
    FROM (SELECT nullif(pg_catalog.upper(pg_catalog.btrim(p_model)), '') AS m) x
$$;
COMMENT ON FUNCTION cng_compressor_family(text) IS
  'Owner ruling 2026-10-06: the compressor family a model belongs to, for the Stations filter (FORNOVO*, GRAF*, CUBO/CUBOGAS, GALILEO/GALLILEO; anything else upper-cased). Never written back to compressors.model.';
REVOKE ALL ON FUNCTION cng_compressor_family(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_compressor_family(text) TO authenticated;

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
          WHERE c.archived_at IS NULL AND c.station_id = s.id AND NULLIF(btrim(c.model), '') IS NOT NULL), '{}'::text[]) AS compressor_models,
    COALESCE(( SELECT array_agg(DISTINCT cng_compressor_family(c.model) ORDER BY cng_compressor_family(c.model))
           FROM compressors c
          WHERE c.archived_at IS NULL AND c.station_id = s.id AND NULLIF(btrim(c.model), '') IS NOT NULL), '{}'::text[]) AS compressor_families
   FROM stations s
     JOIN regions r ON r.id = s.region_id
  WHERE s.archived_at IS NULL;

COMMENT ON COLUMN v_station_summary.compressor_families IS 'Distinct compressor families of the Station''s live compressors (cng_compressor_family, owner ruling 2026-10-06), for the Stations filter; empty when none is recorded.';
