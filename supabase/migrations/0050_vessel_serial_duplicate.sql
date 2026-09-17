-- 0050_vessel_serial_duplicate.sql
-- Duplicate-serial VISIBILITY for vessels (Prompt 24B).
--
-- WHY. Prompt 24A found 16 storage vessels forming 8 repeated-serial pairs in
-- production and surfaced NOWHERE in the product. Data principle 16 requires
-- duplicate candidates to be REPORTED — never merged, never discarded. Hoses
-- have had exactly this since 0030; vessels did not, because Prompt 14 built
-- the registry around identity for hoses alone.
--
-- THIS IS THE HOSE PATTERN, REUSED — NOT A SECOND ARCHITECTURE. Same window
-- function, same two-distinct-conditions rule, same RLS semantics, same naming
-- (`serial_missing`, `serial_duplicate`). The only additions are
-- `serial_duplicate_count`, which tells a reviewer how many records share the
-- serial without making them page for it, and partitioning by `asset_type`.
--
-- PARTITIONED BY asset_type, DELIBERATELY. This view UNIONs two DIFFERENT
-- physical entities (CLAUDE.md section 5: their tables are never merged). A
-- storage vessel and a recovery tank that happen to share a serial are not the
-- same duplicate condition, and flagging them as one would assert a
-- relationship between two distinct equipment types that nothing proves.
-- Measured on production this changes nothing today — all 8 groups are storage
-- vessels — but it is the correct rule rather than the one that happens to fit.
--
-- IT REPORTS, IT NEVER CONCLUDES. `serial_duplicate` says "more than one record
-- carries this serial". It does NOT say either record is wrong, invalid, or a
-- copy. Production evidence supports that restraint directly: all 8 groups come
-- from DISTINCT source rows with byte-identical raw serials, so they are 8
-- pairs of separately recorded assets, not one row imported twice. Six identical
-- vessels on one Station may be six real devices.
--
-- RLS SEMANTICS, INHERITED FROM 0030 AND NOT WEAKENED. The view stays
-- `security_invoker`, so the window function runs over the rows THE CALLER MAY
-- SEE. A duplicate is reported only when both copies are inside the caller's
-- authorized Regions — a wider signal would disclose the existence of a row in
-- a Region the caller may not read. Measured: all 8 groups are same-Region, so
-- no admin-visible duplicate is hidden from the Region's own engineer today.
--
-- NULL AND BLANK SERIALS ARE NEVER DUPLICATES OF ONE ANOTHER. "Unknown" is not
-- a value two assets can share; `serial_missing` is its own separate condition.
--
-- BLANK IS TREATED AS ABSENT, and that is not a cosmetic detail: the first
-- draft of this view tested `IS NOT NULL` alone, and a regression test caught
-- two blank-serial vessels being reported as a duplicate PAIR — the system
-- asserting a shared identity between two assets whose serial is simply
-- unrecorded. `nullif(btrim(...), '')` is the project's existing rule for this
-- (`ValueOrNull`: "a blank source cell and a NULL are the same fact").
--
-- THE COLUMNS ARE APPENDED AT THE END, deliberately. `v_report_due_compliance`
-- depends on this view, so DROP is not available, and CREATE OR REPLACE VIEW
-- may only add columns after the existing ones. The dependent view is untouched.
--
-- `WITH (security_invoker = true)` IS RESTATED, NOT ASSUMED. CREATE OR REPLACE
-- VIEW does NOT preserve reloptions — that is exactly the Prompt 19B defect,
-- where a replaced view silently became owner-rights and bypassed the RLS meant
-- to bound it. VIEWSEC-ALL asserts this from the catalog.
--
-- NO DATA IS CHANGED. No row is created, updated, deleted, merged or
-- deduplicated; no serial is altered. This migration contains no DML at all.

CREATE OR REPLACE VIEW v_vessel_management
WITH (security_invoker = true) AS
WITH vessels AS (
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
  WHERE rt.archived_at IS NULL
)
SELECT
  v.asset_type, v.id,
  v.region_id, v.region_name, v.station_id, v.station_name, v.unit_id, v.unit_name,
  v.mapping_status, v.needs_mapping,
  v.manufacturer, v.model, v.serial_number, v.serial_number_raw, v.serial_status,
  v.compressor_type_raw,
  v.last_inspection_date, v.last_inspection_precision, v.last_inspection_display,
  v.next_inspection_date, v.next_inspection_precision, v.next_inspection_display,
  v.days_left, v.due_status,
  v.source_status_raw, v.needs_review, v.notes, v.created_at, v.updated_at,
  -- Appended columns. Two conditions kept separate, never merged into one
  -- "bad serial" flag: a missing serial and a repeated serial are different
  -- facts needing different human responses.
  (nullif(btrim(v.serial_number), '') IS NULL) AS serial_missing,
  (nullif(btrim(v.serial_number), '') IS NOT NULL
   AND count(*) FILTER (WHERE nullif(btrim(v.serial_number), '') IS NOT NULL)
         OVER (PARTITION BY v.asset_type, nullif(btrim(v.serial_number), '')) > 1) AS serial_duplicate,
  -- How many records share this serial, for the reviewer. NULL where the
  -- question does not apply, so it never reads as "1 of something".
  (CASE WHEN nullif(btrim(v.serial_number), '') IS NOT NULL
        THEN count(*) FILTER (WHERE nullif(btrim(v.serial_number), '') IS NOT NULL)
               OVER (PARTITION BY v.asset_type, nullif(btrim(v.serial_number), ''))
   END)::integer AS serial_duplicate_count
FROM vessels v;

COMMENT ON VIEW v_vessel_management IS
  'Storage vessels and recovery tanks unioned for the global Vessels module. '
  'Their physical tables are NOT merged — asset_type distinguishes two different '
  'equipment entities, and serial_duplicate is partitioned by asset_type for the '
  'same reason. serial_duplicate REPORTS that more than one record carries a '
  'serial; it never concludes that either record is wrong, and nothing is '
  'deduplicated (data principle 16). Computed under the caller''s RLS, so it '
  'reports only duplicates the caller may already see. NULL serials are never '
  'duplicates of one another.';
