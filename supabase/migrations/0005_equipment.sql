-- 0005_equipment.sql
-- Unit-scoped equipment: compressors, recovery tanks, storage vessels,
-- dispensers, gas detectors (+ presence evidence), hoses.
--
-- THE UNIT-UNKNOWN PATTERN (decision D7)
-- --------------------------------------
-- There is no one-unit-per-station fallback. Where a source proves a Station but
-- not a Unit, the asset is still a first-class record:
--
--     station_id  NOT NULL   -- proven
--     region_id   NOT NULL   -- proven, kept consistent by composite FK
--     unit_id     NULL       -- unknown until a human maps it
--     mapping_status          -- 'resolved' requires unit_id
--
-- Two composite foreign keys keep the hierarchy honest without any trigger:
--   (station_id, region_id) -> stations (id, region_id)
--   (unit_id,    station_id) -> units   (id, station_id)
-- Under MATCH SIMPLE the second is dormant while unit_id IS NULL, and enforced
-- the moment a unit is assigned. A unit can therefore never be attached from a
-- different station, and re-parenting a unit cannot orphan its assets.
--
-- DATE TRIPLES
-- ------------
-- Every inspection/calibration date is (raw TEXT, date DATE, precision).
-- The CHECK `(precision = 'exact_date') = (date IS NOT NULL)` makes it
-- impossible to store a date without exact precision, or claim exact precision
-- with no date. A bare '2021' is precision year_only, date NULL, raw '2021'.

-- ---------------------------------------------------------------------------
-- compressors
-- ---------------------------------------------------------------------------

CREATE TABLE compressors (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id                uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id                 uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id                   uuid NULL,
  mapping_status            asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note              text NULL,

  manufacturer              text NULL,
  manufacturer_raw          text NULL,
  model                     text NULL,
  model_raw                 text NULL,
  job_number                text NULL,          -- TEXT, nullable, not a key
  serial_number             text NULL,
  serial_number_raw         text NULL,
  serial_status             serial_status NOT NULL DEFAULT 'unknown',
  part_number               text NULL,

  total_running_hours       numeric NULL,
  average_hours_per_day     numeric NULL,
  average_gas_sales_per_day numeric NULL,
  average_gas_sales_raw     text NULL,          -- 3 source rows hold text here

  notes                     text NULL,
  source_status_raw         text NULL,

  import_batch_id           uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file               text NULL,
  source_sheet              text NULL,
  source_row                integer NULL,
  source_raw                jsonb NULL,
  needs_review              boolean NOT NULL DEFAULT false,
  review_reason             text NULL,

  resolved_by               uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at               timestamptz NULL,
  archived_at               timestamptz NULL,
  archived_by               uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT compressors_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT compressors_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT compressors_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT compressors_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  -- Composite target so an SRV can prove its compressor belongs to its unit.
  CONSTRAINT compressors_id_unit_uq UNIQUE (id, unit_id)
);

COMMENT ON TABLE compressors IS
  'Compressors. manufacturer is never inferred from model: both are imported only where the source states them (prompt §7).';

-- ---------------------------------------------------------------------------
-- recovery_tanks
-- Physically distinct from storage vessels (source Location = Recovery, 528 rows).
-- The two tables are never merged; v_vessel_management unions them for reporting.
-- ---------------------------------------------------------------------------

CREATE TABLE recovery_tanks (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id               uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id                uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id                  uuid NULL,
  mapping_status           asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note             text NULL,

  manufacturer             text NULL,
  manufacturer_raw         text NULL,
  model                    text NULL,
  model_raw                text NULL,
  serial_number            text NULL,
  serial_number_raw        text NULL,
  serial_status            serial_status NOT NULL DEFAULT 'unknown',
  compressor_type_raw      text NULL,   -- source 'Type OF Compressor'; context, not an FK

  last_inspection_raw      text NULL,
  last_inspection_date     date NULL,
  last_inspection_precision  date_precision NOT NULL DEFAULT 'unknown',
  next_inspection_raw      text NULL,
  next_inspection_date     date NULL,
  next_inspection_precision  date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw        text NULL,   -- 'منتهية' etc. (decision D6)

  notes                    text NULL,
  import_batch_id          uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file              text NULL,
  source_sheet             text NULL,
  source_row               integer NULL,
  source_raw               jsonb NULL,
  needs_review             boolean NOT NULL DEFAULT false,
  review_reason            text NULL,

  resolved_by              uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at              timestamptz NULL,
  archived_at              timestamptz NULL,
  archived_by              uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT recovery_tanks_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT recovery_tanks_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT recovery_tanks_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT recovery_tanks_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  CONSTRAINT recovery_tanks_last_prec_ck CHECK ((last_inspection_precision = 'exact_date') = (last_inspection_date IS NOT NULL)),
  CONSTRAINT recovery_tanks_next_prec_ck CHECK ((next_inspection_precision = 'exact_date') = (next_inspection_date IS NOT NULL))
);

