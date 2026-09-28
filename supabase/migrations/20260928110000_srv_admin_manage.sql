-- SRV admin management (owner request 2026-09-28).
--
-- 1. FILTERED SUMMARY: the attention strip on Installed SRVs follows the active filters. One SECURITY INVOKER
--    function counts over v_installed_srv_management with the same predicates the table uses, in one scan, under
--    the caller's own RLS (a count can never reveal rows the caller cannot read).
--
-- 2. DELETE / EDIT (admin only). "Delete" is ARCHIVE — the row is hidden from every list and kept, with who and when
--    (CLAUDE.md §10: no hard deletes). Every function is SECURITY DEFINER with a pinned search_path, derives the
--    actor from cng_require_admin() (never a parameter), and writes one audit row.
--      * SRV Log: archive an entry; restore its installed valve to its station (undo the replacement); move the
--        entry to another Station (and optionally Unit).
--      * 3rd party calibration: archive a job (the valve returns to warehouse stock); edit certificate fields.
--      * Emergency: edit notes; remove from the Emergency list (the issue itself stays).
--      * Installed / warehouse SRV: archive the valve.
-- This migration executes no DML.

ALTER TABLE srv_field_log        ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL, ADD COLUMN IF NOT EXISTS archived_by uuid NULL REFERENCES app_users(id);
ALTER TABLE srv_calibration_jobs ADD COLUMN IF NOT EXISTS archived_at timestamptz NULL, ADD COLUMN IF NOT EXISTS archived_by uuid NULL REFERENCES app_users(id);
ALTER TABLE srv_issues           ADD COLUMN IF NOT EXISTS emergency_removed_at timestamptz NULL, ADD COLUMN IF NOT EXISTS emergency_removed_by uuid NULL REFERENCES app_users(id);

-- An archived log entry or calibration job no longer holds its valve open.
DROP INDEX IF EXISTS sfl_open_installed_uq;
DROP INDEX IF EXISTS sfl_open_warehouse_uq;
CREATE UNIQUE INDEX sfl_open_installed_uq ON srv_field_log (installed_valve_id) WHERE returned_at IS NULL AND archived_at IS NULL AND installed_valve_id IS NOT NULL;
CREATE UNIQUE INDEX sfl_open_warehouse_uq ON srv_field_log (warehouse_valve_id) WHERE returned_at IS NULL AND archived_at IS NULL AND warehouse_valve_id IS NOT NULL;
DROP INDEX IF EXISTS scj_open_valve_uq;
CREATE UNIQUE INDEX scj_open_valve_uq ON srv_calibration_jobs (warehouse_valve_id) WHERE status <> 'certified' AND archived_at IS NULL;

-- ============================================================================ views (archived rows hidden)
CREATE OR REPLACE VIEW v_srv_warehouse_stock WITH (security_invoker = true) AS
SELECT v.*
  FROM v_warehouse_srv_management v
 WHERE v.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc')
   AND NOT EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = v.id AND j.status <> 'certified' AND j.archived_at IS NULL);

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
  LEFT JOIN units u ON u.id = l.unit_id
 WHERE l.archived_at IS NULL;

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
  LEFT JOIN srv_field_log l ON l.issue_id = e.id AND l.archived_at IS NULL
 WHERE e.is_emergency AND e.emergency_removed_at IS NULL;

CREATE OR REPLACE VIEW v_srv_calibration WITH (security_invoker = true) AS
SELECT j.id, j.status, j.warehouse_valve_id, w.warehouse_code, w.serial_number, w.manufacturer, w.part_number,
       w.size_type, w.inlet_size, w.outlet_size, w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       j.sent_at, j.returned_at, j.certified_at, j.certificate_date, j.certificate_number, j.next_calibration_date
  FROM srv_calibration_jobs j
  JOIN warehouse_relief_valves w ON w.id = j.warehouse_valve_id
 WHERE j.archived_at IS NULL;

