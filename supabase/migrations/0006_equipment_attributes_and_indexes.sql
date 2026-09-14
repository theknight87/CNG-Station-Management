-- 0006_equipment_attributes_and_indexes.sql
-- Unit-level reported attributes, equipment indexes and updated_at triggers.

-- ---------------------------------------------------------------------------
-- Reported counts live on the unit, NOT as generated asset rows.
--
-- `Station data base.xlsx` reports "No. Of Dispensers", "No. Of Hoses",
-- "No. Of Storage". 36 / 47 / 1 of those cells are non-numeric, so each keeps a
-- *_raw text column and a nullable integer. A count is evidence about a unit; it
-- never manufactures individual assets (prompt §10).
-- ---------------------------------------------------------------------------

ALTER TABLE units
  ADD COLUMN dispenser_count_reported integer NULL,
  ADD COLUMN dispenser_count_raw      text NULL,
  ADD COLUMN hose_count_reported      integer NULL,
  ADD COLUMN hose_count_raw           text NULL,
  ADD COLUMN storage_count_reported   integer NULL,
  ADD COLUMN storage_count_raw        text NULL,
  ADD COLUMN bay_status               bay_status NULL,
  ADD COLUMN bay_status_raw           text NULL,
  ADD CONSTRAINT units_dispenser_count_ck CHECK (dispenser_count_reported IS NULL OR dispenser_count_reported >= 0),
  ADD CONSTRAINT units_hose_count_ck      CHECK (hose_count_reported IS NULL OR hose_count_reported >= 0),
  ADD CONSTRAINT units_storage_count_ck   CHECK (storage_count_reported IS NULL OR storage_count_reported >= 0);

COMMENT ON COLUMN units.hose_count_reported IS
  'Reported count from the source. NOT a count of rows in hoses — hose assets exist for 3 stations only.';

-- ---------------------------------------------------------------------------
-- Indexes
--
-- Each index below serves a named query. Nothing speculative.
-- ---------------------------------------------------------------------------

-- Unit → Equipment (the unit detail tabs)
CREATE INDEX compressors_unit_idx      ON compressors (unit_id)      WHERE archived_at IS NULL;
CREATE INDEX recovery_tanks_unit_idx   ON recovery_tanks (unit_id)   WHERE archived_at IS NULL;
CREATE INDEX storage_vessels_unit_idx  ON storage_vessels (unit_id)  WHERE archived_at IS NULL;
CREATE INDEX dispensers_unit_idx       ON dispensers (unit_id)       WHERE archived_at IS NULL;
CREATE INDEX gas_detectors_unit_idx    ON gas_detectors (unit_id)    WHERE archived_at IS NULL;
CREATE INDEX hoses_unit_idx            ON hoses (unit_id)            WHERE archived_at IS NULL;

-- Station → Equipment (station overview, and the unit-unknown backlog)
CREATE INDEX compressors_station_idx     ON compressors (station_id)     WHERE archived_at IS NULL;
CREATE INDEX recovery_tanks_station_idx  ON recovery_tanks (station_id)  WHERE archived_at IS NULL;
CREATE INDEX storage_vessels_station_idx ON storage_vessels (station_id) WHERE archived_at IS NULL;
CREATE INDEX dispensers_station_idx      ON dispensers (station_id)      WHERE archived_at IS NULL;
CREATE INDEX gas_detectors_station_idx   ON gas_detectors (station_id)   WHERE archived_at IS NULL;
CREATE INDEX hoses_station_idx           ON hoses (station_id)           WHERE archived_at IS NULL;

-- Region scoping for RLS predicates and regional management filters
CREATE INDEX compressors_region_idx     ON compressors (region_id);
CREATE INDEX recovery_tanks_region_idx  ON recovery_tanks (region_id);
CREATE INDEX storage_vessels_region_idx ON storage_vessels (region_id);
CREATE INDEX dispensers_region_idx      ON dispensers (region_id);
CREATE INDEX gas_detectors_region_idx   ON gas_detectors (region_id);
CREATE INDEX hoses_region_idx           ON hoses (region_id);

-- Serial lookup (management search boxes). Partial: most rows have no serial.
CREATE INDEX storage_vessels_serial_idx ON storage_vessels (serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX recovery_tanks_serial_idx  ON recovery_tanks (serial_number)  WHERE serial_number IS NOT NULL;
CREATE INDEX gas_detectors_serial_idx   ON gas_detectors (serial_number)   WHERE serial_number IS NOT NULL;
CREATE INDEX hoses_serial_idx           ON hoses (serial_number)           WHERE serial_number IS NOT NULL;
CREATE INDEX dispensers_serial_idx      ON dispensers (serial_number)      WHERE serial_number IS NOT NULL;

-- Due-date scanning for the alert engine. Partial on exact precision: only those
-- rows can ever produce an alert, and this keeps the index small.
CREATE INDEX storage_vessels_due_idx ON storage_vessels (next_inspection_date)
  WHERE next_inspection_precision = 'exact_date' AND archived_at IS NULL;
CREATE INDEX recovery_tanks_due_idx  ON recovery_tanks (next_inspection_date)
  WHERE next_inspection_precision = 'exact_date' AND archived_at IS NULL;
CREATE INDEX gas_detectors_due_idx   ON gas_detectors (next_calibration_date)
  WHERE next_calibration_precision = 'exact_date' AND archived_at IS NULL;
CREATE INDEX hoses_due_idx           ON hoses (next_test_date)
  WHERE next_test_precision = 'exact_date' AND archived_at IS NULL;

-- Data Quality queues: everything not yet resolved.
CREATE INDEX compressors_mapping_idx     ON compressors (mapping_status)     WHERE mapping_status <> 'resolved';
CREATE INDEX recovery_tanks_mapping_idx  ON recovery_tanks (mapping_status)  WHERE mapping_status <> 'resolved';
CREATE INDEX storage_vessels_mapping_idx ON storage_vessels (mapping_status) WHERE mapping_status <> 'resolved';
CREATE INDEX dispensers_mapping_idx      ON dispensers (mapping_status)      WHERE mapping_status <> 'resolved';
CREATE INDEX gas_detectors_mapping_idx   ON gas_detectors (mapping_status)   WHERE mapping_status <> 'resolved';
CREATE INDEX hoses_mapping_idx           ON hoses (mapping_status)           WHERE mapping_status <> 'resolved';

CREATE INDEX gdp_station_idx  ON gas_detector_presence (station_id);
CREATE INDEX gdp_presence_idx ON gas_detector_presence (detector_presence);

-- updated_at triggers
CREATE TRIGGER compressors_set_updated_at BEFORE UPDATE ON compressors
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER recovery_tanks_set_updated_at BEFORE UPDATE ON recovery_tanks
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER storage_vessels_set_updated_at BEFORE UPDATE ON storage_vessels
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER dispensers_set_updated_at BEFORE UPDATE ON dispensers
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER gas_detectors_set_updated_at BEFORE UPDATE ON gas_detectors
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER gas_detector_presence_set_updated_at BEFORE UPDATE ON gas_detector_presence
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER hoses_set_updated_at BEFORE UPDATE ON hoses
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