-- ---------------------------------------------------------------------------
-- storage_vessels
-- ---------------------------------------------------------------------------

CREATE TABLE storage_vessels (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id               uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id                uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id                  uuid NULL,
  mapping_status           asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note             text NULL,

  manufacturer             text NULL,
  manufacturer_raw         text NULL,
  model                    text NULL,
  model_raw                text NULL,
  serial_number            text NULL,
  serial_number_raw        text NULL,
  serial_status            serial_status NOT NULL DEFAULT 'unknown',
  compressor_type_raw      text NULL,

  last_inspection_raw      text NULL,
  last_inspection_date     date NULL,
  last_inspection_precision  date_precision NOT NULL DEFAULT 'unknown',
  next_inspection_raw      text NULL,
  next_inspection_date     date NULL,
  next_inspection_precision  date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw        text NULL,

  notes                    text NULL,
  import_batch_id          uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file              text NULL,
  source_sheet             text NULL,
  source_row               integer NULL,
  source_raw               jsonb NULL,
  needs_review             boolean NOT NULL DEFAULT false,
  review_reason            text NULL,

  resolved_by              uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at              timestamptz NULL,
  archived_at              timestamptz NULL,
  archived_by              uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT storage_vessels_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT storage_vessels_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT storage_vessels_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT storage_vessels_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  CONSTRAINT storage_vessels_last_prec_ck CHECK ((last_inspection_precision = 'exact_date') = (last_inspection_date IS NOT NULL)),
  CONSTRAINT storage_vessels_next_prec_ck CHECK ((next_inspection_precision = 'exact_date') = (next_inspection_date IS NOT NULL)),
  CONSTRAINT storage_vessels_id_unit_uq UNIQUE (id, unit_id)
);

-- ---------------------------------------------------------------------------
-- dispensers
-- Individual dispensers are created ONLY where the source names them
-- ('DIS. Name' / 'DIS. S/N'). A count alone ('No. Of Dispensers') never
-- generates records — the count lives on the unit as a reported attribute.
-- ---------------------------------------------------------------------------

CREATE TABLE dispensers (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id          uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id           uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id             uuid NULL,
  mapping_status      asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note        text NULL,

  dispenser_name      text NULL,      -- bay label: 'A-B', 'C-D', ...
  manufacturer        text NULL,
  manufacturer_raw    text NULL,
  model               text NULL,
  model_raw           text NULL,
  serial_number       text NULL,
  serial_number_raw   text NULL,
  serial_status       serial_status NOT NULL DEFAULT 'unknown',
  number_of_hoses     integer NULL,
  number_of_hoses_raw text NULL,

  notes               text NULL,
  source_status_raw   text NULL,
  import_batch_id     uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file         text NULL,
  source_sheet        text NULL,
  source_row          integer NULL,
  source_raw          jsonb NULL,
  needs_review        boolean NOT NULL DEFAULT false,
  review_reason       text NULL,

  resolved_by         uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at         timestamptz NULL,
  archived_at         timestamptz NULL,
  archived_by         uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT dispensers_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT dispensers_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT dispensers_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT dispensers_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  CONSTRAINT dispensers_hose_count_ck CHECK (number_of_hoses IS NULL OR number_of_hoses >= 0),
  CONSTRAINT dispensers_id_unit_uq UNIQUE (id, unit_id)
);

-- ---------------------------------------------------------------------------
-- gas_detectors — ACTUAL installed detector assets only.
-- A detector that the source says does not exist gets NO row here; the evidence
-- goes to gas_detector_presence instead.
-- ---------------------------------------------------------------------------

CREATE TABLE gas_detectors (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id                uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id                 uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id                   uuid NULL,
  mapping_status            asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note              text NULL,

  manufacturer              text NULL,
  manufacturer_raw          text NULL,
  model                     text NULL,
  model_raw                 text NULL,
  serial_number             text NULL,   -- 149 of 178 installed detectors have none
  serial_number_raw         text NULL,   -- floats such as '1803.02075' kept verbatim
  serial_status             serial_status NOT NULL DEFAULT 'unknown',

  last_calibration_raw      text NULL,
  last_calibration_date     date NULL,
  last_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  next_calibration_raw      text NULL,
  next_calibration_date     date NULL,
  next_calibration_precision date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw         text NULL,   -- 'منتهي'

  notes                     text NULL,
  import_batch_id           uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file               text NULL,
  source_sheet              text NULL,
  source_row                integer NULL,
  source_raw                jsonb NULL,
  needs_review              boolean NOT NULL DEFAULT false,
  review_reason             text NULL,

  resolved_by               uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at               timestamptz NULL,
  archived_at               timestamptz NULL,
  archived_by               uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT gas_detectors_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT gas_detectors_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT gas_detectors_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT gas_detectors_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  CONSTRAINT gas_detectors_last_prec_ck CHECK ((last_calibration_precision = 'exact_date') = (last_calibration_date IS NOT NULL)),
  CONSTRAINT gas_detectors_next_prec_ck CHECK ((next_calibration_precision = 'exact_date') = (next_calibration_date IS NOT NULL))
);