-- ============================================================================ filtered summary
CREATE OR REPLACE FUNCTION cng_installed_srv_summary_filtered(p jsonb)
RETURNS TABLE (total bigint, overdue bigint, attention bigint, needs_station_mapping bigint,
               needs_unit_mapping bigint, needs_equipment_mapping bigint, conflict bigint)
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $$
  SELECT count(*),
         count(*) FILTER (WHERE m.due_status = 'overdue'),
         count(*) FILTER (WHERE m.due_status IN ('overdue','due_today','due_7','due_15','due_30','due_60')),
         count(*) FILTER (WHERE m.mapping_status = 'needs_station_mapping'),
         count(*) FILTER (WHERE m.mapping_status = 'needs_unit_mapping'),
         count(*) FILTER (WHERE m.mapping_status = 'needs_equipment_mapping'),
         count(*) FILTER (WHERE m.mapping_status = 'conflict')
    FROM v_installed_srv_management m
   WHERE (nullif(p->>'region_id', '') IS NULL OR m.region_id = (p->>'region_id')::uuid)
     AND (nullif(p->>'mapping', '') IS NULL OR m.mapping_status::text = p->>'mapping')
     AND (nullif(p->>'parent_kind', '') IS NULL OR m.parent_kind::text = p->>'parent_kind')
     AND (CASE p->>'due' WHEN 'overdue' THEN m.due_status::text = 'overdue'
                         WHEN 'unknown' THEN m.due_status::text = 'unknown'
                         WHEN 'attention' THEN m.due_status::text IN ('overdue','due_today','due_7','due_15','due_30','due_60')
                         ELSE true END)
     AND (nullif(p->>'serial', '') IS NULL OR m.serial_number ILIKE '%' || (p->>'serial') || '%')
     AND (nullif(p->>'station', '') IS NULL OR m.station_display ILIKE '%' || (p->>'station') || '%')
     AND (nullif(p->>'size_type', '') IS NULL OR m.size_type ILIKE p->>'size_type')
     AND (nullif(p->>'inlet', '') IS NULL OR m.inlet_size ILIKE (p->>'inlet') || '%')
     AND (nullif(p->>'outlet', '') IS NULL OR m.outlet_size ILIKE (p->>'outlet') || '%')
     AND (nullif(p->>'pressure', '') IS NULL OR (m.pressure_min <= (p->>'pressure')::numeric AND m.pressure_max >= (p->>'pressure')::numeric))
     AND (nullif(p->>'pressure_unit', '') IS NULL OR m.pressure_unit::text = p->>'pressure_unit')
     AND (nullif(p->>'search', '') IS NULL
          OR m.serial_number ILIKE '%' || (p->>'search') || '%'
          OR m.part_number ILIKE '%' || (p->>'search') || '%'
          OR m.manufacturer ILIKE '%' || (p->>'search') || '%'
          OR m.tag_number ILIKE '%' || (p->>'search') || '%'
          OR m.station_name ILIKE '%' || (p->>'search') || '%'
          OR m.unit_name ILIKE '%' || (p->>'search') || '%'
          OR m.source_station_name_raw ILIKE '%' || coalesce(nullif(p->>'search_folded', ''), p->>'search') || '%');
$$;
COMMENT ON FUNCTION cng_installed_srv_summary_filtered(jsonb) IS
  'The Installed SRV attention strip for the active filters (same predicates as the table), one scan, SECURITY INVOKER so RLS bounds every count.';
