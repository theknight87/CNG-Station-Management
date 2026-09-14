-- 0015_srv_station_mapping.sql
--
-- Three corrections, all of them owner-confirmed business rules rather than
-- assumptions:
--
--  1. An installed SRV whose canonical Station is not yet confirmed is STILL an
--     installed SRV. station_id becomes nullable and the lifecycle gains
--     `needs_station_mapping`. import_issues records the *issue*; the *asset*
--     belongs in installed_relief_valves.
--
--  2. `ابنوب` = `ابنوب اسيوط` is an owner-confirmed Station alias. It bypasses
--     manual review. It does NOT authorize generic governorate-suffix stripping.
--
--  3. `SS-4R3A` is an owner-confirmed Part Number, not a serial. It normalizes
--     into part_number with serial_number NULL, raw evidence preserved. It does
--     NOT authorize moving other part-number-looking values.
--
-- Both (2) and (3) are narrow, enumerated, owner-ruled exceptions. They are
-- stored as DATA in dedicated tables — not as code — so the exact set of values
-- the owner has ruled on is always listable, auditable and reversible.

-- ---------------------------------------------------------------------------
-- 1. Installed SRVs may exist before their Station is confirmed
-- ---------------------------------------------------------------------------

ALTER TABLE installed_relief_valves
  ALTER COLUMN station_id DROP NOT NULL;

-- Raw source placement evidence, kept whether or not the Station resolves.
-- region_id stays NOT NULL: every source row states its Area, and all six values
-- normalize deterministically. Only the *Station* is in doubt.
ALTER TABLE installed_relief_valves
  ADD COLUMN source_station_name_raw text NULL,
  ADD COLUMN source_region_raw       text NULL,
  ADD COLUMN station_alias_id        uuid NULL REFERENCES station_aliases(id) ON DELETE RESTRICT;

COMMENT ON COLUMN installed_relief_valves.source_station_name_raw IS
  'Station name exactly as the source spelled it. Retained permanently, and the only station identity an unresolved SRV has. Surfaced in management and alert context as "Needs Station Mapping".';
COMMENT ON COLUMN installed_relief_valves.station_alias_id IS
  'The confirmed alias that resolved this row''s station, when one did. Makes the resolution path auditable.';

-- Replace the status/shape constraint with the five-state lifecycle.
ALTER TABLE installed_relief_valves DROP CONSTRAINT irv_status_shape_ck;

ALTER TABLE installed_relief_valves ADD CONSTRAINT irv_status_shape_ck CHECK (
  CASE mapping_status
    -- Station not yet confirmed: nothing below it may be claimed either.
    WHEN 'needs_station_mapping' THEN
      station_id IS NULL
      AND unit_id IS NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'needs_unit_mapping' THEN
      station_id IS NOT NULL
      AND unit_id IS NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'needs_equipment_mapping' THEN
      station_id IS NOT NULL
      AND unit_id IS NOT NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 0
    WHEN 'resolved' THEN
      station_id IS NOT NULL
      AND unit_id IS NOT NULL
      AND num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) = 1
    WHEN 'conflict' THEN
      -- Evidence-preserving side state: at most one parent, no other demands.
      num_nonnulls(compressor_id, storage_vessel_id, dispenser_id) <= 1
  END
);

-- An unresolved-station SRV must still say where the source placed it, so the
-- record is never anonymous and a human always has something to work from.
ALTER TABLE installed_relief_valves ADD CONSTRAINT irv_unmatched_station_evidence_ck CHECK (
  mapping_status <> 'needs_station_mapping' OR source_station_name_raw IS NOT NULL
);

CREATE INDEX irv_needs_station_idx ON installed_relief_valves (region_id)
  WHERE mapping_status = 'needs_station_mapping' AND archived_at IS NULL;
CREATE INDEX irv_source_station_idx ON installed_relief_valves (source_station_name_raw)
  WHERE station_id IS NULL;

-- Alerts must tolerate an unresolved station for the same reason: an exact due
-- date is enough to track calibration (prompt §4).
ALTER TABLE alerts
  ALTER COLUMN station_id DROP NOT NULL,
  ADD COLUMN source_station_name_raw text NULL,
  ADD COLUMN needs_station_mapping boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN alerts.source_station_name_raw IS
  'Raw source station name, carried so an alert on an unresolved SRV can name a place without fabricating a Station.';

-- ---------------------------------------------------------------------------
-- 2. Owner-confirmed station aliases (NARROW, ENUMERATED)
--
-- This table holds ONLY equivalences the system owner has explicitly ruled on.
-- The importer may auto-confirm a station_alias for a name listed here, and for
-- no other name. There is deliberately no pattern, regex or suffix rule: the
-- table stores exact values, so "what has the owner actually confirmed?" is
-- answerable by SELECT.
-- ---------------------------------------------------------------------------

CREATE TABLE owner_confirmed_station_aliases (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_name_raw       text NOT NULL,   -- the variant spelling found in sources
  canonical_name_raw    text NOT NULL,   -- the spelling treated as canonical
  source_name_normalized    text GENERATED ALWAYS AS (cng_normalize_name(source_name_raw)) STORED,
  canonical_name_normalized text GENERATED ALWAYS AS (cng_normalize_name(canonical_name_raw)) STORED,
  region_code           text NULL,       -- NULL = applies in any region
  confirmed_by_label    text NOT NULL DEFAULT 'system owner',
  confirmed_on          date NOT NULL DEFAULT current_date,
  note                  text NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ocsa_uq UNIQUE (source_name_raw, canonical_name_raw),
  CONSTRAINT ocsa_distinct_ck CHECK (cng_normalize_name(source_name_raw) <> cng_normalize_name(canonical_name_raw))
);

