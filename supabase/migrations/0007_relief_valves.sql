-- 0007_relief_valves.sql
-- Safety Relief Valves: installed (station assets) and warehouse (stock).
--
-- These are two physically separate datasets and are never merged. A warehouse
-- valve marked 'Sent to Station - Received' may be the same device as an
-- installed row, but proving it needs serial + station + pressure agreement;
-- such links are reported as candidates, never auto-merged.
--
-- WHY PARENTAGE IS CONDITIONAL
-- ----------------------------
-- The installed-SRV source has no Unit column and no equipment identifier: its
-- only placement evidence is Station plus a Location of 'Stage' or 'Storage'.
-- A strict "exactly one equipment parent, always" constraint would reject all
-- 2 662 safety-critical records. The constraint is therefore conditional on an
-- explicit mapping_status: the row states how far the evidence goes, and the
-- database enforces the shape that status implies.

CREATE TABLE installed_relief_valves (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- Placement. station_id is NOT NULL: a row is promoted here only once its
  -- station is confirmed through a confirmed alias. Rows whose station cannot be
  -- confirmed stay in import_issues with their full source_raw — preserved, not
  -- discarded (principle #10).
  station_id         uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id          uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id            uuid NULL,
  compressor_id      uuid NULL,
  storage_vessel_id  uuid NULL,
  dispenser_id       uuid NULL,

  mapping_status     srv_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note       text NULL,
  resolved_by        uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at        timestamptz NULL,

  -- Source evidence for the parent. location_raw is verbatim ('Stage'/'Storage');
  -- expected_parent_kind is the deterministic reading of it and is a HINT ONLY.
  -- No import path may write an equipment FK from it (CLAUDE.md §4).
  location_raw          text NULL,
  expected_parent_kind  srv_parent_kind NULL,

  tag_number         text NULL,
  manufacturer       text NULL,
  manufacturer_raw   text NULL,
  serial_number      text NULL,
  serial_number_raw  text NULL,   -- verbatim, incl. values that are really part numbers
  serial_status      serial_status NOT NULL DEFAULT 'unknown',
  part_number        text NULL,
  size_type          text NULL,
  inlet_size         text NULL,   -- '3/4"', '1/4"' — TEXT, never parsed to numeric
  outlet_size        text NULL,

  set_pressure_raw   text NULL,   -- '275 BAR', '(275-344) BAR', '5500 PSI'
  pressure_min       numeric NULL,
  pressure_max       numeric NULL,
  pressure_unit      pressure_unit NULL,   -- NULL where the source states no unit

  last_calibration_raw       text NULL,
  last_calibration_date      date NULL,
  last_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  next_calibration_raw       text NULL,
  next_calibration_date      date NULL,
  next_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw          text NULL,    -- 'منتهية' / 'شهادة المنشأ' (decision D6)

  notes              text NULL,
  import_batch_id    uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file        text NULL,
  source_sheet       text NULL,
  source_row         integer NULL,
  source_raw         jsonb NULL,
  needs_review       boolean NOT NULL DEFAULT false,
  review_reason      text NULL,

  archived_at        timestamptz NULL,
  archived_by        uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  -- === Constraint 1: shape must match mapping_status ======================
  -- Makes every unresolved state explicit and self-describing: a NULL parent is
  -- never ambiguous, because the status says whether it means "not yet mapped"
  -- or "evidence disputed". A half-mapped row can never read as resolved.
  CONSTRAINT irv_status_shape_ck CHECK (
    CASE mapping_status
      WHEN 'resolved' THEN
        unit_id IS NOT NULL
        AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 1
      WHEN 'needs_unit_mapping' THEN
        unit_id IS NULL
        AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
      WHEN 'needs_equipment_mapping' THEN
        unit_id IS NOT NULL
        AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
      WHEN 'conflict' THEN
        num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) <= 1
    END
  ),

  -- === Constraint 2: a parent must belong to the stated Unit and Station ===
  -- Composite FKs, no triggers. Under MATCH SIMPLE each is dormant while any of
  -- its columns is NULL, and enforced the moment a parent is assigned — which by
  -- Constraint 1 also means unit_id is set. The chain
  -- SRV → equipment → unit → station is therefore consistent by construction,
  -- and re-parenting a unit or a piece of equipment cannot orphan a resolved SRV.
  CONSTRAINT irv_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT irv_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT irv_compressor_unit_fk FOREIGN KEY (compressor_id, unit_id)
    REFERENCES compressors (id, unit_id) ON DELETE RESTRICT,
  CONSTRAINT irv_storage_vessel_unit_fk FOREIGN KEY (storage_vessel_id, unit_id)
    REFERENCES storage_vessels (id, unit_id) ON DELETE RESTRICT,
  CONSTRAINT irv_dispenser_unit_fk FOREIGN KEY (dispenser_id, unit_id)
    REFERENCES dispensers (id, unit_id) ON DELETE RESTRICT,

  -- Date precision
  CONSTRAINT irv_last_prec_ck CHECK ((last_calibration_precision = 'exact_date') = (last_calibration_date IS NOT NULL)),
  CONSTRAINT irv_next_prec_ck CHECK ((next_calibration_precision = 'exact_date') = (next_calibration_date IS NOT NULL)),

  -- Pressure: a range must not be inverted; a unit alone is not a value.
  CONSTRAINT irv_pressure_range_ck CHECK (
    pressure_min IS NULL OR pressure_max IS NULL OR pressure_min <= pressure_max
  ),
  CONSTRAINT irv_pressure_nonneg_ck CHECK (
    (pressure_min IS NULL OR pressure_min >= 0) AND (pressure_max IS NULL OR pressure_max >= 0)
  ),

  -- Resolution must be attributable: a resolved row records who and when.
  -- A script cannot honestly satisfy this, which is a second line of defence
  -- against an automated backfill inventing parentage.
  CONSTRAINT irv_resolved_attribution_ck CHECK (
    mapping_status <> 'resolved' OR (resolved_by IS NOT NULL AND resolved_at IS NOT NULL)
  )
);

