-- ---------------------------------------------------------------------------
-- 0030 — v_hose_registry (Prompt 14)
--
-- Additive only. `v_hose_management` (0011) is unchanged and still serves the
-- Prompt-10 Unit Hoses tab; this view adds ONE derived column that cannot be
-- computed correctly anywhere else.
--
-- WHY A VIEW IS GENUINELY REQUIRED. A hose is an individually traceable item,
-- so a duplicated serial is an operational data-quality condition worth
-- surfacing. Detecting it needs a window function over the whole visible set:
-- a paged client sees 50 rows at a time and cannot know that row 12 on page 1
-- shares a serial with row 3 on page 2. Doing it client-side would require
-- fetching every hose, which is exactly what the registry must not do.
--
-- RLS SEMANTICS OF `serial_duplicate` — read this before changing it.
--
-- The view is `security_invoker`, so the window function runs over the rows
-- THE CALLER MAY SEE. A duplicate is therefore reported only when both copies
-- are inside the caller's authorized regions. That is deliberate and it is the
-- non-leaking behaviour: if an East engineer's hose shared a serial with a West
-- hose, reporting "duplicate" to that engineer would disclose the existence of
-- a West record they have no right to know about. A narrower, honest signal is
-- correct here; a complete one would be a leak.
--
-- NULL serials are NOT duplicates of one another. Several hoses with no
-- recorded serial are several unknowns, not one repeated value (principle #16:
-- repeated values are not duplicates without supporting evidence). `missing`
-- and `duplicate` are separate conditions and are never conflated.
--
-- No UNIQUE constraint is added on `serial_number`. Uniqueness is operationally
-- desirable but the source does not prove it, and a constraint would reject
-- valid historical rows at the Prompt-21 import. The condition is REPORTED,
-- never enforced, and never silently repaired.
-- ---------------------------------------------------------------------------

CREATE VIEW v_hose_registry
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
  -- Two distinct identity conditions, never merged into one "bad serial" flag.
  (h.serial_number IS NULL) AS serial_missing,
  (h.serial_number IS NOT NULL
   AND count(*) FILTER (WHERE h.serial_number IS NOT NULL)
         OVER (PARTITION BY h.serial_number) > 1) AS serial_duplicate,
  h.working_pressure_raw, h.working_pressure_value, h.working_pressure_unit,
  h.test_pressure_raw,    h.test_pressure_value,    h.test_pressure_unit,
  -- The schema calls this a TEST, not a calibration. The wording is preserved
  -- exactly; see docs/hoses-management.md §"Terminology".
  h.last_test_date, h.last_test_precision,
  cng_date_display(h.last_test_date, h.last_test_precision, h.last_test_raw) AS last_test_display,
  h.next_test_date, h.next_test_precision,
  cng_date_display(h.next_test_date, h.next_test_precision, h.next_test_raw) AS next_test_display,
  cng_days_left(h.next_test_date, h.next_test_precision)  AS days_left,
  cng_due_status(h.next_test_date, h.next_test_precision) AS due_status,
  h.source_status_raw, h.needs_review, h.notes,
  h.source_file, h.source_sheet, h.source_row
FROM hoses h
JOIN regions r  ON r.id = h.region_id
JOIN stations s ON s.id = h.station_id
LEFT JOIN units u      ON u.id = h.unit_id
LEFT JOIN dispensers d ON d.id = h.dispenser_id
WHERE h.archived_at IS NULL;

COMMENT ON VIEW v_hose_registry IS
  'Company-wide hose registry. Adds serial_missing and serial_duplicate to v_hose_management. serial_duplicate is computed under the caller''s RLS, so it reports only duplicates the caller may already see — a wider signal would disclose out-of-region records. NULL serials are never duplicates of one another.';

-- Read-only, and only for signed-in users. `anon` receives nothing.
GRANT SELECT ON v_hose_registry TO authenticated;
