-- Phase 6n: installed SRVs take the serial / set pressure of the 24/9/2026 station snapshot (رصيد المحطات).
--
-- Owner ruling 2026-09-24: "اي تغييرات في السيريال او الضغط اعتمد الي في الملف" - where the snapshot and the system
-- hold the same valve with a different serial or set pressure, the snapshot wins. The pairing is computed outside the
-- database by scripts/import/6n_snapshot_update.py using the import pipeline's own normalizers, and only where it is
-- unambiguous (same Region/Station/Location and serial -> pressure change; same Region/Station/Location and pressure
-- with exactly one unmatched valve on each side -> serial change). A serial change means a different physical valve now
-- sits there, so its calibration dates come from the snapshot too; the old values are kept in the audit row.
-- The payload is content-bound: the fingerprint covers the payload and every target row's updated_at, and a row that
-- already holds the snapshot value refuses the whole batch (replay guard). service_role
-- only, prefix 6N. No DML here.

CREATE OR REPLACE FUNCTION cng_6n_preview(p_payload jsonb)
RETURNS TABLE (preview_fingerprint text, total int, pressure_changes int, serial_changes int, missing int, already_applied int)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  WITH p AS MATERIALIZED (SELECT (e->>'id')::uuid AS id, e->>'kind' AS kind, e AS v FROM jsonb_array_elements(p_payload) e),
       t AS MATERIALIZED (SELECT p.id, p.kind, i.updated_at,
                                 CASE p.kind WHEN 'pressure' THEN i.set_pressure_raw IS NOT DISTINCT FROM p.v->>'set_pressure_raw'
                                             ELSE i.serial_number IS NOT DISTINCT FROM p.v->>'serial_number'
                                              AND i.serial_number_raw IS NOT DISTINCT FROM p.v->>'serial_number_raw' END AS applied
                            FROM p
                            LEFT JOIN installed_relief_valves i ON i.id = p.id AND i.archived_at IS NULL)
  SELECT encode(sha256(convert_to('6N|' || p_payload::text || '|' ||
           coalesce((SELECT string_agg(concat_ws('|', id, updated_at), E'\n' ORDER BY id) FROM t), ''), 'UTF8')), 'hex'),
         (SELECT count(*) FROM t)::int,
         (SELECT count(*) FROM t WHERE kind = 'pressure')::int,
         (SELECT count(*) FROM t WHERE kind = 'serial')::int,
         (SELECT count(*) FROM t WHERE updated_at IS NULL OR kind NOT IN ('pressure', 'serial'))::int
           + (SELECT count(*) - count(DISTINCT id) FROM t)::int,
         (SELECT count(*) FROM t WHERE applied)::int;
$$;

CREATE OR REPLACE FUNCTION cng_6n_commit(p_payload jsonb, p_expected_preview_fingerprint text, p_reason text)
RETURNS TABLE (updated int, preview_fingerprint text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE v_fp text; e int; m int; a int; n int; v_before jsonb;
BEGIN
  SELECT pv.preview_fingerprint, pv.total, pv.missing, pv.already_applied INTO v_fp, e, m, a FROM cng_6n_preview(p_payload) pv;
  IF v_fp IS DISTINCT FROM p_expected_preview_fingerprint THEN
    RAISE EXCEPTION '6n commit refused: the proposal no longer matches the approved one (approved %, current %)',
      p_expected_preview_fingerprint, v_fp USING ERRCODE = '22023';
  END IF;
  IF e = 0 OR m > 0 OR a > 0 THEN
    RAISE EXCEPTION '6n commit refused: % rows, % missing/duplicate/unknown, % already applied', e, m, a USING ERRCODE = '22023';
  END IF;

  CREATE TEMP TABLE _6n ON COMMIT DROP AS
  SELECT (x->>'id')::uuid AS id, x->>'kind' AS kind, x AS v FROM jsonb_array_elements(p_payload) x;

  SELECT jsonb_agg(jsonb_build_object('id', i.id, 'serial_number', i.serial_number, 'serial_number_raw', i.serial_number_raw,
           'part_number', i.part_number, 'serial_status', i.serial_status, 'set_pressure_raw', i.set_pressure_raw,
           'pressure_min', i.pressure_min, 'pressure_max', i.pressure_max, 'pressure_unit', i.pressure_unit,
           'last_calibration_date', i.last_calibration_date, 'last_calibration_precision', i.last_calibration_precision,
           'last_calibration_raw', i.last_calibration_raw, 'next_calibration_date', i.next_calibration_date,
           'next_calibration_precision', i.next_calibration_precision, 'next_calibration_raw', i.next_calibration_raw) ORDER BY i.id)
    INTO v_before FROM installed_relief_valves i JOIN _6n USING (id);

  UPDATE installed_relief_valves i
     SET set_pressure_raw = t.v->>'set_pressure_raw',
         pressure_min = (t.v->>'pressure_min')::numeric, pressure_max = (t.v->>'pressure_max')::numeric,
         pressure_unit = (t.v->>'pressure_unit')::pressure_unit,
         serial_number = CASE WHEN t.kind = 'serial' THEN t.v->>'serial_number' ELSE i.serial_number END,
         serial_number_raw = CASE WHEN t.kind = 'serial' THEN t.v->>'serial_number_raw' ELSE i.serial_number_raw END,
         part_number = CASE WHEN t.kind = 'serial' THEN t.v->>'part_number' ELSE i.part_number END,
         serial_status = CASE WHEN t.kind = 'serial' THEN (t.v->>'serial_status')::serial_status ELSE i.serial_status END,
         last_calibration_date = CASE WHEN t.kind = 'serial' THEN (t.v->>'last_calibration_date')::date ELSE i.last_calibration_date END,
         last_calibration_precision = CASE WHEN t.kind = 'serial' THEN (t.v->>'last_calibration_precision')::date_precision ELSE i.last_calibration_precision END,
         last_calibration_raw = CASE WHEN t.kind = 'serial' THEN t.v->>'last_calibration_raw' ELSE i.last_calibration_raw END,
         next_calibration_date = CASE WHEN t.kind = 'serial' THEN (t.v->>'next_calibration_date')::date ELSE i.next_calibration_date END,
         next_calibration_precision = CASE WHEN t.kind = 'serial' THEN (t.v->>'next_calibration_precision')::date_precision ELSE i.next_calibration_precision END,
         next_calibration_raw = CASE WHEN t.kind = 'serial' THEN t.v->>'next_calibration_raw' ELSE i.next_calibration_raw END
    FROM _6n t WHERE i.id = t.id AND i.archived_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;

  IF n <> e THEN RAISE EXCEPTION '6n commit refused: % updated, % expected', n, e USING ERRCODE = '40001'; END IF;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('import_executed', 'installed_relief_valves', NULL, NULL, 'service_role:srv_snapshot_update_6n',
          format('Phase 6n: %s installed SRVs updated from the 24/9/2026 station snapshot (owner ruling: the file wins on serial and pressure). %s',
                 n, coalesce(p_reason, '')),
          jsonb_build_object('records', v_before), jsonb_build_object('preview_fingerprint', v_fp, 'payload', p_payload), now());
  RETURN QUERY SELECT n, v_fp;
END;
$$;

REVOKE ALL ON FUNCTION cng_6n_preview(jsonb), cng_6n_commit(jsonb, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION cng_6n_preview(jsonb), cng_6n_commit(jsonb, text, text) TO service_role;
