-- SRV warehouse workflow (owner request 2026-09-23).
--
-- 1. WAREHOUSE CODE FOLLOWS STATUS (owner rule): the code is <base><suffix><rest>, where <base> is the
--    first two letters, and the suffix is '' for available_new, 'C' for available_calibrated and 'U'
--    for available_in_store_uc ("MB 9" / "MBC 9" / "MBU 9"; "KC 17" / "KCC 17" / "KCU 17"). The status
--    is authoritative and the code follows it. A trigger keeps them linked on every insert/update;
--    sent_to_station_* rows keep the code as written. A code that does not have that shape is left
--    alone (shape unknown -> nothing is guessed).
--
-- 2. ISSUE (صرف): an admin issues an available (new or calibrated) warehouse valve to a Unit, and may
--    pick the installed valve it replaces. The issue creates the installed record at that Station/Unit,
--    marks the warehouse record sent_to_station_received, archives the replaced valve (never deletes)
--    and writes it to the SRV Log as "at station". Emergency issues are the same issue with a flag;
--    the Emergency tab lists them.
--
-- 3. SRV LOG: valves that left the warehouse loop and are expected back. Receiving one returns it to
--    warehouse stock as available_in_store_uc.
--
-- 4. CALIBRATION (3rd party): an under-calibration warehouse valve is sent out, comes back awaiting its
--    certificate, and with the certificate becomes available_calibrated with the certificate date as
--    its last calibration date.
--
-- 5. HISTORY: every step writes an append-only srv_history row, so each valve's page shows when it was
--    issued, returned, sent for calibration and certified.
--
-- All mutations are SECURITY DEFINER, admin only (owner ruling: "الادمن بس"), actor derived server-side,
-- audited, and refuse a stale selection with PT409 (HTTP 409, never retried by PostgREST).
-- The data step (code corrections + reconciling sent-to-station stock into the SRV Log) is a separate
-- content-bound 6F preview/commit, service_role only. This migration executes no DML.

-- ============================================================================ code rule
CREATE OR REPLACE FUNCTION cng_srv_code_for(p_code text, p_status warehouse_availability)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
DECLARE m text[]; v_letters text; v_suffix text;
BEGIN
  IF p_code IS NULL OR btrim(p_code) = '' THEN RETURN p_code; END IF;
  v_suffix := CASE p_status WHEN 'available_new' THEN '' WHEN 'available_calibrated' THEN 'C'
                            WHEN 'available_in_store_uc' THEN 'U' END;
  IF v_suffix IS NULL THEN RETURN p_code; END IF;
  m := regexp_match(btrim(p_code), '^([A-Za-z]+)(\s*\d.*)$');
  IF m IS NULL THEN RETURN p_code; END IF;
  v_letters := m[1];
  IF length(v_letters) = 3 AND upper(right(v_letters, 1)) IN ('C', 'U') THEN
    NULL;
  ELSIF length(v_letters) <> 2 THEN
    RETURN p_code;
  END IF;
  IF v_letters = lower(v_letters) THEN v_suffix := lower(v_suffix); END IF;
  RETURN left(v_letters, 2) || v_suffix || m[2];
END;
$$;
COMMENT ON FUNCTION cng_srv_code_for(text, warehouse_availability) IS
  'Owner rule: warehouse code = two-letter base + (new: nothing, calibrated: C, under calibration: U) + number. Codes of any other shape are returned unchanged.';

CREATE OR REPLACE FUNCTION cng_wrv_code_follows_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  NEW.warehouse_code := cng_srv_code_for(NEW.warehouse_code, NEW.availability_status);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS wrv_code_follows_status ON warehouse_relief_valves;
CREATE TRIGGER wrv_code_follows_status
  BEFORE INSERT OR UPDATE OF availability_status, warehouse_code ON warehouse_relief_valves
  FOR EACH ROW EXECUTE FUNCTION cng_wrv_code_follows_status();