REVOKE ALL ON FUNCTION cng_installed_srv_summary_filtered(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_installed_srv_summary_filtered(jsonb) TO authenticated;

-- ============================================================================ admin actions
CREATE OR REPLACE FUNCTION cng_srv_log_archive(p_log_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); v_before jsonb;
BEGIN
  SELECT to_jsonb(l) INTO v_before FROM srv_field_log l WHERE l.id = p_log_id AND l.archived_at IS NULL FOR UPDATE;
  IF v_before IS NULL THEN RAISE EXCEPTION 'this log entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  UPDATE srv_field_log SET archived_at = now(), archived_by = v_actor WHERE id = p_log_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', 'srv_field_log', p_log_id, v_actor, 'admin_srv_log', format('SRV Log entry removed (archived). %s', coalesce(p_reason, '')),
          v_before, NULL, now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_log_restore_to_station(p_log_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); l srv_field_log;
BEGIN
  SELECT * INTO l FROM srv_field_log WHERE id = p_log_id AND archived_at IS NULL AND returned_at IS NULL FOR UPDATE;
  IF l.id IS NULL THEN RAISE EXCEPTION 'this log entry is no longer open; reload the list' USING ERRCODE = 'PT409'; END IF;
  IF l.installed_valve_id IS NULL THEN
    RAISE EXCEPTION 'this entry has no installed record to put back; move it to a station instead' USING ERRCODE = '22023';
  END IF;
  UPDATE installed_relief_valves SET archived_at = NULL, archived_by = NULL WHERE id = l.installed_valve_id;
  UPDATE srv_field_log SET archived_at = now(), archived_by = v_actor WHERE id = p_log_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_restored', 'installed_relief_valves', l.installed_valve_id, v_actor, 'admin_srv_log',
          format('Valve returned to its station from the SRV Log (log entry archived). %s', coalesce(p_reason, '')),
          to_jsonb(l), jsonb_build_object('installed_valve_id', l.installed_valve_id, 'station_id', l.station_id, 'unit_id', l.unit_id), now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_log_move(p_log_id uuid, p_station_id uuid, p_unit_id uuid DEFAULT NULL, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); l srv_field_log; v_region uuid;
BEGIN
  SELECT * INTO l FROM srv_field_log WHERE id = p_log_id AND archived_at IS NULL FOR UPDATE;
  IF l.id IS NULL THEN RAISE EXCEPTION 'this log entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  SELECT region_id INTO v_region FROM stations WHERE id = p_station_id AND archived_at IS NULL;
  IF v_region IS NULL THEN RAISE EXCEPTION 'station not found' USING ERRCODE = '22023'; END IF;
  IF p_unit_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM units WHERE id = p_unit_id AND station_id = p_station_id AND archived_at IS NULL) THEN
    RAISE EXCEPTION 'that unit is not at the chosen station' USING ERRCODE = '22023';
  END IF;
  UPDATE srv_field_log SET station_id = p_station_id, region_id = v_region, unit_id = p_unit_id WHERE id = p_log_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', 'srv_field_log', p_log_id, v_actor, 'admin_srv_log', format('SRV Log entry moved to another station. %s', coalesce(p_reason, '')),
          jsonb_build_object('station_id', l.station_id, 'region_id', l.region_id, 'unit_id', l.unit_id),
          jsonb_build_object('station_id', p_station_id, 'region_id', v_region, 'unit_id', p_unit_id), now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_calibration_archive(p_job_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); v_before jsonb;
BEGIN
  SELECT to_jsonb(j) INTO v_before FROM srv_calibration_jobs j WHERE j.id = p_job_id AND j.archived_at IS NULL FOR UPDATE;
  IF v_before IS NULL THEN RAISE EXCEPTION 'this calibration entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  UPDATE srv_calibration_jobs SET archived_at = now(), archived_by = v_actor WHERE id = p_job_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', 'srv_calibration_jobs', p_job_id, v_actor, 'admin_srv_calibration',
          format('3rd party calibration entry removed (archived); the valve is back in warehouse stock. %s', coalesce(p_reason, '')), v_before, NULL, now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_calibration_edit(p_job_id uuid, p_certificate_date date, p_certificate_number text,
                                                    p_next_calibration_date date, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); j srv_calibration_jobs;
BEGIN
  SELECT * INTO j FROM srv_calibration_jobs WHERE id = p_job_id AND archived_at IS NULL FOR UPDATE;
  IF j.id IS NULL THEN RAISE EXCEPTION 'this calibration entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  IF j.status = 'certified' AND p_certificate_date IS NULL THEN
    RAISE EXCEPTION 'a certified entry needs a certificate date' USING ERRCODE = '22023';
  END IF;
  UPDATE srv_calibration_jobs SET certificate_date = p_certificate_date, certificate_number = nullif(btrim(p_certificate_number), ''),
         next_calibration_date = p_next_calibration_date WHERE id = p_job_id;
  IF j.status = 'certified' THEN
    UPDATE warehouse_relief_valves SET last_calibration_date = p_certificate_date, last_calibration_precision = 'exact_date',
           next_calibration_date = p_next_calibration_date,
           next_calibration_precision = CASE WHEN p_next_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision
     WHERE id = j.warehouse_valve_id;
  END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', 'srv_calibration_jobs', p_job_id, v_actor, 'admin_srv_calibration', format('3rd party calibration entry edited. %s', coalesce(p_reason, '')),
          jsonb_build_object('certificate_date', j.certificate_date, 'certificate_number', j.certificate_number, 'next_calibration_date', j.next_calibration_date),
          jsonb_build_object('certificate_date', p_certificate_date, 'certificate_number', p_certificate_number, 'next_calibration_date', p_next_calibration_date), now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_emergency_edit(p_issue_id uuid, p_notes text, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); e srv_issues;
