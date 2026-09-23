-- Owner ruling 2026-09-23: SRV calibration has a fixed interval of ONE YEAR. When a certificate is
-- recorded, the next calibration is due one year after the certificate date (it was left unknown before).
-- Only cng_srv_calibration_certify changes; signature, grants and security are unchanged. No DML.

-- The certificate date becomes the valve's last calibration date (exact), and the next calibration is due
-- one year later (owner ruling 2026-09-23: fixed interval of one year).
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
  p_next_calibration_date := coalesce(p_next_calibration_date, (p_certificate_date + interval '1 year')::date);
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