-- ============================================================================ tables
CREATE TABLE IF NOT EXISTS srv_issues (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_valve_id          uuid NOT NULL REFERENCES warehouse_relief_valves(id),
  new_installed_valve_id      uuid NOT NULL REFERENCES installed_relief_valves(id),
  replaced_installed_valve_id uuid NULL REFERENCES installed_relief_valves(id),
  region_id                   uuid NOT NULL REFERENCES regions(id),
  station_id                  uuid NOT NULL REFERENCES stations(id),
  unit_id                     uuid NOT NULL REFERENCES units(id),
  is_emergency                boolean NOT NULL DEFAULT false,
  notes                       text NULL,
  issued_by                   uuid NOT NULL REFERENCES app_users(id),
  issued_at                   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS srv_field_log (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reason                      text NOT NULL CHECK (reason IN ('replaced_on_issue', 'reconcile_other_serial', 'reconcile_station_not_found')),
  issue_id                    uuid NULL REFERENCES srv_issues(id),
  installed_valve_id          uuid NULL REFERENCES installed_relief_valves(id),
  warehouse_valve_id          uuid NULL REFERENCES warehouse_relief_valves(id),
  region_id                   uuid NULL REFERENCES regions(id),
  station_id                  uuid NULL REFERENCES stations(id),
  unit_id                     uuid NULL REFERENCES units(id),
  station_name_raw            text NULL,
  is_emergency                boolean NOT NULL DEFAULT false,
  logged_by                   uuid NULL REFERENCES app_users(id),
  logged_at                   timestamptz NOT NULL DEFAULT now(),
  returned_at                 timestamptz NULL,
  returned_by                 uuid NULL REFERENCES app_users(id),
  returned_warehouse_valve_id uuid NULL REFERENCES warehouse_relief_valves(id),
  CONSTRAINT sfl_one_source_ck CHECK (num_nonnulls(installed_valve_id, warehouse_valve_id) = 1),
  CONSTRAINT sfl_issue_shape_ck CHECK ((reason = 'replaced_on_issue') = (issue_id IS NOT NULL AND installed_valve_id IS NOT NULL)),
  CONSTRAINT sfl_returned_shape_ck CHECK ((returned_at IS NULL) = (returned_by IS NULL) AND (returned_at IS NULL) = (returned_warehouse_valve_id IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS sfl_open_installed_uq ON srv_field_log (installed_valve_id) WHERE returned_at IS NULL AND installed_valve_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS sfl_open_warehouse_uq ON srv_field_log (warehouse_valve_id) WHERE returned_at IS NULL AND warehouse_valve_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS srv_calibration_jobs (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_valve_id     uuid NOT NULL REFERENCES warehouse_relief_valves(id),
  status                 text NOT NULL DEFAULT 'sent' CHECK (status IN ('sent', 'returned_awaiting_certificate', 'certified')),
  sent_by                uuid NOT NULL REFERENCES app_users(id),
  sent_at                timestamptz NOT NULL DEFAULT now(),
  returned_by            uuid NULL REFERENCES app_users(id),
  returned_at            timestamptz NULL,
  certified_by           uuid NULL REFERENCES app_users(id),
  certified_at           timestamptz NULL,
  certificate_date       date NULL,
  certificate_number     text NULL,
  next_calibration_date  date NULL,
  CONSTRAINT scj_certified_shape_ck CHECK ((status = 'certified') = (certified_at IS NOT NULL AND certified_by IS NOT NULL AND certificate_date IS NOT NULL)),
  CONSTRAINT scj_returned_shape_ck CHECK (status = 'sent' OR returned_at IS NOT NULL)
);
CREATE UNIQUE INDEX IF NOT EXISTS scj_open_valve_uq ON srv_calibration_jobs (warehouse_valve_id) WHERE status <> 'certified';

CREATE TABLE IF NOT EXISTS srv_history (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  warehouse_valve_id uuid NULL REFERENCES warehouse_relief_valves(id),
  installed_valve_id uuid NULL REFERENCES installed_relief_valves(id),
  region_id          uuid NULL REFERENCES regions(id),
  event              text NOT NULL CHECK (event IN ('issued', 'replaced', 'logged', 'received', 'sent_to_calibration',
                                                     'returned_from_calibration', 'certified', 'code_corrected')),
  summary            text NOT NULL,
  details            jsonb NULL,
  actor_id           uuid NULL REFERENCES app_users(id),
  occurred_at        timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sh_subject_ck CHECK (num_nonnulls(warehouse_valve_id, installed_valve_id) >= 1)
);
CREATE INDEX IF NOT EXISTS sh_warehouse_idx ON srv_history (warehouse_valve_id);
CREATE INDEX IF NOT EXISTS sh_installed_idx ON srv_history (installed_valve_id);

ALTER TABLE srv_issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE srv_field_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE srv_calibration_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE srv_history ENABLE ROW LEVEL SECURITY;

-- Reads follow the data they describe: Station-bearing rows are Region-scoped, warehouse-only rows are
-- readable by any active user (as warehouse stock already is). No write policy and no write grant:
-- the SECURITY DEFINER functions below are the only writers.
DROP POLICY IF EXISTS srv_issues_select ON srv_issues;
CREATE POLICY srv_issues_select ON srv_issues FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR cng_has_region_grant(region_id, false));
DROP POLICY IF EXISTS srv_field_log_select ON srv_field_log;
CREATE POLICY srv_field_log_select ON srv_field_log FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR (region_id IS NOT NULL AND cng_has_region_grant(region_id, false)));
DROP POLICY IF EXISTS srv_calibration_jobs_select ON srv_calibration_jobs;
CREATE POLICY srv_calibration_jobs_select ON srv_calibration_jobs FOR SELECT TO authenticated
  USING ((SELECT cng_current_role()) IS NOT NULL);
DROP POLICY IF EXISTS srv_history_select ON srv_history;
CREATE POLICY srv_history_select ON srv_history FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin())
         OR (region_id IS NULL AND (SELECT cng_current_role()) IS NOT NULL)
         OR (region_id IS NOT NULL AND cng_has_region_grant(region_id, false)));

REVOKE ALL ON srv_issues, srv_field_log, srv_calibration_jobs, srv_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON srv_issues, srv_field_log, srv_calibration_jobs, srv_history TO authenticated;

-- ============================================================================ views
-- Warehouse STOCK: only what is physically in the store (owner: new, calibrated, under calibration),
-- minus anything currently out at the calibration company.
CREATE OR REPLACE VIEW v_srv_warehouse_stock WITH (security_invoker = true) AS
SELECT v.*
  FROM v_warehouse_srv_management v
 WHERE v.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc')
   AND NOT EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = v.id AND j.status <> 'certified');

