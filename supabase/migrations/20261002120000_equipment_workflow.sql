-- Hoses and Gas Detectors get the relief-valve workflow (owner request 2026-10-02): the same five tabs —
-- Installed, Warehouse, Log, Calibration / Hydrotest (3rd party), Emergency — with the same steps.
--
-- ONE design for both kinds, keyed by `kind` ('hose' | 'gas_detector'), rather than two copies of the SRV tables:
--
--   equipment_stock             the store: new, calibrated (tested), under calibration (testing)
--   equipment_issues            issue (صرف) from the store to a Station (and Unit, when known); emergency is a flag
--   equipment_field_log         the item an issue replaced: still at the station, expected back
--   equipment_calibration_jobs  sent to the 3rd party -> returned awaiting certificate -> certified
--   equipment_history           every step, append-only
--
-- The installed records stay where they are (`hoses`, `gas_detectors`). An issue CREATES the installed record at the
-- chosen Station, archives (never deletes) the one it replaces and logs it; receiving it back puts it in the store as
-- under calibration; the certificate date becomes its last calibration / test date. Hoses keep their own words: a
-- hose is TESTED (hydrotest), never "calibrated" — the schema's last_test/next_test columns are written for hoses.
--
-- Same safety shape as the SRV workflow: every write is an admin-only SECURITY DEFINER function, actor derived
-- server-side, audited, stale selections refused with PT409. No write policy and no write grant exist on any table.
-- Station-bearing rows are Region-scoped; store and 3rd-party rows are readable by any active user (as SRV stock is).
-- No next date is ever invented: it is set only when the admin enters it. This migration executes no DML.
--
-- Part 1 of 3 (tables, policies, views, history); 20261002120100 adds/issues, 20261002120200 the Log and 3rd party.

-- ============================================================================ tables
CREATE TABLE IF NOT EXISTS equipment_stock (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                    text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  availability_status     warehouse_availability NOT NULL DEFAULT 'available_new',
  serial_number           text NULL,
  serial_status           serial_status NOT NULL DEFAULT 'unknown',
  manufacturer            text NULL,
  model                   text NULL,
  description             text NULL,
  working_pressure_value  numeric NULL CHECK (working_pressure_value IS NULL OR working_pressure_value >= 0),
  working_pressure_unit   pressure_unit NULL,
  test_pressure_value     numeric NULL CHECK (test_pressure_value IS NULL OR test_pressure_value >= 0),
  test_pressure_unit      pressure_unit NULL,
  last_date               date NULL,
  last_precision          date_precision NOT NULL DEFAULT 'unknown',
  next_date               date NULL,
  next_precision          date_precision NOT NULL DEFAULT 'unknown',
  warehouse_code          text NULL,
  notes                   text NULL,
  target_region_id        uuid NULL REFERENCES regions(id),
  target_station_id       uuid NULL REFERENCES stations(id),
  created_by              uuid NULL REFERENCES app_users(id),
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  archived_at             timestamptz NULL,
  archived_by             uuid NULL REFERENCES app_users(id),
  CONSTRAINT es_last_prec_ck CHECK ((last_precision = 'exact_date') = (last_date IS NOT NULL)),
  CONSTRAINT es_next_prec_ck CHECK ((next_precision = 'exact_date') = (next_date IS NOT NULL)),
  -- A hose has no model; a detector has no description or pressures (the installed tables say the same).
  CONSTRAINT es_kind_fields_ck CHECK (
    (kind = 'hose' AND model IS NULL)
    OR (kind = 'gas_detector' AND description IS NULL AND working_pressure_value IS NULL AND working_pressure_unit IS NULL
        AND test_pressure_value IS NULL AND test_pressure_unit IS NULL)),
  CONSTRAINT es_serial_status_ck CHECK (serial_number IS NULL OR serial_status = 'assigned')
);
CREATE INDEX IF NOT EXISTS es_kind_idx ON equipment_stock (kind, availability_status) WHERE archived_at IS NULL;
CREATE TRIGGER es_set_updated_at BEFORE UPDATE ON equipment_stock FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();

