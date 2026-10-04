-- Warehouse valve destination: Station or Unit, set when adding and editable later (owner request 2026-10-04).
--
-- A store valve already carries a destination Station (target_station_id, its Region following by
-- wrv_target_station_region_fk). This adds:
--   * target_unit_id      the Unit, when the destination is a Unit; it must belong to target_station_id
--                         (composite FK on units(id, station_id)) and never stands without a Station.
--   * destination_set_at  when an administrator last set the destination by hand. Once set, the sheet's own
--                         Station text (source_raw->>'Station', kept unchanged) is no longer shown in its place,
--                         so clearing a destination really clears it. source_raw is never altered.
-- Writes go only through admin-only SECURITY DEFINER functions (actor server-side, audited, PT409 on a stale
-- edit). No browser write grant is added. Additive: two nullable columns, one FK, one CHECK, one trigger, the view replaced
-- with appended columns (security_invoker restated), two functions replaced/added. No DML on existing rows.

ALTER TABLE warehouse_relief_valves
  ADD COLUMN IF NOT EXISTS target_unit_id uuid NULL,
  ADD COLUMN IF NOT EXISTS destination_set_at timestamptz NULL;

ALTER TABLE warehouse_relief_valves
  ADD CONSTRAINT wrv_target_unit_station_fk FOREIGN KEY (target_unit_id, target_station_id)
    REFERENCES units (id, station_id) ON DELETE RESTRICT,
  ADD CONSTRAINT wrv_target_unit_needs_station_ck CHECK (target_unit_id IS NULL OR target_station_id IS NOT NULL);

-- The issue / receive / undo functions move target_station_id without knowing about the Unit: when the Station
-- changes and the Unit was not changed with it, the Unit no longer applies and is cleared.
CREATE OR REPLACE FUNCTION cng_wrv_unit_follows_station()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF NEW.target_station_id IS DISTINCT FROM OLD.target_station_id
     AND NEW.target_unit_id IS NOT DISTINCT FROM OLD.target_unit_id THEN
    NEW.target_unit_id := NULL;
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER wrv_unit_follows_station
  BEFORE UPDATE OF target_station_id ON warehouse_relief_valves
  FOR EACH ROW EXECUTE FUNCTION cng_wrv_unit_follows_station();

CREATE INDEX IF NOT EXISTS wrv_target_unit_idx ON warehouse_relief_valves (target_unit_id) WHERE target_unit_id IS NOT NULL;

CREATE OR REPLACE VIEW v_warehouse_srv_management WITH (security_invoker = true) AS
 SELECT w.id,
    w.availability_status,
    w.warehouse_code,
    w.serial_number,
    w.serial_number_raw,
    w.serial_status,
    w.part_number,
    w.manufacturer,
    w.size_type,
    w.inlet_size,
    w.outlet_size,
    w.set_pressure_raw,
    w.pressure_min,
    w.pressure_max,
    w.pressure_unit,
    r.id AS target_region_id,
    r.name AS target_region_name,
    s.id AS target_station_id,
    s.station_name AS target_station_name,
    w.target_station_id IS NULL
      AND (w.destination_set_at IS NOT NULL OR NULLIF(btrim(w.source_raw ->> 'Station'), '') IS NULL) AS is_unassigned_stock,
    w.warehouse_issue_date,
    w.last_calibration_date,
    w.last_calibration_precision,
    cng_date_display(w.last_calibration_date, w.last_calibration_precision, w.last_calibration_raw) AS last_calibration_display,
    w.next_calibration_date,
    w.next_calibration_precision,
    cng_date_display(w.next_calibration_date, w.next_calibration_precision, w.next_calibration_raw) AS next_calibration_display,
    cng_days_left(w.next_calibration_date, w.next_calibration_precision) AS days_left,
    cng_due_status(w.next_calibration_date, w.next_calibration_precision) AS due_status,
    w.calibration_location,
    w.source_status_raw,
    w.needs_review,
    w.notes,
    w.created_at,
    w.updated_at,
    CASE w.pressure_unit::text
      WHEN 'BAR' THEN w.pressure_max
      WHEN 'PSI' THEN round(w.pressure_max * 0.0689476, 3)
      ELSE NULL::numeric
    END AS pressure_sort_bar,
    CASE WHEN w.destination_set_at IS NULL THEN NULLIF(btrim(w.source_raw ->> 'Station'), '') END AS target_station_raw,
    u.id AS target_unit_id,
    u.unit_name AS target_unit_name,
    w.destination_set_at
   FROM warehouse_relief_valves w
     LEFT JOIN regions r ON r.id = w.target_region_id
     LEFT JOIN stations s ON s.id = w.target_station_id
     LEFT JOIN units u ON u.id = w.target_unit_id
  WHERE w.archived_at IS NULL;