COMMENT ON TABLE installed_relief_valves IS
  'Installed SRVs. Expected to import entirely unresolved: the source proves a station and a Stage/Storage hint, never a unit or a specific parent. Repair kits are out of scope and are not represented here or anywhere.';
COMMENT ON COLUMN installed_relief_valves.expected_parent_kind IS
  'HINT ONLY, derived from location_raw (Stage→compressor, Storage→storage_vessel). Narrows the mapping UI; must never populate compressor_id/storage_vessel_id/dispenser_id.';
COMMENT ON COLUMN installed_relief_valves.serial_number_raw IS
  'Verbatim source value, including values that are really part numbers (e.g. SS-4R3A). Never auto-relocated to part_number (prompt §18).';

-- ---------------------------------------------------------------------------
-- warehouse_relief_valves — stock, not installed equipment.
-- Belongs to no unit and never appears in the physical hierarchy.
-- target_region/target_station are the assignment destination, and are NULL for
-- ~413 rows of unassigned stock, which is valid rather than a defect.
-- ---------------------------------------------------------------------------

CREATE TABLE warehouse_relief_valves (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  availability_status warehouse_availability NOT NULL,
  availability_raw    text NULL,

  serial_number       text NULL,
  serial_number_raw   text NULL,
  serial_status       serial_status NOT NULL DEFAULT 'unknown',
  manufacturer        text NULL,
  manufacturer_raw    text NULL,
  part_number         text NULL,
  size_type           text NULL,
  inlet_size          text NULL,
  outlet_size         text NULL,

  set_pressure_raw    text NULL,
  pressure_min        numeric NULL,
  pressure_max        numeric NULL,
  pressure_unit       pressure_unit NULL,

  last_calibration_raw       text NULL,
  last_calibration_date      date NULL,
  last_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  next_calibration_raw       text NULL,
  next_calibration_date      date NULL,
  next_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw          text NULL,

  warehouse_code      text NULL,
  warehouse_issue_raw text NULL,
  warehouse_issue_date date NULL,
  warehouse_issue_precision date_precision NOT NULL DEFAULT 'unknown',
  calibration_location text NULL,

  target_region_id    uuid NULL REFERENCES regions(id) ON DELETE RESTRICT,
  target_station_id   uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,

  notes               text NULL,
  import_batch_id     uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file         text NULL,
  source_sheet        text NULL,
  source_row          integer NULL,
  source_raw          jsonb NULL,
  needs_review        boolean NOT NULL DEFAULT false,
  review_reason       text NULL,

  archived_at         timestamptz NULL,
  archived_by         uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT wrv_last_prec_ck  CHECK ((last_calibration_precision = 'exact_date') = (last_calibration_date IS NOT NULL)),
  CONSTRAINT wrv_next_prec_ck  CHECK ((next_calibration_precision = 'exact_date') = (next_calibration_date IS NOT NULL)),
  CONSTRAINT wrv_issue_prec_ck CHECK ((warehouse_issue_precision = 'exact_date') = (warehouse_issue_date IS NOT NULL)),
  CONSTRAINT wrv_pressure_range_ck CHECK (
    pressure_min IS NULL OR pressure_max IS NULL OR pressure_min <= pressure_max
  ),
  -- A target station must sit in the target region when both are stated.
  CONSTRAINT wrv_target_station_region_fk FOREIGN KEY (target_station_id, target_region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT
);

COMMENT ON TABLE warehouse_relief_valves IS
  'Warehouse SRV stock. Physically separate from installed_relief_valves and never merged on serial alone.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Unit SRV tab: resolved + needs_equipment_mapping for one unit.
CREATE INDEX irv_unit_idx ON installed_relief_valves (unit_id)
  WHERE unit_id IS NOT NULL AND archived_at IS NULL;
-- Station → unresolved SRVs (the mapping queue's primary screen).
CREATE INDEX irv_station_unresolved_idx ON installed_relief_valves (station_id)
  WHERE mapping_status <> 'resolved' AND archived_at IS NULL;
CREATE INDEX irv_station_idx  ON installed_relief_valves (station_id) WHERE archived_at IS NULL;
CREATE INDEX irv_region_idx   ON installed_relief_valves (region_id);
CREATE INDEX irv_mapping_idx  ON installed_relief_valves (mapping_status);
-- Mapping UI filters by expected parent kind within a region/station.
CREATE INDEX irv_expected_kind_idx ON installed_relief_valves (expected_parent_kind)
  WHERE mapping_status <> 'resolved';
-- Search by serial / manufacturer / pressure in SRV Management.
CREATE INDEX irv_serial_idx       ON installed_relief_valves (serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX irv_manufacturer_idx ON installed_relief_valves (manufacturer);
CREATE INDEX irv_pressure_idx     ON installed_relief_valves (pressure_min, pressure_unit);
-- Alert scanning: only exact-precision due dates can generate an alert.
CREATE INDEX irv_due_idx ON installed_relief_valves (next_calibration_date)
  WHERE next_calibration_precision = 'exact_date' AND archived_at IS NULL;
-- Equipment back-references, for "which SRVs hang off this compressor".
CREATE INDEX irv_compressor_idx ON installed_relief_valves (compressor_id) WHERE compressor_id IS NOT NULL;
CREATE INDEX irv_vessel_idx     ON installed_relief_valves (storage_vessel_id) WHERE storage_vessel_id IS NOT NULL;
CREATE INDEX irv_dispenser_idx  ON installed_relief_valves (dispenser_id) WHERE dispenser_id IS NOT NULL;

CREATE INDEX wrv_serial_idx       ON warehouse_relief_valves (serial_number) WHERE serial_number IS NOT NULL;
CREATE INDEX wrv_availability_idx ON warehouse_relief_valves (availability_status);
CREATE INDEX wrv_code_idx         ON warehouse_relief_valves (warehouse_code);
CREATE INDEX wrv_target_idx       ON warehouse_relief_valves (target_station_id) WHERE target_station_id IS NOT NULL;
CREATE INDEX wrv_due_idx          ON warehouse_relief_valves (next_calibration_date)
  WHERE next_calibration_precision = 'exact_date' AND archived_at IS NULL;

CREATE TRIGGER irv_set_updated_at BEFORE UPDATE ON installed_relief_valves
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER wrv_set_updated_at BEFORE UPDATE ON warehouse_relief_valves
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