CREATE TABLE IF NOT EXISTS equipment_issues (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                      text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  stock_id                  uuid NOT NULL REFERENCES equipment_stock(id),
  new_hose_id               uuid NULL REFERENCES hoses(id),
  new_gas_detector_id       uuid NULL REFERENCES gas_detectors(id),
  replaced_hose_id          uuid NULL REFERENCES hoses(id),
  replaced_gas_detector_id  uuid NULL REFERENCES gas_detectors(id),
  region_id                 uuid NOT NULL REFERENCES regions(id),
  station_id                uuid NOT NULL REFERENCES stations(id),
  unit_id                   uuid NULL REFERENCES units(id),
  is_emergency              boolean NOT NULL DEFAULT false,
  notes                     text NULL,
  issued_by                 uuid NOT NULL REFERENCES app_users(id),
  issued_at                 timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ei_kind_shape_ck CHECK (
    (kind = 'hose' AND new_hose_id IS NOT NULL AND new_gas_detector_id IS NULL AND replaced_gas_detector_id IS NULL)
    OR (kind = 'gas_detector' AND new_gas_detector_id IS NOT NULL AND new_hose_id IS NULL AND replaced_hose_id IS NULL))
);

CREATE TABLE IF NOT EXISTS equipment_field_log (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                     text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  reason                   text NOT NULL DEFAULT 'replaced_on_issue' CHECK (reason IN ('replaced_on_issue')),
  issue_id                 uuid NOT NULL REFERENCES equipment_issues(id),
  installed_hose_id        uuid NULL REFERENCES hoses(id),
  installed_gas_detector_id uuid NULL REFERENCES gas_detectors(id),
  region_id                uuid NOT NULL REFERENCES regions(id),
  station_id               uuid NOT NULL REFERENCES stations(id),
  unit_id                  uuid NULL REFERENCES units(id),
  is_emergency             boolean NOT NULL DEFAULT false,
  logged_by                uuid NOT NULL REFERENCES app_users(id),
  logged_at                timestamptz NOT NULL DEFAULT now(),
  returned_at              timestamptz NULL,
  returned_by              uuid NULL REFERENCES app_users(id),
  returned_stock_id        uuid NULL REFERENCES equipment_stock(id),
  CONSTRAINT efl_kind_shape_ck CHECK (
    (kind = 'hose' AND installed_hose_id IS NOT NULL AND installed_gas_detector_id IS NULL)
    OR (kind = 'gas_detector' AND installed_gas_detector_id IS NOT NULL AND installed_hose_id IS NULL)),
  CONSTRAINT efl_returned_shape_ck CHECK ((returned_at IS NULL) = (returned_by IS NULL)
                                          AND (returned_at IS NULL) = (returned_stock_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS efl_open_hose_uq ON equipment_field_log (installed_hose_id)
  WHERE returned_at IS NULL AND installed_hose_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS efl_open_detector_uq ON equipment_field_log (installed_gas_detector_id)
  WHERE returned_at IS NULL AND installed_gas_detector_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS equipment_calibration_jobs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind                text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  stock_id            uuid NOT NULL REFERENCES equipment_stock(id),
  status              text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'returned_awaiting_certificate', 'certified')),
  sent_by             uuid NOT NULL REFERENCES app_users(id),
  sent_at             timestamptz NOT NULL DEFAULT now(),
  returned_by         uuid NULL REFERENCES app_users(id),
  returned_at         timestamptz NULL,
  certified_by        uuid NULL REFERENCES app_users(id),
  certified_at        timestamptz NULL,
  certificate_date    date NULL,
  certificate_number  text NULL,
  next_date           date NULL,
  CONSTRAINT ecj_certified_shape_ck CHECK ((status = 'certified') = (certified_at IS NOT NULL AND certified_by IS NOT NULL AND certificate_date IS NOT NULL)),
  CONSTRAINT ecj_returned_shape_ck CHECK (status = 'sent' OR returned_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS ecj_open_stock_uq ON equipment_calibration_jobs (stock_id) WHERE status <> 'certified';

CREATE TABLE IF NOT EXISTS equipment_history (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind              text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  stock_id          uuid NULL REFERENCES equipment_stock(id),
  hose_id           uuid NULL REFERENCES hoses(id),
  gas_detector_id   uuid NULL REFERENCES gas_detectors(id),
  region_id         uuid NULL REFERENCES regions(id),
  event             text NOT NULL CHECK (event IN ('added', 'issued', 'replaced', 'received', 'sent_to_calibration',
                                                   'returned_from_calibration', 'certified')),
  summary           text NOT NULL,
  details           jsonb NULL,
  actor_id          uuid NULL REFERENCES app_users(id),
  occurred_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT eh_subject_ck CHECK (num_nonnulls(stock_id, hose_id, gas_detector_id) >= 1)
);
CREATE INDEX IF NOT EXISTS eh_stock_idx ON equipment_history (stock_id);
CREATE INDEX IF NOT EXISTS eh_hose_idx ON equipment_history (hose_id);
CREATE INDEX IF NOT EXISTS eh_detector_idx ON equipment_history (gas_detector_id);

ALTER TABLE equipment_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_field_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_calibration_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE equipment_history ENABLE ROW LEVEL SECURITY;

CREATE POLICY equipment_stock_select ON equipment_stock FOR SELECT TO authenticated
  USING ((SELECT cng_current_role()) IS NOT NULL);
CREATE POLICY equipment_issues_select ON equipment_issues FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR cng_has_region_grant(region_id, false));
CREATE POLICY equipment_field_log_select ON equipment_field_log FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR cng_has_region_grant(region_id, false));
CREATE POLICY equipment_calibration_jobs_select ON equipment_calibration_jobs FOR SELECT TO authenticated
  USING ((SELECT cng_current_role()) IS NOT NULL);
