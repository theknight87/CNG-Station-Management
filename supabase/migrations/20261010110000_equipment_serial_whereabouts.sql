-- 20261010110000_equipment_serial_whereabouts.sql — "where is this serial?" for hoses and gas detectors (owner request
-- 2026-10-10: what the relief valves have, every section has; the SRV version is 20261004120000).
--
-- (1) cng_equipment_serial_whereabouts(kind, serials): every live record of that kind holding each serial (trimmed,
--     case-insensitive) — installed at a station, in the warehouse, at the 3rd party (calibration / hydrotest), or in the
--     Log awaiting return — with a readable place. All of them block a new store record. SECURITY INVOKER: from the
--     browser it reads under the caller's RLS. A store record that only follows an issued item (sent to a station) is
--     not listed: the installed record says where that item is.
-- (2) cng_equipment_serials_refuse_known(kind, serials): raises 23505 "already recorded: <serial> — <place>". Not
--     callable from the browser.
-- (3) cng_equipment_stock_add: the same signature and body, except that a serial typed twice (case and spaces folded)
--     refuses the whole batch (22023) — before, the duplicate was silently dropped — and a serial already recorded
--     anywhere refuses it (23505) — before, only one already in the store did. All or nothing, as before.
-- No DROP; no table, column or policy change.

-- (1)
CREATE OR REPLACE FUNCTION cng_equipment_serial_whereabouts(p_kind text, p_serials text[])
RETURNS TABLE (serial text, kind text, blocking boolean, place text, record_id uuid)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = pg_catalog, public AS $$
  WITH q AS (
    SELECT DISTINCT btrim(x) AS serial, lower(btrim(x)) AS k FROM unnest(p_serials) x WHERE nullif(btrim(x), '') IS NOT NULL
  ),
  installed AS (
    SELECT h.id, h.serial_number, h.unit_id, h.station_id, h.region_id FROM hoses h WHERE p_kind = 'hose' AND h.archived_at IS NULL
    UNION ALL
    SELECT g.id, g.serial_number, g.unit_id, g.station_id, g.region_id FROM gas_detectors g WHERE p_kind = 'gas_detector' AND g.archived_at IS NULL
  )
  SELECT q.serial, 'installed'::text, true,
         concat_ws(' · ', 'installed at ' || coalesce(u.unit_name, s.station_name), r.name), i.id
    FROM q JOIN installed i ON lower(btrim(i.serial_number)) = q.k
    LEFT JOIN units u ON u.id = i.unit_id
    LEFT JOIN stations s ON s.id = i.station_id
    LEFT JOIN regions r ON r.id = i.region_id
  UNION ALL
  SELECT q.serial, CASE WHEN j.id IS NOT NULL THEN 'calibration' ELSE 'warehouse' END, true,
         CASE WHEN j.id IS NOT NULL THEN 'at the 3rd party'
              ELSE 'in the warehouse (' || CASE w.availability_status
                     WHEN 'available_new' THEN 'NEW'
                     WHEN 'available_calibrated' THEN CASE WHEN p_kind = 'hose' THEN 'TESTED' ELSE 'CALIBRATED' END
                     ELSE CASE WHEN p_kind = 'hose' THEN 'UNDER TEST' ELSE 'UNDER CALIBRATION' END END || ')' END,
         w.id
    FROM q JOIN equipment_stock w ON lower(btrim(w.serial_number)) = q.k AND w.kind = p_kind AND w.archived_at IS NULL
                                 AND w.availability_status IN ('available_new', 'available_calibrated', 'available_in_store_uc')
    LEFT JOIN LATERAL (SELECT j.id FROM equipment_calibration_jobs j
                        WHERE j.stock_id = w.id AND j.status <> 'certified' LIMIT 1) j ON true
  UNION ALL
  SELECT q.serial, 'log', true,
         concat_ws(' · ', 'awaiting return from ' || coalesce(f.unit_name, f.station_name), f.region_name), f.id
    FROM q JOIN v_equipment_field_log f ON lower(btrim(f.serial_number)) = q.k AND f.kind = p_kind AND f.status = 'at_station'
$$;
COMMENT ON FUNCTION cng_equipment_serial_whereabouts(text, text[]) IS
  'Where each hose / gas detector serial is held (owner request 2026-10-10): installed / warehouse / 3rd party / Log awaiting return — each blocks a new store record. Security invoker.';
