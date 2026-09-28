-- Owner request 2026-09-28: an administrator can
--   (1) add a Station from scratch, in a chosen Region, with its details and its Units, and
--   (2) add relief valves from scratch to the warehouse (a new purchase, or stock already calibrated / under calibration).
--
-- Both follow the admin-RPC pattern of 20260928110000: SECURITY DEFINER with a pinned search_path, the actor derived
-- server-side by cng_require_admin() (no actor parameter exists), and an audit_logs row written in the same statement.
-- Nothing is invented: every value stored is one the administrator typed; an omitted value stays NULL.
-- normalized_name is a generated column on both tables, so it is never written here.
-- Identity is the database's: Station = (region_id, normalized_name) and Unit = (station_id, normalized_name) are
-- enforced by the existing unique constraints; the functions only turn a collision into a readable message.
-- Installing a valve at a station stays the existing issue (صرف) workflow; this only adds stock to the warehouse.

CREATE OR REPLACE FUNCTION cng_admin_create_station(
  p_region_id uuid, p_station_name text, p_bay_status text DEFAULT NULL, p_notes text DEFAULT NULL,
  p_units jsonb DEFAULT '[]'::jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_name text := nullif(btrim(p_station_name), '');
  v_station uuid;
  u jsonb;
  v_unit_name text;
  v_units jsonb := '[]'::jsonb;
  v_count int := 0;
BEGIN
  IF v_name IS NULL THEN RAISE EXCEPTION 'a Station name is required' USING ERRCODE = '22023'; END IF;
  IF NOT EXISTS (SELECT 1 FROM regions WHERE id = p_region_id) THEN
    RAISE EXCEPTION 'choose a Region' USING ERRCODE = '22023';
  END IF;
  IF p_bay_status IS NOT NULL AND p_bay_status NOT IN ('open', 'closed') THEN
    RAISE EXCEPTION 'bay status must be open or closed' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(coalesce(p_units, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'units must be a list' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM stations WHERE region_id = p_region_id AND normalized_name = cng_normalize_name(v_name)) THEN
    RAISE EXCEPTION 'a Station with this name already exists in this Region' USING ERRCODE = '23505';
  END IF;

  INSERT INTO stations (region_id, station_name, bay_status, notes)
  VALUES (p_region_id, v_name, p_bay_status::bay_status, nullif(btrim(p_notes), ''))
  RETURNING id INTO v_station;

  FOR u IN SELECT * FROM jsonb_array_elements(coalesce(p_units, '[]'::jsonb)) LOOP
    v_unit_name := nullif(btrim(u->>'unit_name'), '');
    IF v_unit_name IS NULL THEN RAISE EXCEPTION 'every Unit needs a name' USING ERRCODE = '22023'; END IF;
    IF EXISTS (SELECT 1 FROM units WHERE station_id = v_station AND normalized_name = cng_normalize_name(v_unit_name)) THEN
      RAISE EXCEPTION 'two Units have the same name: %', v_unit_name USING ERRCODE = '23505';
    END IF;
    IF (u->>'bay_status') IS NOT NULL AND (u->>'bay_status') NOT IN ('open', 'closed') THEN
      RAISE EXCEPTION 'bay status must be open or closed' USING ERRCODE = '22023';
    END IF;
    INSERT INTO units (station_id, region_id, unit_name, job_number, job_number_raw,
                       dispenser_count_reported, hose_count_reported, storage_count_reported, bay_status, notes)
    VALUES (v_station, p_region_id, v_unit_name,
            nullif(btrim(u->>'job_number'), ''), nullif(btrim(u->>'job_number'), ''),
            (u->>'dispensers')::int, (u->>'hoses')::int, (u->>'storage_vessels')::int,
            (u->>'bay_status')::bay_status, nullif(btrim(u->>'notes'), ''));
    v_count := v_count + 1;
    v_units := v_units || jsonb_build_array(v_unit_name);
  END LOOP;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', 'stations', v_station, v_actor, 'admin_create_station',
          format('Station %s created with %s Unit(s).', v_name, v_count), NULL,
          jsonb_build_object('region_id', p_region_id, 'station_name', v_name, 'bay_status', p_bay_status, 'units', v_units), now());
  RETURN v_station;
END; $$;

COMMENT ON FUNCTION cng_admin_create_station(uuid, text, text, text, jsonb) IS
  'Admin only: create a Station in a Region with its Units (owner request 2026-09-28). Actor derived server-side; audited.';

CREATE OR REPLACE FUNCTION cng_admin_add_warehouse_srvs(p jsonb)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
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
  s text;
BEGIN
  IF v_status IS NULL OR v_status NOT IN ('available_new', 'available_calibrated', 'available_in_store_uc') THEN
    RAISE EXCEPTION 'choose the condition: new, calibrated or under calibration' USING ERRCODE = '22023';
  END IF;
  SELECT coalesce(array_agg(DISTINCT btrim(x)) FILTER (WHERE btrim(x) <> ''), '{}')
    INTO v_serials FROM jsonb_array_elements_text(coalesce(p->'serials', '[]'::jsonb)) x;
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

  FOR s IN SELECT unnest(CASE WHEN cardinality(v_serials) > 0 THEN v_serials ELSE array_fill(NULL::text, ARRAY[v_qty]) END) LOOP
    INSERT INTO warehouse_relief_valves (
      availability_status, serial_number, serial_number_raw, serial_status, manufacturer, part_number,
      size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit,
      warehouse_code, last_calibration_date, last_calibration_precision, next_calibration_date, next_calibration_precision,
      notes)
    VALUES (
      v_status::warehouse_availability, s, s, CASE WHEN s IS NULL THEN 'unknown' ELSE 'assigned' END::serial_status,
      nullif(btrim(p->>'manufacturer'), ''), nullif(btrim(p->>'part_number'), ''),
      nullif(btrim(p->>'size_type'), ''), nullif(btrim(p->>'inlet_size'), ''), nullif(btrim(p->>'outlet_size'), ''),
      CASE WHEN v_min IS NULL THEN NULL WHEN v_min = v_max THEN v_min::text ELSE v_min::text || '-' || v_max::text END,
      v_min, v_max, (p->>'pressure_unit')::pressure_unit,
      nullif(btrim(p->>'warehouse_code'), ''),
      v_last, CASE WHEN v_last IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      v_next, CASE WHEN v_next IS NULL THEN 'unknown' ELSE 'exact_date' END::date_precision,
      nullif(btrim(p->>'notes'), ''))
    RETURNING id INTO v_id;
    v_ids := v_ids || v_id;
  END LOOP;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at)
  VALUES ('record_created', 'warehouse_relief_valves', v_ids[1], v_actor, 'admin_add_warehouse_srvs',
          format('%s relief valve(s) added to the warehouse (%s).', cardinality(v_ids), v_status), NULL,
          p || jsonb_build_object('ids', to_jsonb(v_ids)), now());
  RETURN cardinality(v_ids);
END; $$;

COMMENT ON FUNCTION cng_admin_add_warehouse_srvs(jsonb) IS
  'Admin only: add relief valves to the warehouse (new, calibrated or under calibration), one row per serial or a quantity without serials. Actor derived server-side; audited.';

REVOKE ALL ON FUNCTION cng_admin_create_station(uuid, text, text, text, jsonb), cng_admin_add_warehouse_srvs(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_admin_create_station(uuid, text, text, text, jsonb), cng_admin_add_warehouse_srvs(jsonb) TO authenticated;