COMMENT ON TABLE owner_confirmed_station_aliases IS
  'Exact station-name equivalences explicitly confirmed by the system owner. The ONLY aliases that may bypass manual review. Not a rule engine: no suffix stripping, no pattern matching — one row per confirmed pair.';

-- Returns the owner-confirmed canonical name for a raw source name, or NULL.
-- Exact (normalized) match only. This function is the entire mechanism by which
-- an alias may skip review; there is no other path.
CREATE OR REPLACE FUNCTION cng_owner_confirmed_canonical(p_source_name text, p_region_code text DEFAULT NULL)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT a.canonical_name_raw
  FROM owner_confirmed_station_aliases a
  WHERE a.source_name_normalized = cng_normalize_name(p_source_name)
    AND (a.region_code IS NULL OR p_region_code IS NULL OR a.region_code = p_region_code)
  LIMIT 1;
$$;

COMMENT ON FUNCTION cng_owner_confirmed_canonical(text, text) IS
  'Exact-match lookup of an owner-confirmed station alias. Returns NULL for anything not explicitly confirmed — including names that merely differ by a governorate suffix.';

-- ---------------------------------------------------------------------------
-- 3. Owner-confirmed identifier classification (NARROW, ENUMERATED)
--
-- Same discipline: exact values only. `SS-4R3A` is confirmed a part number, so
-- when it appears in an SRV serial column it normalizes into part_number and the
-- serial becomes NULL. No other value is touched, and nothing is inferred from
-- shape ("looks like a part number" is not evidence).
-- ---------------------------------------------------------------------------

CREATE TABLE owner_confirmed_part_numbers (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_value       text NOT NULL UNIQUE,   -- the exact cell value, verbatim
  normalized_value   text GENERATED ALWAYS AS (upper(btrim(source_value))) STORED,
  applies_to         asset_type NOT NULL,
  confirmed_by_label text NOT NULL DEFAULT 'system owner',
  confirmed_on       date NOT NULL DEFAULT current_date,
  note               text NULL,
  created_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE owner_confirmed_part_numbers IS
  'Exact source values the system owner has confirmed are part numbers rather than serial numbers. Applied only to these exact values; never generalized by shape or similarity.';

CREATE UNIQUE INDEX ocpn_normalized_uq ON owner_confirmed_part_numbers (normalized_value, applies_to);

-- Classifies one raw identifier cell. Returns the pair (serial_number,
-- part_number) that should be stored.
--   * confirmed part number  -> (NULL, value)
--   * anything else          -> (value, NULL)
-- The raw cell is always preserved separately in serial_number_raw + source_raw.
CREATE OR REPLACE FUNCTION cng_classify_identifier(
  p_raw text,
  p_asset asset_type,
  OUT serial_number text,
  OUT part_number text
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT
    CASE WHEN confirmed THEN NULL ELSE nullif(btrim(p_raw), '') END,
    CASE WHEN confirmed THEN btrim(p_raw) ELSE NULL END
  FROM (
    SELECT EXISTS (
      SELECT 1 FROM owner_confirmed_part_numbers p
      WHERE p.normalized_value = upper(btrim(p_raw))
        AND p.applies_to = p_asset
    ) AS confirmed
  ) s;
$$;

COMMENT ON FUNCTION cng_classify_identifier(text, asset_type) IS
  'Splits a raw identifier into (serial_number, part_number) using ONLY owner-confirmed part numbers. Any unlisted value stays a serial — no shape-based guessing.';

-- ---------------------------------------------------------------------------
-- Seed the owner-confirmed rulings
-- ---------------------------------------------------------------------------

INSERT INTO owner_confirmed_station_aliases (source_name_raw, canonical_name_raw, note)
VALUES (
  'ابنوب',
  'ابنوب اسيوط',
  'Owner-confirmed: the same physical station. Confirmed for THIS PAIR ONLY; it does not authorize generic governorate-suffix stripping.'
)
ON CONFLICT (source_name_raw, canonical_name_raw) DO NOTHING;

INSERT INTO owner_confirmed_part_numbers (source_value, applies_to, note)
VALUES (
  'SS-4R3A',
  'installed_relief_valve',
  'Owner-confirmed: a part number occupying the serial column. This SRV type has no unique serial assigned yet. Applies to this exact value only.'
)
ON CONFLICT (source_value) DO NOTHING;

-- ---------------------------------------------------------------------------
-- RLS for the two tables introduced here.
--
-- 0012 enabled RLS on everything that existed at the time; these tables are
-- newer, so they must enable it themselves. Any future migration that adds a
-- table must do the same — no table ships without RLS (CLAUDE.md §7).
-- Deny-by-default until the auth phase adds policies.
-- ---------------------------------------------------------------------------

ALTER TABLE owner_confirmed_station_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE owner_confirmed_station_aliases FORCE  ROW LEVEL SECURITY;
ALTER TABLE owner_confirmed_part_numbers    ENABLE ROW LEVEL SECURITY;
ALTER TABLE owner_confirmed_part_numbers    FORCE  ROW LEVEL SECURITY;