REVOKE ALL ON FUNCTION cng_equipment_serial_whereabouts(text, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_serial_whereabouts(text, text[]) TO authenticated;

-- (2)
CREATE OR REPLACE FUNCTION cng_equipment_serials_refuse_known(p_kind text, p_serials text[])
RETURNS void LANGUAGE plpgsql STABLE SET search_path = pg_catalog, public AS $$
DECLARE v_msg text;
BEGIN
  SELECT string_agg(serial || ' — ' || places, '; ' ORDER BY serial) INTO v_msg
    FROM (SELECT serial, string_agg(DISTINCT place, ', ') AS places
            FROM cng_equipment_serial_whereabouts(p_kind, p_serials) WHERE blocking GROUP BY serial) b;
  IF v_msg IS NOT NULL THEN
    RAISE EXCEPTION 'already recorded: %', v_msg USING ERRCODE = '23505';
  END IF;
END; $$;
REVOKE ALL ON FUNCTION cng_equipment_serials_refuse_known(text, text[]) FROM PUBLIC, anon, authenticated;

-- (3)
CREATE OR REPLACE FUNCTION cng_equipment_stock_add(
  p_kind text, p_availability warehouse_availability, p_serials text[], p_quantity integer,
  p_manufacturer text, p_model text, p_description text,
  p_working_pressure numeric, p_working_unit pressure_unit, p_test_pressure numeric, p_test_unit pressure_unit,
  p_last_date date, p_next_date date, p_warehouse_code text, p_notes text)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_serials text[] := ARRAY(SELECT DISTINCT btrim(x) FROM unnest(coalesce(p_serials, '{}')) x WHERE nullif(btrim(x), '') IS NOT NULL);
  v_count integer;
  v_ids uuid[];
  v_twice text;
BEGIN
  IF p_kind NOT IN ('hose', 'gas_detector') THEN RAISE EXCEPTION 'unknown equipment kind' USING ERRCODE = '22023'; END IF;
  IF p_availability NOT IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN
    RAISE EXCEPTION 'an item added to the store is new, calibrated or under calibration' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) = 0 AND coalesce(p_quantity, 0) < 1 THEN
    RAISE EXCEPTION 'give the serial numbers, or a quantity for items with no serial yet' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_quantity, 0) > 500 THEN RAISE EXCEPTION 'at most 500 items at once' USING ERRCODE = '22023'; END IF;
  IF p_last_date IS NOT NULL AND p_last_date > cng_business_date() THEN
    RAISE EXCEPTION 'the last date cannot be in the future' USING ERRCODE = '22023';
  END IF;
  IF p_next_date IS NOT NULL AND p_last_date IS NOT NULL AND p_next_date <= p_last_date THEN
    RAISE EXCEPTION 'the next date must be after the last date' USING ERRCODE = '22023';
  END IF;
  SELECT string_agg(s, ', ' ORDER BY s) INTO v_twice
    FROM (SELECT min(btrim(x)) AS s FROM unnest(coalesce(p_serials, '{}')) x WHERE nullif(btrim(x), '') IS NOT NULL
           GROUP BY lower(btrim(x)) HAVING count(*) > 1) d;
  IF v_twice IS NOT NULL THEN
    RAISE EXCEPTION 'serial typed twice: %', v_twice USING ERRCODE = '22023';
  END IF;
  PERFORM cng_equipment_serials_refuse_known(p_kind, v_serials);

  WITH src AS (
    SELECT s AS serial FROM unnest(v_serials) s
    UNION ALL
    SELECT NULL FROM generate_series(1, CASE WHEN cardinality(v_serials) = 0 THEN p_quantity ELSE 0 END)
  ), ins AS (
    INSERT INTO equipment_stock (kind, availability_status, serial_number, serial_status, manufacturer, model, description,
                                 working_pressure_value, working_pressure_unit, test_pressure_value, test_pressure_unit,
                                 last_date, last_precision, next_date, next_precision, warehouse_code, notes, created_by)
    SELECT p_kind, p_availability, src.serial, CASE WHEN src.serial IS NULL THEN 'not_yet_assigned' ELSE 'assigned' END::serial_status,
           nullif(btrim(p_manufacturer), ''),
           CASE WHEN p_kind = 'gas_detector' THEN nullif(btrim(p_model), '') END,
           CASE WHEN p_kind = 'hose' THEN nullif(btrim(p_description), '') END,
           CASE WHEN p_kind = 'hose' THEN p_working_pressure END, CASE WHEN p_kind = 'hose' THEN p_working_unit END,
           CASE WHEN p_kind = 'hose' THEN p_test_pressure END, CASE WHEN p_kind = 'hose' THEN p_test_unit END,
           p_last_date, CASE WHEN p_last_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
           p_next_date, CASE WHEN p_next_date IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
           nullif(btrim(p_warehouse_code), ''), nullif(btrim(p_notes), ''), v_actor
      FROM src
    RETURNING id
  )
  SELECT array_agg(id) INTO v_ids FROM ins;
  v_count := cardinality(v_ids);

  INSERT INTO equipment_history (kind, stock_id, event, summary, actor_id)
  SELECT p_kind, x, 'added', 'Added to the warehouse', v_actor FROM unnest(v_ids) x;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('admin_action', 'equipment_stock', NULL, v_actor, 'equipment_stock_add',
          format('%s %s(s) added to the warehouse', v_count, replace(p_kind, '_', ' ')), NULL,
          jsonb_build_object('kind', p_kind, 'availability', p_availability, 'stock_ids', to_jsonb(v_ids)), now());
  RETURN v_count;
END;
$$;
REVOKE ALL ON FUNCTION cng_equipment_stock_add(text, warehouse_availability, text[], integer, text, text, text, numeric,
  pressure_unit, numeric, pressure_unit, date, date, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_stock_add(text, warehouse_availability, text[], integer, text, text, text, numeric,
  pressure_unit, numeric, pressure_unit, date, date, text, text) TO authenticated;
