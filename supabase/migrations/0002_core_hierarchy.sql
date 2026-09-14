-- 0002_core_hierarchy.sql
-- Region → Station → Unit, plus the alias tables that resolve source names.

-- ---------------------------------------------------------------------------
-- regions
-- Exactly six canonical regions. Seeded in 0010; not user-editable.
-- ---------------------------------------------------------------------------

CREATE TABLE regions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code        text NOT NULL UNIQUE,   -- 'east', 'west', ...
  name        text NOT NULL UNIQUE,   -- 'East', 'West', 'Canal', 'Delta', 'Alex', 'Upper'
  sort_order  smallint NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT regions_code_lower_ck CHECK (code = lower(code))
);

COMMENT ON TABLE regions IS 'The six canonical regions. Closed set; seeded in 0010.';

-- ---------------------------------------------------------------------------
-- stations
--
-- `Station data base.xlsx` is NOT the station master: it mixes station-level and
-- unit-level naming (docs/data-quality-report.md §3). Stations are reconciled
-- across sources and reached through station_aliases.
--
-- Soft delete: stations carry calibration history, imported evidence and audit
-- trails. They are archived, never hard-deleted (prompt §32).
-- ---------------------------------------------------------------------------

CREATE TABLE stations (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  region_id        uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  station_name     text NOT NULL,
  normalized_name  text GENERATED ALWAYS AS (cng_normalize_name(station_name)) STORED,
  bay_status       bay_status NULL,
  bay_status_raw   text NULL,
  notes            text NULL,

  -- provenance
  import_batch_id  uuid NULL,          -- FK added in 0006 (import_batches created later)
  source_file      text NULL,
  source_sheet     text NULL,
  source_row       integer NULL,
  source_raw       jsonb NULL,

  needs_review     boolean NOT NULL DEFAULT false,
  review_reason    text NULL,

  archived_at      timestamptz NULL,   -- soft delete
  archived_by      uuid NULL,          -- FK added in 0005
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  -- One canonical station per normalized name per region. Different regions may
  -- legitimately hold similarly named stations.
  CONSTRAINT stations_region_norm_uq UNIQUE (region_id, normalized_name),
  -- Referenced by the composite FK on units (id, region_id) to keep a unit's
  -- region consistent with its station's without denormalizing region onto units.
  CONSTRAINT stations_id_region_uq UNIQUE (id, region_id)
);

COMMENT ON TABLE stations IS
  'Canonical stations, reconciled across sources. Source names resolve here only through a confirmed row in station_aliases.';
COMMENT ON COLUMN stations.normalized_name IS
  'Generated: cng_normalize_name(station_name). For uniqueness and alias proposal, not for runtime resolution.';

-- ---------------------------------------------------------------------------
-- units
--
-- A unit belongs to exactly one station. There is NO one-unit-per-station
-- fallback (decision D7): where the unit structure is unknown, no unit exists
-- and unit-scoped assets carry unit_id = NULL.
--
-- job_number is TEXT and nullable: it is non-uniform ('2826ps001', 'MC 1138',
-- 30157), NOT unique (4 numbers appear on 2 units each), and absent for three
-- entire regions. It is an attribute, never a key (principle #4).
-- ---------------------------------------------------------------------------

CREATE TABLE units (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id       uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  region_id        uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  unit_name        text NOT NULL,
  normalized_name  text GENERATED ALWAYS AS (cng_normalize_name(unit_name)) STORED,
  job_number       text NULL,          -- TEXT always; never a key
  job_number_raw   text NULL,
  notes            text NULL,

  import_batch_id  uuid NULL,
  source_file      text NULL,
  source_sheet     text NULL,
  source_row       integer NULL,
  source_raw       jsonb NULL,

  needs_review     boolean NOT NULL DEFAULT false,
  review_reason    text NULL,

  archived_at      timestamptz NULL,
  archived_by      uuid NULL,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT units_station_norm_uq UNIQUE (station_id, normalized_name),
  -- Composite target: lets every unit-scoped asset prove (unit_id, station_id)
  -- declaratively, with no trigger. See docs/database.md.
  CONSTRAINT units_id_station_uq UNIQUE (id, station_id),
  CONSTRAINT units_id_region_uq  UNIQUE (id, region_id),
  -- A unit's region must equal its station's region.
  CONSTRAINT units_station_region_fk FOREIGN KEY (station_id, region_id)
    REFERENCES stations (id, region_id) ON DELETE RESTRICT
);

COMMENT ON TABLE units IS
  'Units of a station. Never auto-created: a station with no known unit structure has zero units (decision D7).';
COMMENT ON COLUMN units.job_number IS
  'TEXT, nullable, NOT unique. Absent for Canal/Alex/Upper entirely. Never blocks creation (principle #4).';

-- ---------------------------------------------------------------------------
-- station_aliases
--
-- The ONLY authoritative way a source name resolves to a canonical station.
-- Fuzzy/deterministic rules may PROPOSE; only `confirmed` resolves.
--
-- Per prompt §5, rule-derived proposals (governorate suffix, numbered unit) are
-- inserted as `proposed` and must be confirmed by a human before use. The rule
-- that suggested them is recorded in alias_source so a whole rule's output can
-- be reviewed, accepted or reversed as a set.
-- ---------------------------------------------------------------------------

CREATE TABLE station_aliases (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  region_id              uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  station_id             uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,
  source_name_raw        text NOT NULL,
  source_name_normalized text NOT NULL,
  source_file            text NOT NULL,
  alias_status           alias_status NOT NULL DEFAULT 'proposed',
  alias_source           alias_source NOT NULL,
  match_confidence       numeric(4,3) NULL,   -- advisory only, for review ordering
  notes                  text NULL,

  confirmed_by           uuid NULL,
  confirmed_at           timestamptz NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  -- One alias row per raw name per file per region.
  CONSTRAINT station_aliases_uq UNIQUE (region_id, source_file, source_name_raw),

  -- A confirmed alias MUST point at a station; a rejected one must not.
  -- This is what makes "only confirmed aliases resolve" a database guarantee
  -- rather than a convention.
  CONSTRAINT station_aliases_confirmed_ck CHECK (
    (alias_status = 'confirmed' AND station_id IS NOT NULL AND confirmed_by IS NOT NULL
                                AND confirmed_at IS NOT NULL)
    OR (alias_status = 'rejected' AND station_id IS NULL)
    OR (alias_status = 'proposed')
  ),
  CONSTRAINT station_aliases_confidence_ck CHECK (
    match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1)
  )
);

