-- A deleted (archived) 3rd party calibration entry no longer blocks its valve (owner report 2026-09-29).
--
-- 20260928110000 made "delete" of a calibration entry an ARCHIVE and taught the unique index
-- scj_open_valve_uq, the warehouse stock view and the calibration list to ignore archived entries.
-- Four functions were missed and still counted an archived entry that was never certified as OPEN:
--   * cng_srv_calibration_send   refused to send the valve again ("not already at the calibration company");
--   * cng_srv_issue               refused to issue it ("this valve is at the calibration company");
--   * cng_srv_calibration_returned / _certify would act on an entry that had been deleted.
-- Seen in production on two valves whose entry was sent and then deleted.
--
-- Each body below is the DEPLOYED definition (pg_get_functiondef, md5 of prosrc identical in production and in
-- the repository) with ONLY the "archived_at IS NULL" condition added (and certify's refusal message widened).
-- CREATE OR REPLACE keeps owner, grants, SECURITY DEFINER and search_path. No table, index, policy or grant
-- changes; no DML. Archived entries stay archived, with their audit history.

CREATE OR REPLACE FUNCTION public.cng_srv_calibration_send(p_warehouse_valve_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_warehouse_valve_ids IS NULL OR cardinality(p_warehouse_valve_ids) = 0 THEN
    RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM warehouse_relief_valves WHERE id = ANY (p_warehouse_valve_ids) FOR UPDATE;
  IF (SELECT count(*) FROM warehouse_relief_valves w
       WHERE w.id = ANY (p_warehouse_valve_ids) AND w.archived_at IS NULL AND w.availability_status = 'available_in_store_uc'
         AND NOT EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified' AND j.archived_at IS NULL))
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
$function$;

CREATE OR REPLACE FUNCTION public.cng_srv_issue(p_warehouse_valve_id uuid, p_expected_updated_at timestamp with time zone, p_unit_id uuid, p_replace_installed_valve_id uuid DEFAULT NULL::uuid, p_emergency boolean DEFAULT false, p_notes text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
  IF EXISTS (SELECT 1 FROM srv_calibration_jobs j WHERE j.warehouse_valve_id = w.id AND j.status <> 'certified' AND j.archived_at IS NULL) THEN
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
$function$;

CREATE OR REPLACE FUNCTION public.cng_srv_calibration_returned(p_job_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_job_ids IS NULL OR cardinality(p_job_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  PERFORM 1 FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) AND status = 'sent' AND archived_at IS NULL)
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
$function$;

CREATE OR REPLACE FUNCTION public.cng_srv_calibration_certify(p_job_ids uuid[], p_certificate_date date, p_certificate_number text DEFAULT NULL::text, p_next_calibration_date date DEFAULT NULL::date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_job_ids IS NULL OR cardinality(p_job_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  p_next_calibration_date := coalesce(p_next_calibration_date, (p_certificate_date + interval '1 year')::date);
  IF p_certificate_date IS NULL THEN RAISE EXCEPTION 'the certificate date is required' USING ERRCODE = '22023'; END IF;
  IF p_certificate_date > cng_business_date() THEN RAISE EXCEPTION 'the certificate date cannot be in the future' USING ERRCODE = '22023'; END IF;
  IF p_next_calibration_date IS NOT NULL AND p_next_calibration_date <= p_certificate_date THEN
    RAISE EXCEPTION 'the next calibration date must be after the certificate date' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM srv_calibration_jobs WHERE id = ANY (p_job_ids) AND status <> 'certified' AND archived_at IS NULL)
     <> (SELECT count(DISTINCT x) FROM unnest(p_job_ids) x) THEN
    RAISE EXCEPTION 'some selected valves are already certified or their entry was removed; reload and try again' USING ERRCODE = 'PT409';
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
$function$;
