-- 0001_enums_and_helpers.sql
-- CNG Station Management System — enumerated types and shared helpers.
--
-- Project: cng-station-management (its own Supabase organization).
-- Never apply to any other project's database (CLAUDE.md §2).
--
-- Design notes:
--  * Enums are used where the value set is small, closed and semantic. Anything
--    that carries source text also keeps a *_raw TEXT column, so an unexpected
--    source value never has to be forced into an enum (data principle #6).
--  * No table is created here; this migration only defines types and functions.

-- ---------------------------------------------------------------------------
-- Identity and authorization
-- ---------------------------------------------------------------------------

CREATE TYPE app_role AS ENUM ('admin', 'manager', 'engineer', 'viewer');

-- ---------------------------------------------------------------------------
-- Date precision (CLAUDE.md principle #17)
--
-- Source dates arrive as real dates, text dates, bare years, status words, or
-- junk. Precision is explicit so that only `exact_date` can ever drive an alert.
-- A bare `2021` must NOT become 2021-01-01.
-- ---------------------------------------------------------------------------

CREATE TYPE date_precision AS ENUM (
  'exact_date',  -- a real calendar date; the only kind that drives alerts
  'year_only',   -- e.g. '2021' / 2021 — value NULL, year kept in *_raw
  'unknown',     -- source cell empty
  'invalid'      -- unparseable or not a date: 'منتهية', '209/2021', '16/8/3033'
);

-- ---------------------------------------------------------------------------
-- Operational due status (derived, never stored — see 0008)
-- ---------------------------------------------------------------------------

CREATE TYPE due_status AS ENUM (
  'overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60', 'valid',
  'unknown'      -- no exact due date exists; NEVER conflated with 'valid'
);

-- ---------------------------------------------------------------------------
-- Mapping status
--
-- Two shapes. Unit-scoped assets (vessels, detectors, hoses, dispensers,
-- compressors, recovery tanks) resolve only a Unit. Relief valves additionally
-- resolve a parent equipment record, so they get their own type.
-- ---------------------------------------------------------------------------

CREATE TYPE asset_mapping_status AS ENUM (
  'resolved',            -- Unit confirmed
  'needs_unit_mapping',  -- Station confirmed, Unit unknown
  'conflict'             -- sources disagree; never treated as resolved
);

CREATE TYPE srv_mapping_status AS ENUM (
  'resolved',                 -- Unit + exactly one equipment parent
  'needs_unit_mapping',       -- Station confirmed, Unit unknown
  'needs_equipment_mapping',  -- Station + Unit confirmed, parent unknown
  'conflict'                  -- sources disagree; never treated as resolved
);

-- Equipment kinds that may parent a Safety Relief Valve.
-- `dispenser` exists because the hierarchy permits it; no current source proves
-- a dispenser SRV, and none may be inferred (CLAUDE.md §4).
CREATE TYPE srv_parent_kind AS ENUM ('compressor', 'storage_vessel', 'dispenser');

-- ---------------------------------------------------------------------------
-- Serial number status (decision D4)
--
-- 'not_yet_assigned' is a positive fact — the asset type has no unique serial
-- issued yet — and is deliberately distinct from 'unknown', where the source
-- simply says nothing. Serials are never generated automatically.
-- ---------------------------------------------------------------------------

CREATE TYPE serial_status AS ENUM ('assigned', 'not_yet_assigned', 'unknown');

-- ---------------------------------------------------------------------------
-- Alias resolution (CLAUDE.md §8)
-- ---------------------------------------------------------------------------

CREATE TYPE alias_status AS ENUM ('proposed', 'confirmed', 'rejected');

-- How an alias came to exist. Stored per row so that every alias created by a
-- rule can be listed, audited and reversed as a set.
CREATE TYPE alias_source AS ENUM (
  'human',                    -- a person created or confirmed it
  'import_exact_match',       -- exact normalized match at import
  'rule:governorate_suffix',  -- decision D1 — proposal only, see 0002
  'rule:numbered_unit'        -- decision D2 — proposal only, see 0002
);

-- ---------------------------------------------------------------------------
-- Equipment presence (gas detectors)
--
-- 'not_installed' is evidence, not absence of data: 138 source rows state it
-- explicitly. No gas_detectors row is ever created to represent it.
-- ---------------------------------------------------------------------------

CREATE TYPE presence_state AS ENUM ('installed', 'not_installed', 'unknown');

CREATE TYPE area_type AS ENUM ('open', 'closed');

CREATE TYPE bay_status AS ENUM ('open', 'closed');

-- ---------------------------------------------------------------------------
-- Pressure units — never converted between each other (CLAUDE.md, mapping doc)
-- ---------------------------------------------------------------------------

CREATE TYPE pressure_unit AS ENUM ('BAR', 'PSI');

-- ---------------------------------------------------------------------------
-- Warehouse SRV availability (5 observed source values)
-- ---------------------------------------------------------------------------

CREATE TYPE warehouse_availability AS ENUM (
  'available_new',
  'available_calibrated',
  'available_in_store_uc',
  'sent_to_station_received',
  'sent_to_station_not_received'
);

-- ---------------------------------------------------------------------------
-- Asset type — used by alerts, mapping audit and import issues to reference a
-- record in any asset table. These are deliberately NOT foreign keys: a single
-- FK column cannot point at six tables. Referential integrity for these is
-- enforced by the application plus the ON DELETE policy of the owning table
-- (see docs/database.md §"Deletion behaviour").
-- ---------------------------------------------------------------------------

CREATE TYPE asset_type AS ENUM (
  'installed_relief_valve',
  'warehouse_relief_valve',
  'storage_vessel',
  'recovery_tank',
  'gas_detector',
  'hose',
  'compressor',
  'dispenser'
);

-- ---------------------------------------------------------------------------
-- Import / data quality
-- ---------------------------------------------------------------------------

CREATE TYPE import_status AS ENUM ('dry_run', 'running', 'completed', 'failed', 'rolled_back');

CREATE TYPE issue_severity AS ENUM ('info', 'warning', 'error');

CREATE TYPE issue_status AS ENUM ('open', 'resolved', 'wont_fix');

CREATE TYPE import_issue_type AS ENUM (
  'unmatched_station',
  'ambiguous_station',
  'ambiguous_unit',
  'unit_structure_unknown',
  'invalid_date',
  'year_only_date',
  'conflicting_dates',
  'duplicate_candidate',
  'serial_quality_issue',
  'missing_serial',
  'placeholder_value',
  'mapping_conflict',
  'manufacturer_alias_candidate',
  'unit_mismatch',
  'other'
);

-- ---------------------------------------------------------------------------
-- Alerts
-- ---------------------------------------------------------------------------

-- What kind of due date a rule watches. Generic from the outset: the alert
-- engine must never be SRV-only (prompt §26).
CREATE TYPE alert_subject AS ENUM (
  'srv_calibration',
  'storage_inspection',
  'recovery_tank_inspection',
  'gas_detector_calibration',
  'hose_hydrotest'
);

CREATE TYPE alert_threshold AS ENUM ('due_60', 'due_30', 'due_15', 'due_7', 'due_today', 'overdue');

CREATE TYPE alert_state AS ENUM ('open', 'acknowledged', 'resolved', 'suppressed');

CREATE TYPE notification_channel AS ENUM ('email', 'web_push');

CREATE TYPE delivery_status AS ENUM ('pending', 'sent', 'failed', 'skipped');

CREATE TYPE audit_action AS ENUM (
  'record_created', 'record_updated', 'record_deleted', 'record_restored',
  'mapping_changed', 'alias_confirmed', 'alias_rejected',
  'user_role_changed', 'region_access_changed',
  'alert_rule_changed', 'import_executed', 'admin_action'
);

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Business date in the operational timezone. Every due-date calculation in this
-- schema goes through this function, so the timezone is defined exactly once.
-- Africa/Cairo per docs/architecture.md.
CREATE OR REPLACE FUNCTION cng_business_date()
RETURNS date
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT (now() AT TIME ZONE 'Africa/Cairo')::date;
$$;

COMMENT ON FUNCTION cng_business_date() IS
  'Current business date in Africa/Cairo. Single source of truth for all due-date arithmetic.';

-- Deterministic Arabic/Latin name normalization, used to PROPOSE aliases and to
-- detect exact matches. It never resolves a lookup on its own: resolution always
-- goes through a confirmed row in station_aliases / unit_aliases.
CREATE OR REPLACE FUNCTION cng_normalize_name(p_name text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
  SELECT nullif(
    btrim(
      regexp_replace(
        translate(
          normalize(lower(btrim(p_name)), NFKC),
          -- tatweel and Arabic diacritics removed; alef/yaa/taa-marbuta folded
          E'ـًٌٍَُِّْأإآىة',
          E'ااايه'
        ),
        '\s+', ' ', 'g'
      )
    ),
    ''
  );
$$;

COMMENT ON FUNCTION cng_normalize_name(text) IS
  'Deterministic name normalization (NFKC, case, whitespace, Arabic letter folding). '
  'Used to propose aliases and detect exact matches only — never as a runtime resolver.';

-- Updated-at maintenance. Plain trigger function, no elevated privileges.
CREATE OR REPLACE FUNCTION cng_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
