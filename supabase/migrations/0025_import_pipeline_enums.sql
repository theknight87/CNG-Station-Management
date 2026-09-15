-- 0025_import_pipeline_enums.sql
-- Enum values the import pipeline needs. ISOLATED in their own migration:
-- PostgreSQL will not let a new enum value be USED in the transaction that
-- added it, so 0026 (which uses them) must be a separate migration. Same
-- reason as 0014.

-- How a staged source row ended up. This is the pipeline's own verdict on the
-- row, distinct from `import_issues`, which records WHY.
CREATE TYPE staging_outcome AS ENUM (
  'ready',            -- would create or update a canonical record as-is
  'ready_unresolved', -- would be created, but carries an unresolved mapping
  'proposal_only',    -- resolves only to a PROPOSED alias; attaches nothing
  'conflict',         -- sources disagree; held for a human
  'rejected',         -- structurally unusable (no identity at all)
  'excluded',         -- deliberately out of scope, e.g. the Repair Kit sheet
  'replayed'          -- identical to a row already staged by an earlier run
);

-- Dry run vs a real commit. A dry run performs identical parsing,
-- normalization, matching and validation and writes ONLY to staging.
CREATE TYPE import_run_mode AS ENUM ('dry_run', 'commit');

-- Issue types the source analysis proved are needed and 0001 did not carry.
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'unknown_region';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'ambiguous_station_identity';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'not_found_in_assets_database';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'placeholder_in_source';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'suspected_part_number_in_serial_column';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'identifier_numeric_coercion';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'source_conflict';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'missing_job_number';
ALTER TYPE import_issue_type ADD VALUE IF NOT EXISTS 'structurally_invalid_row';
