-- 0014_mapping_lifecycle_enums.sql
-- New enum values for the extended SRV mapping lifecycle and owner-confirmed aliases.
--
-- These are isolated in their own migration because PostgreSQL will not allow a
-- value added by ALTER TYPE ... ADD VALUE to be *used* until the adding
-- transaction has committed. Splitting the file guarantees 0015 can reference
-- them in CHECK constraints and seed data.

-- The full lifecycle is now:
--   needs_station_mapping -> needs_unit_mapping -> needs_equipment_mapping -> resolved
--   (with `conflict` as an evidence-preserving side state)
ALTER TYPE srv_mapping_status ADD VALUE IF NOT EXISTS 'needs_station_mapping' BEFORE 'needs_unit_mapping';

-- An alias confirmed directly by the system owner. Distinct from 'human' (a
-- named application user confirming in the review UI) so owner rulings can be
-- listed and audited as their own class.
ALTER TYPE alias_source ADD VALUE IF NOT EXISTS 'owner_confirmed';

-- Asset-level mapping status for unit-scoped equipment gains the same station
-- state, for symmetry with SRVs when an equipment row's station is unmatched.
ALTER TYPE asset_mapping_status ADD VALUE IF NOT EXISTS 'needs_station_mapping' BEFORE 'needs_unit_mapping';
