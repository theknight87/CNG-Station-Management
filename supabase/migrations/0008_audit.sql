-- 0008_audit.sql
-- Append-only mapping audit and the general application audit log.
--
-- Neither table is ever updated or deleted by application code. Both are
-- append-only by policy (enforced in RLS in the auth phase: INSERT and SELECT
-- only, no UPDATE/DELETE grant for any application role).
--
-- Mapping audit records the HUMAN DECISION. source_raw on the asset records the
-- SOURCE EVIDENCE and is never touched by a mapping change — the two must stay
-- independently inspectable so a wrong mapping can be traced and reversed.

CREATE TABLE asset_mapping_audit (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  asset_type              asset_type NOT NULL,
  asset_id                uuid NOT NULL,      -- no FK: references one of several tables

  previous_station_id     uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,
  new_station_id          uuid NULL REFERENCES stations(id) ON DELETE RESTRICT,
  previous_unit_id        uuid NULL REFERENCES units(id) ON DELETE RESTRICT,
  new_unit_id             uuid NULL REFERENCES units(id) ON DELETE RESTRICT,

  previous_parent_type    srv_parent_kind NULL,
  previous_parent_id      uuid NULL,
  new_parent_type         srv_parent_kind NULL,
  new_parent_id           uuid NULL,

  previous_mapping_status text NULL,          -- TEXT: spans two different status enums
  new_mapping_status      text NULL,

  changed_by              uuid NOT NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  changed_at              timestamptz NOT NULL DEFAULT now(),
  is_bulk                 boolean NOT NULL DEFAULT false,
  bulk_batch_id           uuid NULL,          -- groups one confirmed bulk action
  reason                  text NULL,

  CONSTRAINT ama_parent_pair_ck CHECK (
    (new_parent_type IS NULL) = (new_parent_id IS NULL)
    AND (previous_parent_type IS NULL) = (previous_parent_id IS NULL)
  ),
  CONSTRAINT ama_bulk_ck CHECK (is_bulk = (bulk_batch_id IS NOT NULL))
);

COMMENT ON TABLE asset_mapping_audit IS
  'Append-only history of mapping decisions. changed_by is NOT NULL and RESTRICT: a mapping must always remain attributable to a real user, so a user who has made mappings cannot be deleted.';
COMMENT ON COLUMN asset_mapping_audit.asset_id IS
  'Deliberately not a foreign key: one column cannot reference six asset tables. Asset tables use ON DELETE RESTRICT and soft delete, so the target is never silently removed.';

CREATE INDEX ama_asset_idx  ON asset_mapping_audit (asset_type, asset_id, changed_at DESC);
CREATE INDEX ama_actor_idx  ON asset_mapping_audit (changed_by, changed_at DESC);
CREATE INDEX ama_bulk_idx   ON asset_mapping_audit (bulk_batch_id) WHERE bulk_batch_id IS NOT NULL;
CREATE INDEX ama_recent_idx ON asset_mapping_audit (changed_at DESC);

-- ---------------------------------------------------------------------------
-- audit_logs — general application events
-- ---------------------------------------------------------------------------

CREATE TABLE audit_logs (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  action       audit_action NOT NULL,
  entity_table text NOT NULL,
  entity_id    uuid NULL,
  actor_id     uuid NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  actor_label  text NULL,      -- retained even if the app_user row is gone
  summary      text NULL,
  before_data  jsonb NULL,
  after_data   jsonb NULL,
  occurred_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE audit_logs IS
  'Application audit trail. Append-only; ordinary users get INSERT/SELECT only and never UPDATE or DELETE.';

CREATE INDEX audit_logs_entity_idx  ON audit_logs (entity_table, entity_id, occurred_at DESC);
CREATE INDEX audit_logs_actor_idx   ON audit_logs (actor_id, occurred_at DESC);
CREATE INDEX audit_logs_action_idx  ON audit_logs (action, occurred_at DESC);