COMMENT ON TABLE station_aliases IS
  'Explicit source-name → canonical station mapping. Only alias_status = confirmed may be used to resolve an import. '
  'Governorate-suffix and numbered-unit rules insert PROPOSED rows only; a human confirms them (prompt §5).';

-- Only one CONFIRMED alias may exist for a given normalized name in a region;
-- proposals may be many (several candidate stations for one ambiguous name).
CREATE UNIQUE INDEX station_aliases_confirmed_norm_uq
  ON station_aliases (region_id, source_name_normalized)
  WHERE alias_status = 'confirmed';

-- ---------------------------------------------------------------------------
-- unit_aliases
--
-- Justified by the data: the source files disagree on whether a numbered name
-- ('الخمائل 1') is a unit or a station, and `Station data base.xlsx` is
-- unit-grain while `Assets DataBase` is station+unit-grain. Resolving unit names
-- therefore needs the same explicit mechanism as stations — 107 of 194 rows in
-- the master file match an Assets *unit* name (quality report §3).
-- ---------------------------------------------------------------------------

CREATE TABLE unit_aliases (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  station_id             uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,
  unit_id                uuid NULL REFERENCES units(id) ON DELETE RESTRICT,
  region_id              uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  source_name_raw        text NOT NULL,
  source_name_normalized text NOT NULL,
  source_file            text NOT NULL,
  alias_status           alias_status NOT NULL DEFAULT 'proposed',
  alias_source           alias_source NOT NULL,
  match_confidence       numeric(4,3) NULL,
  notes                  text NULL,

  confirmed_by           uuid NULL,
  confirmed_at           timestamptz NULL,
  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT unit_aliases_uq UNIQUE (region_id, source_file, source_name_raw),
  CONSTRAINT unit_aliases_confirmed_ck CHECK (
    (alias_status = 'confirmed' AND unit_id IS NOT NULL AND confirmed_by IS NOT NULL
                                AND confirmed_at IS NOT NULL)
    OR (alias_status = 'rejected' AND unit_id IS NULL)
    OR (alias_status = 'proposed')
  ),
  -- If both are given, the unit must belong to the stated station.
  CONSTRAINT unit_aliases_unit_station_fk FOREIGN KEY (unit_id, station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  CONSTRAINT unit_aliases_confidence_ck CHECK (
    match_confidence IS NULL OR (match_confidence >= 0 AND match_confidence <= 1)
  )
);

COMMENT ON TABLE unit_aliases IS
  'Source-name → canonical unit mapping. Same proposed/confirmed/rejected discipline as station_aliases.';

CREATE UNIQUE INDEX unit_aliases_confirmed_norm_uq
  ON unit_aliases (region_id, source_name_normalized)
  WHERE alias_status = 'confirmed';

-- ---------------------------------------------------------------------------
-- Indexes: Region → Stations, Station → Units, alias lookup
-- ---------------------------------------------------------------------------

CREATE INDEX stations_region_idx        ON stations (region_id) WHERE archived_at IS NULL;
CREATE INDEX stations_normalized_idx    ON stations (normalized_name);
CREATE INDEX stations_review_idx        ON stations (needs_review) WHERE needs_review;
CREATE INDEX units_station_idx          ON units (station_id) WHERE archived_at IS NULL;
CREATE INDEX units_region_idx           ON units (region_id) WHERE archived_at IS NULL;
CREATE INDEX units_normalized_idx       ON units (normalized_name);
CREATE INDEX station_aliases_lookup_idx ON station_aliases (region_id, source_name_normalized);
CREATE INDEX station_aliases_station_idx ON station_aliases (station_id);
CREATE INDEX station_aliases_queue_idx  ON station_aliases (alias_status) WHERE alias_status = 'proposed';
CREATE INDEX unit_aliases_lookup_idx    ON unit_aliases (region_id, source_name_normalized);
CREATE INDEX unit_aliases_queue_idx     ON unit_aliases (alias_status) WHERE alias_status = 'proposed';

-- updated_at triggers
CREATE TRIGGER regions_set_updated_at BEFORE UPDATE ON regions
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER stations_set_updated_at BEFORE UPDATE ON stations
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER units_set_updated_at BEFORE UPDATE ON units
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER station_aliases_set_updated_at BEFORE UPDATE ON station_aliases
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER unit_aliases_set_updated_at BEFORE UPDATE ON unit_aliases
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