CREATE POLICY equipment_history_select ON equipment_history FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin())
         OR (region_id IS NULL AND (SELECT cng_current_role()) IS NOT NULL)
         OR (region_id IS NOT NULL AND cng_has_region_grant(region_id, false)));

REVOKE ALL ON equipment_stock, equipment_issues, equipment_field_log, equipment_calibration_jobs, equipment_history
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON equipment_stock, equipment_issues, equipment_field_log, equipment_calibration_jobs, equipment_history
  TO authenticated;

-- ============================================================================ views
-- The store: new, calibrated and under calibration, minus anything out at the 3rd party. Due state is computed by
-- the alert engine's own functions, so it means what it means everywhere else.
CREATE OR REPLACE VIEW v_equipment_stock WITH (security_invoker = true) AS
SELECT e.id, e.kind, e.availability_status, e.serial_number, e.serial_status, e.manufacturer, e.model, e.description,
       e.working_pressure_value, e.working_pressure_unit, e.test_pressure_value, e.test_pressure_unit,
       e.last_date, e.last_precision, e.next_date, e.next_precision,
       public.cng_days_left(e.next_date, e.next_precision) AS days_left,
       public.cng_due_status(e.next_date, e.next_precision) AS due_status,
       e.warehouse_code, e.notes, e.created_at, e.updated_at
  FROM equipment_stock e
 WHERE e.archived_at IS NULL
   AND e.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc')
   AND NOT EXISTS (SELECT 1 FROM equipment_calibration_jobs j WHERE j.stock_id = e.id AND j.status <> 'certified');