-- ---------------------------------------------------------------------------
-- gas_detector_presence — EVIDENCE, not an asset.
-- 138 source rows state 'Not exist in the station'. That is information worth
-- keeping, and it must never be represented by a fabricated detector record.
-- ---------------------------------------------------------------------------

CREATE TABLE gas_detector_presence (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id         uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id          uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id            uuid NULL,

  detector_presence  presence_state NOT NULL DEFAULT 'unknown',
  presence_raw       text NULL,     -- 'Exist in the station' / 'Not exist in the station'
  area_type          area_type NULL,
  area_type_raw      text NULL,     -- 'Open Area' / 'Close Area' / 'Closed Area'

  notes              text NULL,
  import_batch_id    uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file        text NULL,
  source_sheet       text NULL,
  source_row         integer NULL,
  source_raw         jsonb NULL,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT gdp_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT gdp_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT
);

COMMENT ON TABLE gas_detector_presence IS
  'Presence evidence per station/unit: installed | not_installed | unknown. Never a substitute for a detector asset, and never fabricated to represent absence (prompt §12).';

-- One presence statement per unit, and one per station where the unit is unknown.
CREATE UNIQUE INDEX gdp_station_unit_uq ON gas_detector_presence (station_id, unit_id)
  WHERE unit_id IS NOT NULL;
CREATE UNIQUE INDEX gdp_station_only_uq ON gas_detector_presence (station_id)
  WHERE unit_id IS NULL;

-- ---------------------------------------------------------------------------
-- hoses
-- Hoses are NOT assumed to belong to dispensers: the source gives an Arabic
-- description ('خرطوم غاز C') that cannot be deterministically matched to a
-- dispenser bay label. dispenser_id stays NULL until a human maps it.
-- Working and test pressures keep BAR and PSI exactly as found; no conversion.
-- ---------------------------------------------------------------------------

CREATE TABLE hoses (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id              uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id               uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_id                 uuid NULL,
  dispenser_id            uuid NULL,
  mapping_status          asset_mapping_status NOT NULL DEFAULT 'needs_unit_mapping',
  mapping_note            text NULL,

  description             text NULL,
  serial_number           text NULL,
  serial_number_raw       text NULL,
  serial_status           serial_status NOT NULL DEFAULT 'unknown',

  working_pressure_raw    text NULL,
  working_pressure_value  numeric NULL,
  working_pressure_unit   pressure_unit NULL,
  test_pressure_raw       text NULL,
  test_pressure_value     numeric NULL,
  test_pressure_unit      pressure_unit NULL,

  last_test_raw           text NULL,
  last_test_date          date NULL,
  last_test_precision     date_precision NOT NULL DEFAULT 'unknown',
  next_test_raw           text NULL,
  next_test_date          date NULL,
  next_test_precision     date_precision NOT NULL DEFAULT 'unknown',
  source_status_raw       text NULL,

  notes                   text NULL,
  import_batch_id         uuid NULL REFERENCES import_batches(id) ON DELETE RESTRICT,
  source_file             text NULL,
  source_sheet            text NULL,
  source_row              integer NULL,
  source_raw              jsonb NULL,
  needs_review            boolean NOT NULL DEFAULT false,
  review_reason           text NULL,

  resolved_by             uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at             timestamptz NULL,
  archived_at             timestamptz NULL,
  archived_by             uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT hoses_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT,
  CONSTRAINT hoses_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  -- A dispenser may only be attached once the unit is known, and it must belong
  -- to that same unit.
  CONSTRAINT hoses_dispenser_unit_fk FOREIGN KEY (dispenser_id, unit_id)
    REFERENCES dispensers (id, unit_id) ON DELETE RESTRICT,
  CONSTRAINT hoses_resolved_ck CHECK (mapping_status <> 'resolved' OR unit_id IS NOT NULL),
  CONSTRAINT hoses_needs_unit_ck CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL),
  CONSTRAINT hoses_dispenser_needs_unit_ck CHECK (dispenser_id IS NULL OR unit_id IS NOT NULL),
  CONSTRAINT hoses_last_prec_ck CHECK ((last_test_precision = 'exact_date') = (last_test_date IS NOT NULL)),
  CONSTRAINT hoses_next_prec_ck CHECK ((next_test_precision = 'exact_date') = (next_test_date IS NOT NULL)),
  CONSTRAINT hoses_working_pressure_ck CHECK (working_pressure_value IS NULL OR working_pressure_value >= 0),
  CONSTRAINT hoses_test_pressure_ck CHECK (test_pressure_value IS NULL OR test_pressure_value >= 0)
);

COMMENT ON TABLE hoses IS
  'Hose assets. Only 71 exist, for 3 stations in West; no hose is fabricated for regions with no source. Hose COUNTS elsewhere are unit attributes, never expanded into rows.';
