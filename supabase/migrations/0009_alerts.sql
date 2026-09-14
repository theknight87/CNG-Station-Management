-- 0009_alerts.sql
-- Generic alert engine: rules, generated alerts, preferences, subscriptions,
-- and delivery records.
--
-- Generic from the outset (prompt §26). alert_rules.subject covers SRV
-- calibration, storage inspection, recovery tank inspection, gas detector
-- calibration and hose hydrotest; nothing about the design is SRV-specific.
--
-- An UNRESOLVED SRV is still alertable. Alerting needs three things — the asset
-- exists, its station is confirmed, and it has an exact next due date — none of
-- which requires unit or equipment mapping. The alert simply carries
-- needs_mapping = true so the recipient knows the location is not yet pinned.

CREATE TABLE alert_rules (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject         alert_subject NOT NULL,
  threshold       alert_threshold NOT NULL,
  days_before     integer NULL,      -- 60/30/15/7; NULL for due_today and overdue
  is_enabled      boolean NOT NULL DEFAULT true,
  description     text NULL,
  created_by      uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT alert_rules_uq UNIQUE (subject, threshold),
  -- days_before must be present exactly for the countdown thresholds.
  CONSTRAINT alert_rules_days_ck CHECK (
    (threshold IN ('due_60','due_30','due_15','due_7') AND days_before IS NOT NULL AND days_before > 0)
    OR (threshold IN ('due_today','overdue') AND days_before IS NULL)
  )
);

COMMENT ON TABLE alert_rules IS
  'One row per (subject, threshold). Seeded with the six default thresholds for all five subjects in 0012.';

CREATE TABLE alerts (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_rule_id  uuid NOT NULL REFERENCES alert_rules(id) ON DELETE RESTRICT,
  subject        alert_subject NOT NULL,
  threshold      alert_threshold NOT NULL,

  asset_type     asset_type NOT NULL,
  asset_id       uuid NOT NULL,       -- no FK; see asset_mapping_audit comment
  region_id      uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  station_id     uuid NOT NULL REFERENCES stations(id) ON DELETE RESTRICT,
  unit_id        uuid NULL REFERENCES units(id) ON DELETE RESTRICT,

  due_date       date NOT NULL,       -- always an exact_date; year_only never reaches here
  days_left      integer NULL,        -- snapshot at generation, for the message body only
  needs_mapping  boolean NOT NULL DEFAULT false,

  state          alert_state NOT NULL DEFAULT 'open',
  acknowledged_by uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  acknowledged_at timestamptz NULL,
  resolved_at    timestamptz NULL,
  detail         jsonb NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),

  -- Idempotency: one alert per asset per threshold per due date. A re-run of the
  -- cron job cannot double-alert, however many times it fires.
  CONSTRAINT alerts_dedupe_uq UNIQUE (asset_type, asset_id, threshold, due_date),
  CONSTRAINT alerts_ack_ck CHECK ((acknowledged_at IS NULL) = (acknowledged_by IS NULL))
);

COMMENT ON TABLE alerts IS
  'Generated alerts. An unresolved SRV is alertable when its station is confirmed and its next due date is exact; needs_mapping flags that the location is not yet pinned.';
COMMENT ON COLUMN alerts.days_left IS
  'Snapshot taken when the alert was generated, used only in the notification body. Live Days Left always comes from the views, never from here.';

CREATE INDEX alerts_open_idx     ON alerts (state, due_date) WHERE state = 'open';
CREATE INDEX alerts_asset_idx    ON alerts (asset_type, asset_id);
CREATE INDEX alerts_station_idx  ON alerts (station_id, state);
CREATE INDEX alerts_region_idx   ON alerts (region_id, state);
CREATE INDEX alerts_mapping_idx  ON alerts (needs_mapping) WHERE needs_mapping;

-- ---------------------------------------------------------------------------
-- notification_preferences / push_subscriptions / notification_deliveries
-- ---------------------------------------------------------------------------

CREATE TABLE notification_preferences (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_user_id  uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  subject      alert_subject NULL,        -- NULL = applies to every subject
  channel      notification_channel NOT NULL,
  is_enabled   boolean NOT NULL DEFAULT true,
  min_threshold alert_threshold NULL,     -- quieten low-urgency notices
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- One preference per (user, subject, channel); the NULL-subject default needs
-- its own partial index because NULL never equals NULL in a UNIQUE constraint.
CREATE UNIQUE INDEX notif_pref_subject_uq ON notification_preferences (app_user_id, subject, channel)
  WHERE subject IS NOT NULL;
CREATE UNIQUE INDEX notif_pref_default_uq ON notification_preferences (app_user_id, channel)
  WHERE subject IS NULL;

CREATE TABLE push_subscriptions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_user_id  uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  endpoint     text NOT NULL UNIQUE,
  p256dh       text NOT NULL,
  auth         text NOT NULL,
  user_agent   text NULL,
  is_active    boolean NOT NULL DEFAULT true,
  last_success_at timestamptz NULL,
  last_failure_at timestamptz NULL,
  failure_count   integer NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT push_subscriptions_failures_ck CHECK (failure_count >= 0)
);

COMMENT ON TABLE push_subscriptions IS
  'Web Push subscriptions, using THIS project''s own VAPID keys. Pruned on 404/410 responses. Keys stored here are per-browser subscription secrets, not the project VAPID private key, which lives only in Edge Function secrets.';

CREATE TABLE notification_deliveries (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  alert_id      uuid NOT NULL REFERENCES alerts(id) ON DELETE RESTRICT,
  app_user_id   uuid NOT NULL REFERENCES app_users(id) ON DELETE RESTRICT,
  channel       notification_channel NOT NULL,
  status        delivery_status NOT NULL DEFAULT 'pending',
  provider_message_id text NULL,
  error_detail  text NULL,
  attempted_at  timestamptz NOT NULL DEFAULT now(),
  delivered_at  timestamptz NULL,

  -- A given alert is delivered to a given user on a given channel exactly once.
  -- This is the second half of the anti-duplication story: alerts_dedupe_uq
  -- stops duplicate alerts, this stops duplicate sends of one alert.
  CONSTRAINT notif_delivery_uq UNIQUE (alert_id, app_user_id, channel)
);

CREATE INDEX notif_deliveries_alert_idx  ON notification_deliveries (alert_id);
CREATE INDEX notif_deliveries_status_idx ON notification_deliveries (status, attempted_at)
  WHERE status IN ('pending', 'failed');

CREATE TRIGGER alert_rules_set_updated_at BEFORE UPDATE ON alert_rules
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER alerts_set_updated_at BEFORE UPDATE ON alerts
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER notif_pref_set_updated_at BEFORE UPDATE ON notification_preferences
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER push_subs_set_updated_at BEFORE UPDATE ON push_subscriptions
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