BEGIN
  SELECT * INTO e FROM srv_issues WHERE id = p_issue_id AND is_emergency AND emergency_removed_at IS NULL FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'this emergency entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  UPDATE srv_issues SET notes = nullif(btrim(p_notes), '') WHERE id = p_issue_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', 'srv_issues', p_issue_id, v_actor, 'admin_srv_emergency', format('Emergency entry edited. %s', coalesce(p_reason, '')),
          jsonb_build_object('notes', e.notes), jsonb_build_object('notes', p_notes), now());
END; $$;

CREATE OR REPLACE FUNCTION cng_srv_emergency_remove(p_issue_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); e srv_issues;
BEGIN
  SELECT * INTO e FROM srv_issues WHERE id = p_issue_id AND is_emergency AND emergency_removed_at IS NULL FOR UPDATE;
  IF e.id IS NULL THEN RAISE EXCEPTION 'this emergency entry no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
  UPDATE srv_issues SET emergency_removed_at = now(), emergency_removed_by = v_actor WHERE id = p_issue_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', 'srv_issues', p_issue_id, v_actor, 'admin_srv_emergency',
          format('Removed from the Emergency list (the issue record is kept). %s', coalesce(p_reason, '')), to_jsonb(e), NULL, now());
END; $$;

CREATE OR REPLACE FUNCTION cng_admin_archive_srv(p_table text, p_id uuid, p_reason text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE v_actor uuid := cng_require_admin(); v_before jsonb;
BEGIN
  IF p_table = 'installed_relief_valves' THEN
    SELECT to_jsonb(v) INTO v_before FROM installed_relief_valves v WHERE v.id = p_id AND v.archived_at IS NULL FOR UPDATE;
    IF v_before IS NULL THEN RAISE EXCEPTION 'this valve no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
    UPDATE installed_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = p_id;
  ELSIF p_table = 'warehouse_relief_valves' THEN
    SELECT to_jsonb(v) INTO v_before FROM warehouse_relief_valves v WHERE v.id = p_id AND v.archived_at IS NULL FOR UPDATE;
    IF v_before IS NULL THEN RAISE EXCEPTION 'this valve no longer exists; reload the list' USING ERRCODE = 'PT409'; END IF;
    UPDATE warehouse_relief_valves SET archived_at = now(), archived_by = v_actor WHERE id = p_id;
  ELSE
    RAISE EXCEPTION 'only installed or warehouse relief valves can be removed here' USING ERRCODE = '22023';
  END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_deleted', p_table, p_id, v_actor, 'admin_srv_remove', format('Relief valve removed (archived). %s', coalesce(p_reason, '')), v_before, NULL, now());
END; $$;

REVOKE ALL ON FUNCTION cng_srv_log_archive(uuid, text), cng_srv_log_restore_to_station(uuid, text), cng_srv_log_move(uuid, uuid, uuid, text),
                       cng_srv_calibration_archive(uuid, text), cng_srv_calibration_edit(uuid, date, text, date, text),
                       cng_srv_emergency_edit(uuid, text, text), cng_srv_emergency_remove(uuid, text), cng_admin_archive_srv(text, uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_log_archive(uuid, text), cng_srv_log_restore_to_station(uuid, text), cng_srv_log_move(uuid, uuid, uuid, text),
                          cng_srv_calibration_archive(uuid, text), cng_srv_calibration_edit(uuid, date, text, date, text),
                          cng_srv_emergency_edit(uuid, text, text), cng_srv_emergency_remove(uuid, text), cng_admin_archive_srv(text, uuid, text)
  TO authenticated;