-- The destination a Station/Unit choice resolves to: a Unit fixes its Station; the Region follows the Station.
CREATE OR REPLACE FUNCTION cng_wrv_resolve_destination(p_station_id uuid, p_unit_id uuid,
  OUT station_id uuid, OUT region_id uuid, OUT unit_id uuid)
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_unit_id IS NOT NULL THEN
    SELECT un.station_id, un.region_id, un.id INTO station_id, region_id, unit_id
      FROM units un WHERE un.id = p_unit_id AND un.archived_at IS NULL;
    IF unit_id IS NULL THEN RAISE EXCEPTION 'that Unit does not exist' USING ERRCODE = '22023'; END IF;
    IF p_station_id IS NOT NULL AND p_station_id <> station_id THEN
      RAISE EXCEPTION 'that Unit belongs to another Station' USING ERRCODE = '22023';
    END IF;
  ELSIF p_station_id IS NOT NULL THEN
    SELECT st.id, st.region_id INTO station_id, region_id FROM stations st WHERE st.id = p_station_id AND st.archived_at IS NULL;
    IF station_id IS NULL THEN RAISE EXCEPTION 'that Station does not exist' USING ERRCODE = '22023'; END IF;
  END IF;
END; $$;
REVOKE ALL ON FUNCTION cng_wrv_resolve_destination(uuid, uuid) FROM PUBLIC, anon, authenticated;


-- Admin: set, change or clear one store valve's destination.
CREATE OR REPLACE FUNCTION cng_admin_set_warehouse_destination(p_id uuid, p_expected_updated_at timestamptz,
                                                              p_station_id uuid, p_unit_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  w warehouse_relief_valves%ROWTYPE;
  d record;
BEGIN
  SELECT * INTO w FROM warehouse_relief_valves WHERE id = p_id AND archived_at IS NULL FOR UPDATE;
  IF w.id IS NULL THEN RAISE EXCEPTION 'valve not found' USING ERRCODE = '42704'; END IF;
  IF p_expected_updated_at IS NULL OR w.updated_at <> p_expected_updated_at THEN
    RAISE EXCEPTION 'this valve was changed by someone else; reload it and try again' USING ERRCODE = 'PT409';
  END IF;
  SELECT * INTO d FROM cng_wrv_resolve_destination(p_station_id, p_unit_id);
  UPDATE warehouse_relief_valves
     SET target_station_id = d.station_id, target_region_id = d.region_id, target_unit_id = d.unit_id,
         destination_set_at = now()
   WHERE id = p_id;
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_updated', 'warehouse_relief_valves', p_id, v_actor, 'admin_set_warehouse_destination',
          CASE WHEN d.station_id IS NULL THEN 'Warehouse valve destination cleared.' ELSE 'Warehouse valve destination set.' END,
          jsonb_build_object('target_station_id', w.target_station_id, 'target_region_id', w.target_region_id,
                             'target_unit_id', w.target_unit_id, 'destination_set_at', w.destination_set_at),
          jsonb_build_object('target_station_id', d.station_id, 'target_region_id', d.region_id, 'target_unit_id', d.unit_id),
          now());