CREATE OR REPLACE VIEW v_srv_field_log WITH (security_invoker = true) AS
SELECT l.id, l.reason,
       CASE WHEN l.returned_at IS NOT NULL THEN 'returned'
            WHEN l.reason = 'replaced_on_issue' THEN 'at_station'
            ELSE 'location_unconfirmed' END AS status,
       l.is_emergency, l.issue_id, l.installed_valve_id, l.warehouse_valve_id,
       l.region_id, r.name AS region_name, l.station_id, s.station_name, l.station_name_raw,
       coalesce(s.station_name, l.station_name_raw) AS station_display,
       l.unit_id, u.unit_name,
       coalesce(i.serial_number, w.serial_number) AS serial_number,
       coalesce(i.manufacturer, w.manufacturer) AS manufacturer,
       coalesce(i.part_number, w.part_number) AS part_number,
       coalesce(i.warehouse_code, w.warehouse_code) AS warehouse_code,
       coalesce(i.size_type, w.size_type) AS size_type,
       coalesce(i.inlet_size, w.inlet_size) AS inlet_size,
       coalesce(i.outlet_size, w.outlet_size) AS outlet_size,
       coalesce(i.set_pressure_raw, w.set_pressure_raw) AS set_pressure_raw,
       coalesce(i.pressure_min, w.pressure_min) AS pressure_min,
       coalesce(i.pressure_max, w.pressure_max) AS pressure_max,
       coalesce(i.pressure_unit, w.pressure_unit) AS pressure_unit,
       w.warehouse_issue_date,
       l.logged_at, l.returned_at, l.returned_warehouse_valve_id
  FROM srv_field_log l
  LEFT JOIN installed_relief_valves i ON i.id = l.installed_valve_id
  LEFT JOIN warehouse_relief_valves w ON w.id = l.warehouse_valve_id
  LEFT JOIN regions r ON r.id = l.region_id
  LEFT JOIN stations s ON s.id = l.station_id
  LEFT JOIN units u ON u.id = l.unit_id;

CREATE OR REPLACE VIEW v_srv_emergency WITH (security_invoker = true) AS
SELECT e.id, e.issued_at, e.notes,
       e.region_id, r.name AS region_name, e.station_id, s.station_name, e.unit_id, u.unit_name,
       e.warehouse_valve_id, w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.pressure_min, w.pressure_max, w.pressure_unit, w.set_pressure_raw,
       e.replaced_installed_valve_id, o.serial_number AS replaced_serial, o.warehouse_code AS replaced_code,
       l.id AS log_id,
       CASE WHEN l.id IS NULL THEN NULL WHEN l.returned_at IS NOT NULL THEN 'returned' ELSE 'at_station' END AS replaced_status
  FROM srv_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  JOIN units u ON u.id = e.unit_id
  JOIN warehouse_relief_valves w ON w.id = e.warehouse_valve_id
  LEFT JOIN installed_relief_valves o ON o.id = e.replaced_installed_valve_id
  LEFT JOIN srv_field_log l ON l.issue_id = e.id
 WHERE e.is_emergency;

CREATE OR REPLACE VIEW v_srv_calibration WITH (security_invoker = true) AS
SELECT j.id, j.status, j.warehouse_valve_id, w.warehouse_code, w.serial_number, w.manufacturer, w.part_number,
       w.size_type, w.inlet_size, w.outlet_size, w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       j.sent_at, j.returned_at, j.certified_at, j.certificate_date, j.certificate_number, j.next_calibration_date
  FROM srv_calibration_jobs j
  JOIN warehouse_relief_valves w ON w.id = j.warehouse_valve_id;

GRANT SELECT ON v_srv_warehouse_stock, v_srv_field_log, v_srv_emergency, v_srv_calibration TO authenticated;
REVOKE ALL ON v_srv_warehouse_stock, v_srv_field_log, v_srv_emergency, v_srv_calibration FROM anon;

-- ============================================================================ history (read)
-- Every event about this valve, following the links an issue or a return creates between the warehouse
-- record and the installed record of the same physical valve. Imported warehouse issue dates appear as
-- a source event. Runs with the caller's rights.
CREATE OR REPLACE FUNCTION cng_srv_valve_history(p_valve_id uuid)
RETURNS TABLE (occurred_at timestamptz, event text, summary text, actor_name text, from_source boolean)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH RECURSIVE ids(id) AS (
    SELECT p_valve_id
    UNION
    SELECT x.other FROM ids
      JOIN LATERAL (
        SELECT h.installed_valve_id AS other FROM srv_history h WHERE h.warehouse_valve_id = ids.id AND h.installed_valve_id IS NOT NULL
        UNION ALL
        SELECT h.warehouse_valve_id FROM srv_history h WHERE h.installed_valve_id = ids.id AND h.warehouse_valve_id IS NOT NULL
      ) x ON true
  )
  SELECT h.occurred_at, h.event, h.summary, a.full_name, false
    FROM srv_history h LEFT JOIN app_users a ON a.id = h.actor_id
   WHERE h.warehouse_valve_id IN (SELECT id FROM ids) OR h.installed_valve_id IN (SELECT id FROM ids)
  UNION ALL
  SELECT w.warehouse_issue_date::timestamptz, 'issued',
         'Issued from warehouse (source workbook)' || coalesce(' to ' || nullif(w.source_raw->>'assigned_station_raw', ''), ''),
         NULL, true
    FROM warehouse_relief_valves w
   WHERE w.id IN (SELECT id FROM ids) AND w.warehouse_issue_date IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM srv_issues e WHERE e.warehouse_valve_id = w.id)
  ORDER BY 1 DESC NULLS LAST;
