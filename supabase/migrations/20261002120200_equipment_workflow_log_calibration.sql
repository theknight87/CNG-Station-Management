-- Hoses / Gas Detectors workflow, part 3 of 3 (owner request 2026-10-02): the Log and the 3rd-party step.
-- Split from 20261002120000 only so each deploy stays small; see that file for the design. Executes no DML.

-- ============================================================================ Log: receive
CREATE OR REPLACE FUNCTION cng_equipment_log_receive(p_log_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); l equipment_field_log; h hoses; g gas_detectors; v_stock uuid; n int := 0;
BEGIN
  IF p_log_ids IS NULL OR cardinality(p_log_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  IF (SELECT count(*) FROM equipment_field_log WHERE id = ANY (p_log_ids) AND returned_at IS NULL)
     <> (SELECT count(DISTINCT x) FROM unnest(p_log_ids) x) THEN
    RAISE EXCEPTION 'some selected items were already received or are not in the Log; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  FOR l IN SELECT * FROM equipment_field_log WHERE id = ANY (p_log_ids) ORDER BY logged_at, id FOR UPDATE LOOP
    v_stock := gen_random_uuid();
    IF l.kind = 'hose' THEN
      SELECT * INTO h FROM hoses WHERE id = l.installed_hose_id;
      INSERT INTO equipment_stock (id, kind, availability_status, serial_number, serial_status, description,
                                   working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                                   last_date, last_precision, next_date, next_precision, notes, created_by)
      VALUES (v_stock, 'hose', 'available_in_store_uc', h.serial_number,
              CASE WHEN h.serial_number IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status, h.description,
              h.working_pressure_value, h.working_pressure_unit, h.test_pressure_value, h.test_pressure_unit,
              h.last_test_date, CASE WHEN h.last_test_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              h.next_test_date, CASE WHEN h.next_test_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              'Returned from the station (Log)', v_actor);
    ELSE
      SELECT * INTO g FROM gas_detectors WHERE id = l.installed_gas_detector_id;
      INSERT INTO equipment_stock (id, kind, availability_status, serial_number, serial_status, manufacturer, model,
                                   last_date, last_precision, next_date, next_precision, notes, created_by)
      VALUES (v_stock, 'gas_detector', 'available_in_store_uc', g.serial_number,
              CASE WHEN g.serial_number IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status, g.manufacturer, g.model,
              g.last_calibration_date, CASE WHEN g.last_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              g.next_calibration_date, CASE WHEN g.next_calibration_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
              'Returned from the station (Log)', v_actor);
    END IF;
    UPDATE equipment_field_log SET returned_at = now(), returned_by = v_actor, returned_stock_id = v_stock WHERE id = l.id;
    INSERT INTO equipment_history (kind, stock_id, hose_id, gas_detector_id, region_id, event, summary, details, actor_id)
    VALUES (l.kind, v_stock, l.installed_hose_id, l.installed_gas_detector_id, NULL, 'received',
            'Received back at the warehouse; now in the store, under calibration',
            jsonb_build_object('log_id', l.id, 'from_station_id', l.station_id), v_actor);
    n := n + 1;
  END LOOP;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_field_log', NULL, v_actor, 'equipment_log_receive',
          format('%s item(s) received back at the warehouse from the Log', n), NULL,
          jsonb_build_object('log_ids', to_jsonb(p_log_ids)), now());
  RETURN n;
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_log_receive(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_log_receive(uuid[]) TO authenticated;

-- ============================================================================ 3rd party: calibration / hydrotest
CREATE OR REPLACE FUNCTION cng_equipment_calibration_send(p_stock_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_stock_ids IS NULL OR cardinality(p_stock_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  PERFORM 1 FROM equipment_stock WHERE id = ANY (p_stock_ids) FOR UPDATE;
  IF (SELECT count(*) FROM equipment_stock e
       WHERE e.id = ANY (p_stock_ids) AND e.archived_at IS NULL AND e.availability_status = 'available_in_store_uc'
         AND NOT EXISTS (SELECT 1 FROM equipment_calibration_jobs j WHERE j.stock_id = e.id AND j.status <> 'certified'))
     <> (SELECT count(DISTINCT x) FROM unnest(p_stock_ids) x) THEN
    RAISE EXCEPTION 'only items in the store under calibration, not already at the 3rd party, can be sent; reload and try again'
      USING ERRCODE = 'PT409';
  END IF;
  INSERT INTO equipment_calibration_jobs (kind, stock_id, sent_by)
  SELECT e.kind, e.id, v_actor FROM equipment_stock e WHERE e.id = ANY (p_stock_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO equipment_history (kind, stock_id, event, summary, actor_id)
  SELECT e.kind, e.id, 'sent_to_calibration', 'Sent to the 3rd party', v_actor FROM equipment_stock e WHERE e.id = ANY (p_stock_ids);
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_calibration_jobs', NULL, v_actor, 'equipment_calibration',
          format('%s item(s) sent to the 3rd party', n), NULL, jsonb_build_object('stock_ids', to_jsonb(p_stock_ids)), now());
  RETURN n;
END;
$$;

CREATE OR REPLACE FUNCTION cng_equipment_calibration_returned(p_job_ids uuid[])
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_require_admin(); n int;
BEGIN
  IF p_job_ids IS NULL OR cardinality(p_job_ids) = 0 THEN RAISE EXCEPTION 'nothing selected' USING ERRCODE = '22023'; END IF;
  PERFORM 1 FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids) AND status = 'sent')
     <> (SELECT count(DISTINCT x) FROM unnest(p_job_ids) x) THEN
    RAISE EXCEPTION 'only items still at the 3rd party can be marked returned; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  UPDATE equipment_calibration_jobs SET status = 'returned_awaiting_certificate', returned_at = now(), returned_by = v_actor
   WHERE id = ANY (p_job_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  INSERT INTO equipment_history (kind, stock_id, event, summary, actor_id)
  SELECT kind, stock_id, 'returned_from_calibration', 'Returned from the 3rd party; certificate awaited', v_actor
    FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids);
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_calibration_jobs', NULL, v_actor, 'equipment_calibration',
          format('%s item(s) returned from the 3rd party, certificate awaited', n), NULL,
          jsonb_build_object('job_ids', to_jsonb(p_job_ids)), now());
  RETURN n;