END; $$;
REVOKE ALL ON FUNCTION cng_admin_set_warehouse_destination(uuid, timestamptz, uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_set_warehouse_destination(uuid, timestamptz, uuid, uuid) TO authenticated;

-- Add: unchanged, plus an optional destination — one for the whole batch (station_id / unit_id) and, per serial,
-- `items`: [{serial, station_id, unit_id}] (a row without its own destination takes the batch one).
CREATE OR REPLACE FUNCTION cng_admin_add_warehouse_srvs(p jsonb)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $function$
DECLARE
  v_actor uuid := cng_require_admin();
  v_status text := p->>'availability';
  v_serials text[];
  v_qty int := coalesce((p->>'quantity')::int, 0);
  v_min numeric := (p->>'pressure_min')::numeric;
  v_max numeric := coalesce((p->>'pressure_max')::numeric, (p->>'pressure_min')::numeric);
  v_last date := (p->>'last_calibration_date')::date;
  v_next date := (p->>'next_calibration_date')::date;
  v_dupes text;
  v_ids uuid[] := '{}';
  v_id uuid;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_default record;
  d record;
  s text;
BEGIN
  IF v_status IS NULL OR v_status NOT IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN
    RAISE EXCEPTION 'choose the condition: new, calibrated or under calibration' USING ERRCODE = '22023';
  END IF;
  -- Per-serial rows win; plain serials are rows with no destination of their own.
  IF jsonb_typeof(p->'items') = 'array' AND jsonb_array_length(p->'items') > 0 THEN
    SELECT coalesce(jsonb_agg(x), '[]'::jsonb) INTO v_items
      FROM jsonb_array_elements(p->'items') x WHERE btrim(coalesce(x->>'serial', '')) <> '';
  ELSE
    SELECT coalesce(jsonb_agg(jsonb_build_object('serial', x)), '[]'::jsonb) INTO v_items
      FROM jsonb_array_elements_text(coalesce(p->'serials', '[]'::jsonb)) x WHERE btrim(x) <> '';
  END IF;
  SELECT coalesce(array_agg(btrim(x->>'serial')), '{}') INTO v_serials FROM jsonb_array_elements(v_items) x;
  IF cardinality(v_serials) <> (SELECT count(DISTINCT x) FROM unnest(v_serials) x) THEN
    RAISE EXCEPTION 'the same serial is listed twice' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) = 0 AND v_qty < 1 THEN
    RAISE EXCEPTION 'give at least one serial, or a quantity for valves without a serial' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_serials) > 0 AND v_qty > 0 THEN
    RAISE EXCEPTION 'give serials or a quantity, not both' USING ERRCODE = '22023';
  END IF;
  IF v_qty > 500 OR cardinality(v_serials) > 500 THEN
    RAISE EXCEPTION 'at most 500 valves at once' USING ERRCODE = '22023';
  END IF;
  IF v_min IS NOT NULL AND v_max < v_min THEN RAISE EXCEPTION 'pressure range is reversed' USING ERRCODE = '22023'; END IF;
  IF (p->>'pressure_unit') IS NOT NULL AND (p->>'pressure_unit') NOT IN ('BAR', 'PSI') THEN
    RAISE EXCEPTION 'pressure unit must be BAR or PSI' USING ERRCODE = '22023';
  END IF;
  -- A serial already in warehouse stock would be the same valve entered twice.
  SELECT string_agg(DISTINCT w.serial_number, ', ') INTO v_dupes
    FROM warehouse_relief_valves w WHERE w.archived_at IS NULL AND w.serial_number = ANY (v_serials);
  IF v_dupes IS NOT NULL THEN
    RAISE EXCEPTION 'already in the warehouse: %', v_dupes USING ERRCODE = '23505';
  END IF;
  -- The owner rule for a calibration certificate: due again one year later.
  IF v_last IS NOT NULL AND v_next IS NULL THEN v_next := (v_last + interval '1 year')::date; END IF;
  SELECT * INTO v_default FROM cng_wrv_resolve_destination(nullif(p->>'station_id', '')::uuid, nullif(p->>'unit_id', '')::uuid);

  FOR v_item IN
    SELECT x FROM jsonb_array_elements(v_items) x
    UNION ALL SELECT '{}'::jsonb FROM generate_series(1, CASE WHEN cardinality(v_serials) = 0 THEN v_qty ELSE 0 END)
  LOOP
    s := nullif(btrim(v_item->>'serial'), '');
    IF nullif(v_item->>'station_id', '') IS NOT NULL OR nullif(v_item->>'unit_id', '') IS NOT NULL THEN
      SELECT * INTO d FROM cng_wrv_resolve_destination(nullif(v_item->>'station_id', '')::uuid, nullif(v_item->>'unit_id', '')::uuid);
    ELSE
      d := v_default;
    END IF;
    INSERT INTO warehouse_relief_valves (
      availability_status, serial_number, serial_number_raw, serial_status, manufacturer, part_number,
      size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
      warehouse_code, last_calibration_date, last_calibration_precision, next_calibration_date, next_calibration_precision,
      notes, target_station_id, target_region_id, target_unit_id, destination_set_at)
    VALUES (
      v_status::warehouse_availability, s, s, CASE WHEN s IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
      nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'part_number'), ''),
      nullif(btrim(p->>'size_type'), ''), nullif(btrim(p->>'inlet_size'), ''), nullif(btrim(p->>'outlet_size'), ''),
      CASE WHEN v_min IS NULL THEN NULL WHEN v_min = v_max THEN v_min::text ELSE v_min::text || '-' || v_max::text END,
      v_min, v_max, (p->>'pressure_unit')::pressure_unit,
      nullif(btrim(p->>'warehouse_code'), ''),
      v_last, CASE WHEN v_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      v_next, CASE WHEN v_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      nullif(btrim(p->>'notes'), ''), d.station_id, d.region_id, d.unit_id,
      CASE WHEN d.station_id IS NOT NULL THEN now() END)
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', 'warehouse_relief_valves', v_ids[1], v_actor, 'admin_add_warehouse_srvs',
          format('%s relief valve(s) added to the warehouse (%s).', cardinality(v_ids), v_status), NULL,
          p || jsonb_build_object('ids', to_jsonb(v_ids)), now());
  RETURN cardinality(v_ids);
END; $function$;
REVOKE ALL ON FUNCTION cng_admin_add_warehouse_srvs(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_add_warehouse_srvs(jsonb) TO authenticated;