$$;
REVOKE ALL ON FUNCTION cng_srv_valve_history(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_valve_history(uuid) TO authenticated;

-- ============================================================================ issue
-- Installed valves at the Unit's Station with the same set pressure: the valves the issued one can replace.
-- A valve whose Station is not yet confirmed is offered when its raw Station name folds to this Station's
-- name in the same Region — a suggestion for the admin to choose, never an assignment.
CREATE OR REPLACE FUNCTION cng_srv_replacement_candidates(p_unit_id uuid, p_warehouse_valve_id uuid)
RETURNS TABLE (id uuid, serial_number text, warehouse_code text, manufacturer text, set_pressure_raw text,
               pressure_min numeric, pressure_max numeric, pressure_unit pressure_unit,
               size_type text, inlet_size text, outlet_size text, location_raw text,
               unit_name text, station_confirmed boolean, next_calibration_date date)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT i.id, i.serial_number, i.warehouse_code, i.manufacturer, i.set_pressure_raw,
         i.pressure_min, i.pressure_max, i.pressure_unit, i.size_type, i.inlet_size, i.outlet_size, i.location_raw,
         iu.unit_name, i.station_id IS NOT NULL, i.next_calibration_date
    FROM units u
    JOIN stations s ON s.id = u.station_id
    JOIN warehouse_relief_valves w ON w.id = p_warehouse_valve_id
    JOIN installed_relief_valves i
      ON i.archived_at IS NULL
     AND (i.station_id = s.id
          OR (i.station_id IS NULL AND i.region_id = s.region_id
              AND cng_normalize_name(i.source_station_name_raw) = s.normalized_name))
     AND (i.unit_id IS NULL OR i.unit_id = u.id)
     AND i.pressure_min IS NOT DISTINCT FROM w.pressure_min
     AND i.pressure_max IS NOT DISTINCT FROM w.pressure_max
     AND i.pressure_unit IS NOT DISTINCT FROM w.pressure_unit
    LEFT JOIN units iu ON iu.id = i.unit_id
   WHERE u.id = p_unit_id
   ORDER BY (i.unit_id = u.id) DESC NULLS LAST, i.serial_number NULLS LAST, i.id;
$$;
REVOKE ALL ON FUNCTION cng_srv_replacement_candidates(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_replacement_candidates(uuid, uuid) TO authenticated;

CREATE OR REPLACE FUNCTION cng_srv_issue(
  p_warehouse_valve_id uuid,
  p_expected_updated_at timestamptz,
  p_unit_id uuid,
  p_replace_installed_valve_id uuid DEFAULT NULL,
  p_emergency boolean DEFAULT false,
  p_notes text DEFAULT NULL)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  w warehouse_relief_valves;
  u units;
  s stations;
  o installed_relief_valves;
  v_new uuid := gen_random_uuid();
  v_issue uuid := gen_random_uuid();
  v_status srv_mapping_status := 'needs_equipment_mapping';
  v_notes text := nullif(btrim(p_notes), '');
BEGIN
  SELECT * INTO w FROM warehouse_relief_valves WHERE id = p_warehouse_valve_id AND archived_at IS NULL FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'warehouse valve not found' USING ERRCODE = '42704'; END IF;
  PERFORM cng_check_precondition(w.updated_at, p_expected_updated_at);
  IF w.availability_status NOT IN ('available_new', 'available_calibrated') THEN
    RAISE EXCEPTION 'only a new or calibrated valve in the store can be issued (this one is %)', w.availability_status
      USING ERRCODE = 'PT409';
  END IF;
  IF EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified') THEN
    RAISE EXCEPTION 'this valve is at the calibration company' USING ERRCODE = 'PT409';
  END IF;

  SELECT * INTO u FROM units WHERE id = p_unit_id AND archived_at IS NULL;
  IF u.id IS NULL THEN RAISE EXCEPTION 'unit not found' USING ERRCODE = '42704'; END IF;
  SELECT * INTO s FROM stations WHERE id = u.station_id;

  IF p_replace_installed_valve_id IS NOT NULL THEN
    SELECT * INTO o FROM installed_relief_valves WHERE id = p_replace_installed_valve_id AND archived_at IS NULL FOR UPDATE;
    IF o.id IS NULL THEN RAISE EXCEPTION 'the valve to replace was not found or was already removed' USING ERRCODE = 'PT409'; END IF;
    IF NOT EXISTS (SELECT 1 FROM cng_srv_replacement_candidates(p_unit_id, p_warehouse_valve_id) c WHERE c.id = o.id) THEN
      RAISE EXCEPTION 'the valve to replace is not at this Unit''s Station with the same set pressure' USING ERRCODE = '22023';
    END IF;
    IF num_nonnulls(o.compressor_id, o.storage_vessel_id, o.dispenser_id) = 1 AND o.unit_id = u.id THEN
      v_status := 'resolved';
    END IF;
  END IF;

  INSERT INTO installed_relief_valves (
    id, region_id, station_id, unit_id, compressor_id, storage_vessel_id, dispenser_id,
    mapping_status, mapping_note, resolved_by, resolved_at, location_raw, expected_parent_kind,
    manufacturer, manufacturer_raw, serial_number, serial_number_raw, serial_status, part_number,
    size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
    last_calibration_raw, last_calibration_date, last_calibration_precision,
    next_calibration_raw, next_calibration_date, next_calibration_precision,
    notes, warehouse_code)
  VALUES (
    v_new, u.region_id, u.station_id, u.id,
    CASE WHEN v_status = 'resolved' THEN o.compressor_id END,
    CASE WHEN v_status = 'resolved' THEN o.storage_vessel_id END,
    CASE WHEN v_status = 'resolved' THEN o.dispenser_id END,
    v_status, 'Issued from the warehouse' || CASE WHEN o.id IS NOT NULL THEN ' in place of another valve' ELSE '' END,
    CASE WHEN v_status = 'resolved' THEN v_actor END, CASE WHEN v_status = 'resolved' THEN now() END,
    o.location_raw, o.expected_parent_kind,
    w.manufacturer, w.manufacturer_raw, w.serial_number, w.serial_number_raw, w.serial_status, w.part_number,
    w.size_type, w.inlet_size, w.outlet_size, w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
    w.last_calibration_raw, w.last_calibration_date, w.last_calibration_precision,
    w.next_calibration_raw, w.next_calibration_date, w.next_calibration_precision,
    v_notes, w.warehouse_code);

  UPDATE warehouse_relief_valves
     SET availability_status = 'sent_to_station_received',
         target_region_id = u.region_id, target_station_id = u.station_id,
         warehouse_issue_date = cng_business_date(), warehouse_issue_precision = 'exact_date', warehouse_issue_raw = NULL
   WHERE id = w.id;

  INSERT INTO srv_issues (id, warehouse_valve_id, new_installed_valve_id, replaced_installed_valve_id,
                          region_id, station_id, unit_id, is_emergency, notes, issued_by)
  VALUES (v_issue, w.id, v_new, o.id, u.region_id, u.station_id, u.id, coalesce(p_emergency, false), v_notes, v_actor);

  INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
  VALUES (w.id, v_new, u.region_id, 'issued',
          format('Issued from warehouse to %s / %s%s', s.station_name, u.unit_name,
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('issue_id', v_issue, 'replaced_installed_valve_id', o.id), v_actor);

  IF o.id IS NOT NULL THEN
    UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = o.id;
    INSERT INTO srv_field_log (reason, issue_id, installed_valve_id, region_id, station_id, unit_id, station_name_raw,
                               is_emergency, logged_by)
    VALUES ('replaced_on_issue', v_issue, o.id, u.region_id, u.station_id, u.id, o.source_station_name_raw,
            coalesce(p_emergency, false), v_actor);
    INSERT INTO srv_history (installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (o.id, u.region_id, 'replaced',
            format('Removed from %s / %s, replaced by serial %s; in the SRV Log, still at the station', s.station_name,
                   u.unit_name, coalesce(w.serial_number, '(none)')),
            jsonb_build_object('issue_id', v_issue, 'new_installed_valve_id', v_new), v_actor);
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_issues', v_issue, v_actor, 'srv_issue',
          format('SRV %s issued to %s / %s%s%s', coalesce(w.serial_number, w.id::text), s.station_name, u.unit_name,
                 CASE WHEN o.id IS NOT NULL THEN ', replacing ' || coalesce(o.serial_number, o.id::text) ELSE '' END,
                 CASE WHEN coalesce(p_emergency, false) THEN ' (emergency)' ELSE '' END),
          jsonb_build_object('availability_status', w.availability_status, 'replaced_installed_valve_id', o.id),
          jsonb_build_object('new_installed_valve_id', v_new, 'unit_id', u.id, 'mapping_status', v_status), now());
  RETURN v_issue;
END;
$$;
REVOKE ALL ON FUNCTION cng_srv_issue(uuid, timestamptz, uuid, uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_issue(uuid, timestamptz, uuid, uuid, boolean, text) TO authenticated;

-- ============================================================================ SRV Log: receive
CREATE OR REPLACE FUNCTION cng_srv_log_receive(p_log_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); l srv_field_log; o installed_relief_valves; v_wh uuid; n int := 0;
BEGIN
  IF p_log_ids IS NULL OR cardinality(p_log_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM srv_field_log WHERE id = ANY (p_log_ids) AND returned_at IS NULL)
     <> (SELECT count(DISTINCT x) FROM unnest(p_log_ids) x) THEN
    RAISE EXCEPTION 'some selected valves were already received or are not in the SRV Log; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  FOR l IN SELECT * FROM srv_field_log WHERE id = ANY (p_log_ids) ORDER BY logged_at, id FOR UPDATE LOOP
    IF l.warehouse_valve_id IS NOT NULL THEN
      v_wh := l.warehouse_valve_id;
      UPDATE warehouse_relief_valves
         SET availability_status = 'available_in_store_uc', target_region_id = NULL, target_station_id = NULL
       WHERE id = v_wh;
    ELSE
      SELECT * INTO o FROM installed_relief_valves WHERE id = l.installed_valve_id;
      v_wh := gen_random_uuid();
      INSERT INTO warehouse_relief_valves (
        id, availability_status, serial_number, serial_number_raw, serial_status, manufacturer, manufacturer_raw,
        part_number, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
        last_calibration_raw, last_calibration_date, last_calibration_precision,
        next_calibration_raw, next_calibration_date, next_calibration_precision, warehouse_code, notes)
      VALUES (
        v_wh, 'available_in_store_uc', o.serial_number, o.serial_number_raw, o.serial_status, o.manufacturer, o.manufacturer_raw,
        o.part_number, o.size_type, o.inlet_size, o.outlet_size, o.set_pressure_raw, o.pressure_min, o.pressure_max, o.pressure_unit,
        o.last_calibration_raw, o.last_calibration_date, o.last_calibration_precision,
        o.next_calibration_raw, o.next_calibration_date, o.next_calibration_precision,
        coalesce(o.warehouse_code, (SELECT vi.warehouse_code FROM v_installed_srv_management vi WHERE vi.id = o.id)),
        'Returned from the station (SRV Log)');
    END IF;
    UPDATE srv_field_log SET returned_at = now(), returned_by = v_actor, returned_warehouse_valve_id = v_wh WHERE id = l.id;
    INSERT INTO srv_history (warehouse_valve_id, installed_valve_id, region_id, event, summary, details, actor_id)
    VALUES (v_wh, l.installed_valve_id, NULL, 'received',
            'Received back at the warehouse; now available, under calibration',
            jsonb_build_object('log_id', l.id, 'from_region_id', l.region_id, 'from_station_id', l.station_id), v_actor);
    n := n + 1;
  END LOOP;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_field_log', NULL, v_actor, 'srv_log_receive',
          format('%s SRV(s) received back at the warehouse from the SRV Log', n), NULL,
          jsonb_build_object('log_ids', to_jsonb(p_log_ids)), now());
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION cng_srv_log_receive(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_log_receive(uuid[]) TO authenticated;

-- ============================================================================ calibration
CREATE OR REPLACE FUNCTION cng_srv_calibration_send(p_warehouse_valve_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_warehouse_valve_ids IS NULL OR cardinality(p_warehouse_valve_ids) = 0 THEN
    RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM warehouse_relief_valves WHERE id = ANY (p_warehouse_valve_ids) FOR UPDATE;
  IF (SELECT count(*) FROM warehouse_relief_valves w
       WHERE w.id = ANY (p_warehouse_valve_ids) AND w.archived_at IS NULL AND w.availability_status = 'available_in_store_uc'
         AND NOT EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified'))
     <> (SELECT count(DISTINCT x) FROM unnest(p_warehouse_valve_ids) x) THEN
    RAISE EXCEPTION 'only valves in the store under calibration, not already at the calibration company, can be sent; reload and try again'
      USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO srv_calibration_jobs (warehouse_valve_id, sent_by)
  SELECT DISTINCT x, v_actor FROM unnest(p_warehouse_valve_ids) x;
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO srv_history (warehouse_valve_id, event, summary, actor_id)
  SELECT DISTINCT x, 'sent_to_calibration', 'Sent to the calibration company', v_actor FROM unnest(p_warehouse_valve_ids) x;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_calibration_jobs', NULL, v_actor, 'srv_calibration',
          format('%s SRV(s) sent to the calibration company', n), NULL,
          jsonb_build_object('warehouse_valve_ids', to_jsonb(p_warehouse_valve_ids)), now());
  RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION cng_srv_calibration_returned(p_job_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_job_ids IS NULL OR cardinality(p_job_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  PERFORM 1 FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) AND status = 'sent')
     <> (SELECT count(DISTINCT x) FROM unnest(p_job_ids) x) THEN
    RAISE EXCEPTION 'only valves still at the calibration company can be marked returned; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  UPDATE srv_calibration_jobs SET status = 'returned_awaiting_certificate', returned_at = now(), returned_by = v_actor
   WHERE id = ANY (p_job_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO srv_history (warehouse_valve_id, event, summary, actor_id)
  SELECT warehouse_valve_id, 'returned_from_calibration', 'Returned from the calibration company; certificate awaited', v_actor
    FROM srv_calibration_jobs WHERE id = ANY (p_job_ids);
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_calibration_jobs', NULL, v_actor, 'srv_calibration',
          format('%s SRV(s) returned from calibration, certificate awaited', n), NULL,
          jsonb_build_object('job_ids', to_jsonb(p_job_ids)), now());
  RETURN n;
END;
$$;

-- The certificate date becomes the valve's last calibration date (exact). The next due date is set only
-- when the admin enters it; otherwise it is unknown — no calibration interval is invented.
CREATE OR REPLACE FUNCTION cng_srv_calibration_certify(p_job_ids uuid[], p_certificate_date date,
                                                       p_certificate_number text DEFAULT NULL,
                                                       p_next_calibration_date date DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_job_ids IS NULL OR cardinality(p_job_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  IF p_certificate_date IS NULL THEN RAISE EXCEPTION 'the certificate date is required' USING ERRCODE = '22023'; END IF;
  IF p_certificate_date > cng_business_date() THEN RAISE EXCEPTION 'the certificate date cannot be in the future' USING ERRCODE = '22023'; END IF;
  IF p_next_calibration_date IS NOT NULL AND p_next_calibration_date <= p_certificate_date THEN
    RAISE EXCEPTION 'the next calibration date must be after the certificate date' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) AND status <> 'certified')
     <> (SELECT count(DISTINCT x) FROM unnest(p_job_ids) x) THEN
    RAISE EXCEPTION 'some selected valves are already certified; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  UPDATE srv_calibration_jobs
     SET status = 'certified', returned_at = coalesce(returned_at, now()), returned_by = coalesce(returned_by, v_actor),
         certified_at = now(), certified_by = v_actor, certificate_date = p_certificate_date,
         certificate_number = nullif(btrim(p_certificate_number), ''), next_calibration_date = p_next_calibration_date
   WHERE id = ANY (p_job_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE warehouse_relief_valves w
     SET availability_status = 'available_calibrated',
         last_calibration_date = p_certificate_date, last_calibration_precision = 'exact_date',
         last_calibration_raw = NULL,
         next_calibration_date = p_next_calibration_date,
         next_calibration_precision = CASE WHEN p_next_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
         next_calibration_raw = NULL, source_status_raw = NULL
    FROM srv_calibration_jobs j
   WHERE j.id = ANY (p_job_ids) AND w.id = j.warehouse_valve_id;
  INSERT INTO srv_history (warehouse_valve_id, event, summary, details, actor_id)
  SELECT warehouse_valve_id, 'certified',
         format('Certificate received (dated %s%s); now available, calibrated', p_certificate_date,
                coalesce(', no. ' || nullif(btrim(p_certificate_number), ''), '')),
         jsonb_build_object('job_id', id, 'next_calibration_date', p_next_calibration_date), v_actor
    FROM srv_calibration_jobs WHERE id = ANY (p_job_ids);
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'srv_calibration_jobs', NULL, v_actor, 'srv_calibration',
          format('%s SRV(s) certified (certificate dated %s)', n, p_certificate_date), NULL,
          jsonb_build_object('job_ids', to_jsonb(p_job_ids), 'certificate_date', p_certificate_date,
                             'certificate_number', p_certificate_number, 'next_calibration_date', p_next_calibration_date), now());
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION cng_srv_calibration_send(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_calibration_send(uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION cng_srv_calibration_returned(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_calibration_returned(uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION cng_srv_calibration_certify(uuid[], date, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_calibration_certify(uuid[], date, text, date) TO authenticated;

-- ============================================================================ 6F data step
-- (a) Warehouse codes that disagree with their status are corrected to the owner rule.
-- (b) Sent-to-station stock is reconciled against the SRVs recorded at the Station it was sent to
--     (same Region, Station name folded; the Station's recorded valves are those whose confirmed Station
--     or raw source Station name folds to it):
--       same serial recorded there        -> nothing is logged;
--       Station has valves, not this one  -> SRV Log, reason reconcile_other_serial (the Station's own
--                                            record is left as it is);
--       no valves recorded for that name  -> SRV Log, reason reconcile_station_not_found.
CREATE OR REPLACE FUNCTION cng_6f_warehouse_proposal()
RETURNS TABLE (kind text, warehouse_valve_id uuid, old_code text, new_code text,
               region_id uuid, station_id uuid, station_name_raw text)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH inst AS MATERIALIZED (
    SELECT i.region_id, coalesce(s.normalized_name, cng_normalize_name(i.source_station_name_raw)) AS st,
           cng_normalize_name(i.source_station_name_raw) AS st_raw, lower(btrim(i.serial_number)) AS sn
      FROM installed_relief_valves i LEFT JOIN stations s ON s.id = i.station_id
     WHERE i.archived_at IS NULL
  ),
  sent AS MATERIALIZED (
    SELECT w.id, w.target_region_id AS region_id, w.source_raw->>'assigned_station_raw' AS raw,
           cng_normalize_name(w.source_raw->>'assigned_station_raw') AS st, lower(btrim(w.serial_number)) AS sn
      FROM warehouse_relief_valves w
     WHERE w.archived_at IS NULL AND w.availability_status IN ('sent_to_station_received', 'sent_to_station_not_received')
       AND NOT EXISTS (SELECT 1 FROM srv_field_log l WHERE l.warehouse_valve_id = w.id)
  ),
  classified AS (
    SELECT se.*,
           EXISTS (SELECT 1 FROM inst i WHERE i.region_id = se.region_id AND (i.st = se.st OR i.st_raw = se.st) AND i.sn = se.sn) AS same_serial,
           EXISTS (SELECT 1 FROM inst i WHERE i.region_id = se.region_id AND (i.st = se.st OR i.st_raw = se.st)) AS station_has_valves
      FROM sent se
  )
  SELECT 'code_fix', w.id, w.warehouse_code, cng_srv_code_for(w.warehouse_code, w.availability_status), NULL::uuid, NULL::uuid, NULL
    FROM warehouse_relief_valves w
   WHERE w.archived_at IS NULL AND w.warehouse_code IS DISTINCT FROM cng_srv_code_for(w.warehouse_code, w.availability_status)
  UNION ALL
  SELECT CASE WHEN c.station_has_valves THEN 'log_other_serial' ELSE 'log_station_not_found' END,
         c.id, NULL, NULL, c.region_id,
         (SELECT s.id FROM stations s WHERE s.region_id = c.region_id AND s.normalized_name = c.st AND s.archived_at IS NULL),
         c.raw
    FROM classified c
   WHERE c.region_id IS NOT NULL AND c.st IS NOT NULL AND NOT c.same_serial
  ORDER BY 1, 2;
$$;

CREATE OR REPLACE FUNCTION cng_6f_warehouse_preview()
RETURNS TABLE (preview_fingerprint text, code_fixes int, log_other_serial int, log_station_not_found int,
               log_with_canonical_station int, sent_to_station_total int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT * FROM cng_6f_warehouse_proposal())
  SELECT encode(sha256(convert_to('6F|' || coalesce((SELECT string_agg(concat_ws('|', kind, warehouse_valve_id, old_code, new_code,
           region_id, station_id, station_name_raw), E'\n' ORDER BY kind, warehouse_valve_id) FROM p), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM p WHERE kind = 'code_fix')::int,
         (SELECT count(*) FROM p WHERE kind = 'log_other_serial')::int,
         (SELECT count(*) FROM p WHERE kind = 'log_station_not_found')::int,
         (SELECT count(*) FROM p WHERE kind LIKE 'log%' AND station_id IS NOT NULL)::int,
         (SELECT count(*) FROM warehouse_relief_valves w WHERE w.archived_at IS NULL
             AND w.availability_status IN ('sent_to_station_received', 'sent_to_station_not_received'))::int;
$$;

CREATE OR REPLACE FUNCTION cng_6f_warehouse_commit(p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (codes_corrected int, logged int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; v_codes int; v_logs int; e_codes int; e_logs int;
BEGIN
  IF nullif(btrim(p_expected_preview_fingerprint), '') IS NULL THEN
    RAISE EXCEPTION '6f commit requires the approved preview fingerprint' USING ERRCODE = '22023';
  END IF;
  SELECT pv.preview_fingerprint, pv.code_fixes, pv.log_other_serial + pv.log_station_not_found
    INTO v_fp, e_codes, e_logs FROM cng_6f_warehouse_preview() pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6f commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6f ON COMMIT DROP AS SELECT * FROM cng_6f_warehouse_proposal();

  UPDATE warehouse_relief_valves w SET warehouse_code = p.new_code
    FROM _6f p WHERE p.kind = 'code_fix' AND w.id = p.warehouse_valve_id;
  GET DIAGNOSTICS v_codes = ROW_COUNT;
  INSERT INTO srv_history (warehouse_valve_id, event, summary, details)
  SELECT warehouse_valve_id, 'code_corrected', format('Warehouse code %s -> %s to match its status', old_code, new_code),
         jsonb_build_object('old_code', old_code, 'new_code', new_code)
    FROM _6f WHERE kind = 'code_fix';

  INSERT INTO srv_field_log (reason, warehouse_valve_id, region_id, station_id, station_name_raw)
  SELECT CASE kind WHEN 'log_other_serial' THEN 'reconcile_other_serial' ELSE 'reconcile_station_not_found' END,
         warehouse_valve_id, region_id, station_id, station_name_raw
    FROM _6f WHERE kind LIKE 'log%';
  GET DIAGNOSTICS v_logs = ROW_COUNT;
  INSERT INTO srv_history (warehouse_valve_id, region_id, event, summary)
  SELECT warehouse_valve_id, region_id, 'logged',
         CASE kind WHEN 'log_other_serial'
           THEN 'In the SRV Log: sent to ' || coalesce(station_name_raw, '?') || ', but that Station records a different valve'
           ELSE 'In the SRV Log: sent to ' || coalesce(station_name_raw, '?') || ', which has no valves recorded; location unconfirmed' END
    FROM _6f WHERE kind LIKE 'log%';

  IF v_codes <> e_codes OR v_logs <> e_logs THEN
    RAISE EXCEPTION '6f commit refused: % codes / % log rows written, % / % expected', v_codes, v_logs, e_codes, e_logs
      USING ERRCODE = '40001';
  END IF;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'warehouse_relief_valves', NULL, NULL, 'service_role:warehouse_6f',
          format('Phase 6f: %s warehouse codes corrected to the status rule; %s sent-to-station valves placed in the SRV Log. %s',
                 v_codes, v_logs, coalesce(p_reason, '')),
          NULL, jsonb_build_object('preview_fingerprint', v_fp, 'codes_corrected', v_codes, 'logged', v_logs), now());
  RETURN QUERY SELECT v_codes, v_logs, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6f_warehouse_proposal(), cng_6f_warehouse_preview(), cng_6f_warehouse_commit(text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6f_warehouse_proposal(), cng_6f_warehouse_preview(), cng_6f_warehouse_commit(text, text)
  TO service_role;