END;
$$;

-- The certificate date becomes the item's last calibration / test date (exact). The next date is set only when the
-- admin enters it; otherwise it is unknown — no interval is invented.
CREATE OR REPLACE FUNCTION cng_equipment_calibration_certify(p_job_ids uuid[], p_certificate_date date,
                                                            p_certificate_number text DEFAULT NULL,
                                                            p_next_date date DEFAULT NULL)
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
  IF p_next_date IS NOT NULL AND p_next_date <= p_certificate_date THEN
    RAISE EXCEPTION 'the next date must be after the certificate date' USING ERRCODE = '22023';
  END IF;
  PERFORM 1 FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids) FOR UPDATE;
  IF (SELECT count(*) FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids) AND status <> 'certified')
     <> (SELECT count(DISTINCT x) FROM unnest(p_job_ids) x) THEN
    RAISE EXCEPTION 'some selected items are already certified; reload and try again' USING ERRCODE = 'PT409';
  END IF;
  UPDATE equipment_calibration_jobs
     SET status = 'certified', returned_at = coalesce(returned_at, now()), returned_by = coalesce(returned_by, v_actor),
         certified_at = now(), certified_by = v_actor, certificate_date = p_certificate_date,
         certificate_number = nullif(btrim(p_certificate_number), ''), next_date = p_next_date
   WHERE id = ANY (p_job_ids);
  GET DIAGNOSTICS n = ROW_COUNT;
  UPDATE equipment_stock e
     SET availability_status = 'available_calibrated',
         last_date = p_certificate_date, last_precision = 'exact_date',
         next_date = p_next_date,
         next_precision = CASE WHEN p_next_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision
    FROM equipment_calibration_jobs j
   WHERE j.id = ANY (p_job_ids) AND e.id = j.stock_id;
  INSERT INTO equipment_history (kind, stock_id, event, summary, details, actor_id)
  SELECT kind, stock_id, 'certified',
         format('Certificate received (dated %s%s); now in the store, calibrated', p_certificate_date,
                coalesce(', no. ' || nullif(btrim(p_certificate_number), ''), '')),
         jsonb_build_object('job_id', id, 'next_date', p_next_date), v_actor
    FROM equipment_calibration_jobs WHERE id = ANY (p_job_ids);
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_calibration_jobs', NULL, v_actor, 'equipment_calibration',
          format('%s item(s) certified (certificate dated %s)', n, p_certificate_date), NULL,
          jsonb_build_object('job_ids', to_jsonb(p_job_ids), 'certificate_date', p_certificate_date,
                             'certificate_number', p_certificate_number, 'next_date', p_next_date), now());
  RETURN n;
END;
$$;

REVOKE ALL ON FUNCTION cng_equipment_calibration_send(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_calibration_send(uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION cng_equipment_calibration_returned(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_calibration_returned(uuid[]) TO authenticated;
REVOKE ALL ON FUNCTION cng_equipment_calibration_certify(uuid[], date, text, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_calibration_certify(uuid[], date, text, date) TO authenticated;
