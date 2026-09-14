-- 0004_import_traceability.sql
-- Import batches and the data-quality issue queue.
--
-- Created before the asset tables so every asset can carry a real FK to its
-- import batch. No source row is ever silently discarded: a row that cannot be
-- promoted into an asset table survives here, with its full raw content.

CREATE TABLE import_batches (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_file       text NOT NULL,
  source_sheet      text NULL,
  file_checksum     text NULL,        -- sha256 where computable; proves which file version
  status            import_status NOT NULL DEFAULT 'dry_run',
  imported_by       uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  started_at        timestamptz NOT NULL DEFAULT now(),
  completed_at      timestamptz NULL,

  rows_read         integer NOT NULL DEFAULT 0,
  rows_imported     integer NOT NULL DEFAULT 0,
  rows_flagged      integer NOT NULL DEFAULT 0,
  rows_failed       integer NOT NULL DEFAULT 0,

  header_row        integer NULL,     -- asserted per file: 1, or 5 for files 3 and 4
  metadata          jsonb NULL,       -- column mapping, normalization rules applied, counts
  notes             text NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT import_batches_counts_ck CHECK (
    rows_read >= 0 AND rows_imported >= 0 AND rows_flagged >= 0 AND rows_failed >= 0
  ),
  CONSTRAINT import_batches_completed_ck CHECK (
    (status IN ('completed', 'failed', 'rolled_back')) = (completed_at IS NOT NULL)
  )
);

COMMENT ON TABLE import_batches IS
  'One row per importer run, dry-run included. metadata holds the detected header row and column mapping so a run is reproducible.';

-- ---------------------------------------------------------------------------
-- import_issues
--
-- The Data Quality queue AND the holding area for rows that could not be
-- promoted. `entity_type`/`entity_id` are nullable precisely because the most
-- important issues (unmatched_station) have no asset row yet — the evidence
-- lives here until a human resolves it.
-- ---------------------------------------------------------------------------

CREATE TABLE import_issues (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  import_batch_id  uuid NOT NULL REFERENCES import_batches(id) ON DELETE RESTRICT,

  source_file      text NOT NULL,
  source_sheet     text NULL,
  source_row       integer NULL,
  source_raw       jsonb NULL,        -- the entire source row, verbatim
  source_value     text NULL,         -- the specific offending value

  entity_type      asset_type NULL,   -- NULL when no asset row could be created
  entity_id        uuid NULL,         -- no FK: may reference any asset table
  region_id        uuid NULL REFERENCES regions(id) ON DELETE RESTRICT,
  station_id       uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,

  issue_type       import_issue_type NOT NULL,
  severity         issue_severity NOT NULL DEFAULT 'warning',
  status           issue_status NOT NULL DEFAULT 'open',
  detail           text NULL,
  resolution       text NULL,
  resolved_by      uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  resolved_at      timestamptz NULL,

  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT import_issues_resolved_ck CHECK (
    (status = 'open' AND resolved_at IS NULL)
    OR (status <> 'open' AND resolved_at IS NOT NULL)
  )
);

COMMENT ON TABLE import_issues IS
  'Data-quality queue and holding area. A source row that cannot be promoted (e.g. unmatched station) survives here with its full source_raw — nothing is discarded (principle #10).';

CREATE INDEX import_issues_open_idx    ON import_issues (issue_type, severity) WHERE status = 'open';
CREATE INDEX import_issues_batch_idx   ON import_issues (import_batch_id);
CREATE INDEX import_issues_entity_idx  ON import_issues (entity_type, entity_id);
CREATE INDEX import_issues_station_idx ON import_issues (station_id) WHERE status = 'open';
CREATE INDEX import_batches_status_idx ON import_batches (status, started_at DESC);

-- Deferred provenance FKs from 0002.
ALTER TABLE stations ADD CONSTRAINT stations_import_batch_fk
  FOREIGN KEY (import_batch_id) REFERENCES import_batches(id) ON DELETE RESTRICT;
ALTER TABLE units ADD CONSTRAINT units_import_batch_fk
  FOREIGN KEY (import_batch_id) REFERENCES import_batches(id) ON DELETE RESTRICT;

CREATE TRIGGER import_batches_set_updated_at BEFORE UPDATE ON import_batches
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER import_issues_set_updated_at BEFORE UPDATE ON import_issues
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