CREATE OR REPLACE VIEW v_equipment_field_log WITH (security_invoker = true) AS
SELECT l.id, l.kind,
       CASE WHEN l.returned_at IS NOT NULL THEN 'returned' ELSE 'at_station' END AS status,
       l.is_emergency, l.issue_id, l.installed_hose_id, l.installed_gas_detector_id,
       l.region_id, r.name AS region_name, l.station_id, s.station_name, l.unit_id, u.unit_name,
       coalesce(h.serial_number, g.serial_number) AS serial_number,
       g.manufacturer, g.model, h.description,
       h.working_pressure_value, h.working_pressure_unit,
       coalesce(h.last_test_date, g.last_calibration_date) AS last_date,
       l.logged_at, l.returned_at, l.returned_stock_id
  FROM equipment_field_log l
  JOIN regions r ON r.id = l.region_id
  JOIN stations s ON s.id = l.station_id
  LEFT JOIN units u ON u.id = l.unit_id
  LEFT JOIN hoses h ON h.id = l.installed_hose_id
  LEFT JOIN gas_detectors g ON g.id = l.installed_gas_detector_id;

CREATE OR REPLACE VIEW v_equipment_emergency WITH (security_invoker = true) AS
SELECT e.id, e.kind, e.issued_at, e.notes,
       e.region_id, r.name AS region_name, e.station_id, s.station_name, e.unit_id, u.unit_name,
       e.stock_id, w.serial_number AS issued_serial, w.warehouse_code AS issued_code, w.manufacturer, w.model, w.description,
       coalesce(rh.serial_number, rg.serial_number) AS replaced_serial,
       CASE WHEN l.id IS NULL THEN NULL WHEN l.returned_at IS NOT NULL THEN 'returned' ELSE 'at_station' END AS replaced_status
  FROM equipment_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  LEFT JOIN units u ON u.id = e.unit_id
  JOIN equipment_stock w ON w.id = e.stock_id
  LEFT JOIN hoses rh ON rh.id = e.replaced_hose_id
  LEFT JOIN gas_detectors rg ON rg.id = e.replaced_gas_detector_id
  LEFT JOIN equipment_field_log l ON l.issue_id = e.id
 WHERE e.is_emergency;

CREATE OR REPLACE VIEW v_equipment_calibration WITH (security_invoker = true) AS
SELECT j.id, j.kind, j.status, j.stock_id, w.warehouse_code, w.serial_number, w.manufacturer, w.model, w.description,
       w.working_pressure_value, w.working_pressure_unit,
       j.sent_at, j.returned_at, j.certified_at, j.certificate_date, j.certificate_number, j.next_date
  FROM equipment_calibration_jobs j
  JOIN equipment_stock w ON w.id = j.stock_id;

REVOKE ALL ON v_equipment_stock, v_equipment_field_log, v_equipment_emergency, v_equipment_calibration FROM PUBLIC, anon;
GRANT SELECT ON v_equipment_stock, v_equipment_field_log, v_equipment_emergency, v_equipment_calibration TO authenticated;

-- ============================================================================ history (read)
-- Every step of one item, following the links an issue or a return makes between its store record and its
-- installed record. Runs with the caller's rights.
CREATE OR REPLACE FUNCTION cng_equipment_history(p_kind text, p_id uuid)
RETURNS TABLE (occurred_at timestamptz, event text, summary text, actor_name text)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH RECURSIVE ids(id) AS (
    SELECT p_id
    UNION
    SELECT x.other FROM ids
      JOIN LATERAL (
        SELECT coalesce(h.hose_id, h.gas_detector_id) AS other FROM equipment_history h
         WHERE h.kind = p_kind AND h.stock_id = ids.id AND coalesce(h.hose_id, h.gas_detector_id) IS NOT NULL
        UNION ALL
        SELECT h.stock_id FROM equipment_history h
         WHERE h.kind = p_kind AND coalesce(h.hose_id, h.gas_detector_id) = ids.id AND h.stock_id IS NOT NULL
      ) x ON true
  )
  SELECT h.occurred_at, h.event, h.summary, a.full_name
    FROM equipment_history h LEFT JOIN app_users a ON a.id = h.actor_id
   WHERE h.kind = p_kind
     AND (h.stock_id IN (SELECT id FROM ids) OR h.hose_id IN (SELECT id FROM ids) OR h.gas_detector_id IN (SELECT id FROM ids))
   ORDER BY h.occurred_at DESC;
$$;
REVOKE ALL ON FUNCTION cng_equipment_history(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_history(text, uuid) TO authenticated;
