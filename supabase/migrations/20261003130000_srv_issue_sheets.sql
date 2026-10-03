-- 20261003130000_srv_issue_sheets.sql — the warehouse issue sheet (owner request 2026-10-03).
--
-- The owner sends the storekeeper one workbook per Region and month ("بيانات صرف صمامات أمان معايرة"), one sheet per
-- issue day; a second export the same day for the same Region gets a new sheet named "<date> (2)", then "(3)", and
-- earlier sheets never change. To make that repeatable the system remembers which issues each sheet carried:
--
-- (1) srv_issue_sheets: one row per sheet — Region, issue day (Cairo), sequence number for that day, who exported it
--     and when. No browser write grant; select-only RLS like srv_issues.
-- (2) srv_issues.sheet_id: the sheet an issue was first exported in (NULL until then). Additive, nullable.
-- (3) cng_srv_issue_sheet_assign(region, month): admin only, SECURITY DEFINER, audited. Puts every live issue of that
--     Region and month that is in no sheet yet into a NEW sheet for its day (sequence = last for that day + 1). Run by
--     the export, so a sheet holds exactly what had not been sent before. Serialised per Region and month by an
--     advisory lock, so two exports at once cannot both make sheet (2).
-- (4) v_srv_issue_sheet: the rows of the workbook — every live (not undone) issue with its sheet, issue day, place,
--     Stage / Storage, the issued valve, the valve it replaced and when that one came back. security_invoker, so
--     srv_issues' RLS bounds it; no six-month cut-off (that belongs to the Log list, not to a month's paperwork).

-- (1)
CREATE TABLE srv_issue_sheets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  region_id   uuid NOT NULL REFERENCES regions(id),
  issue_day   date NOT NULL,
  seq         integer NOT NULL CHECK (seq >= 1),
  exported_by uuid NOT NULL REFERENCES app_users(id),
  exported_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT srv_issue_sheets_day_seq_uq UNIQUE (region_id, issue_day, seq)
);
COMMENT ON TABLE srv_issue_sheets IS
  'One sheet of the warehouse issue workbook (Region, issue day, n-th export that day). Written only by cng_srv_issue_sheet_assign.';
ALTER TABLE srv_issue_sheets ENABLE ROW LEVEL SECURITY;
CREATE POLICY srv_issue_sheets_select ON srv_issue_sheets FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR cng_has_region_grant(region_id, false));
REVOKE ALL ON srv_issue_sheets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON srv_issue_sheets TO authenticated;

-- (2)
ALTER TABLE srv_issues ADD COLUMN IF NOT EXISTS sheet_id uuid NULL REFERENCES srv_issue_sheets(id);
CREATE INDEX IF NOT EXISTS srv_issues_sheet_idx ON srv_issues (sheet_id);
CREATE INDEX IF NOT EXISTS srv_issues_region_issued_idx ON srv_issues (region_id, issued_at);
COMMENT ON COLUMN srv_issues.sheet_id IS 'The issue sheet this issue was first exported in; NULL until exported.';

-- (3)
CREATE OR REPLACE FUNCTION cng_srv_issue_sheet_assign(p_region_id uuid, p_month date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_from date; v_to date; v_day date; v_seq integer; v_sheet uuid; v_n integer; v_total integer := 0;
  v_region text;
BEGIN
  IF p_region_id IS NULL OR p_month IS NULL THEN
    RAISE EXCEPTION 'choose a Region and a month' USING ERRCODE = '22023';
  END IF;
  SELECT name INTO v_region FROM regions WHERE id = p_region_id;
  IF v_region IS NULL THEN RAISE EXCEPTION 'Region not found' USING ERRCODE = '42704'; END IF;
  v_from := date_trunc('month', p_month)::date;
  v_to := (v_from + interval '1 month')::date;
  PERFORM pg_advisory_xact_lock(hashtext('cng_srv_issue_sheet:' || p_region_id::text || ':' || v_from::text));

  FOR v_day IN
    SELECT DISTINCT (e.issued_at AT TIME ZONE 'Africa/Cairo')::date
      FROM srv_issues e
     WHERE e.region_id = p_region_id AND e.cancelled_at IS NULL AND e.sheet_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date >= v_from
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date < v_to
     ORDER BY 1
  LOOP
    SELECT coalesce(max(seq), 0) + 1 INTO v_seq FROM srv_issue_sheets WHERE region_id = p_region_id AND issue_day = v_day;
    INSERT INTO srv_issue_sheets (region_id, issue_day, seq, exported_by) VALUES (p_region_id, v_day, v_seq, v_actor)
      RETURNING id INTO v_sheet;
    UPDATE srv_issues e SET sheet_id = v_sheet
     WHERE e.region_id = p_region_id AND e.cancelled_at IS NULL AND e.sheet_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date = v_day;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, after_data, occurred_at)
    VALUES ('admin_action', 'srv_issue_sheets', v_sheet, v_actor, 'srv_issue_sheet',
            format('Issue sheet %s %s%s exported with %s valve(s)', v_region, to_char(v_day, 'FMDD-FMMM-YYYY'),
                   CASE WHEN v_seq > 1 THEN ' (' || v_seq || ')' ELSE '' END, v_n),
            jsonb_build_object('region_id', p_region_id, 'issue_day', v_day, 'seq', v_seq, 'issues', v_n), now());
  END LOOP;
  RETURN v_total;
END $$;
COMMENT ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) IS
  'Admin: put every live SRV issue of the Region and month that is in no sheet yet into a new sheet for its day. Returns how many issues were placed.';
REVOKE ALL ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_srv_issue_sheet_assign(uuid, date) TO authenticated;

-- (4)
CREATE OR REPLACE VIEW v_srv_issue_sheet WITH (security_invoker = true) AS
SELECT e.id,
       e.issued_at,
       (e.issued_at AT TIME ZONE 'Africa/Cairo')::date AS issue_day,
       e.region_id, r.name AS region_name,
       e.sheet_id, sh.seq AS sheet_seq, sh.exported_at AS sheet_exported_at,
       e.is_emergency,
       s.station_name, u.unit_name,
       -- Storage at Station level (ruling 6y) is written under the Station; anything on a Unit under the Unit.
       CASE WHEN nv.id IS NOT NULL AND nv.unit_id IS NULL THEN s.station_name ELSE u.unit_name END AS place_name,
       COALESCE(nullif(btrim(nv.location_raw), ''),
                CASE WHEN nv.storage_vessel_id IS NOT NULL OR nv.expected_parent_kind = 'storage_vessel' THEN 'Storage'
                     WHEN nv.compressor_id IS NOT NULL OR nv.expected_parent_kind = 'compressor' THEN 'Stage' END) AS location,
       e.warehouse_valve_id,
       w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.manufacturer, w.size_type, w.inlet_size, w.outlet_size,
       w.set_pressure_raw, w.pressure_min, w.pressure_max, w.pressure_unit,
       e.replaced_installed_valve_id, o.serial_number AS replaced_serial,
       l.returned_at AS replaced_returned_at
  FROM srv_issues e
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = e.station_id
  JOIN units u ON u.id = e.unit_id
  JOIN warehouse_relief_valves w ON w.id = e.warehouse_valve_id
  LEFT JOIN installed_relief_valves nv ON nv.id = e.new_installed_valve_id
  LEFT JOIN installed_relief_valves o ON o.id = e.replaced_installed_valve_id
  LEFT JOIN srv_issue_sheets sh ON sh.id = e.sheet_id
  LEFT JOIN srv_field_log l ON l.issue_id = e.id AND l.reason = 'replaced_on_issue'
                           AND l.installed_valve_id = e.replaced_installed_valve_id AND l.archived_at IS NULL
 WHERE e.cancelled_at IS NULL;
COMMENT ON VIEW v_srv_issue_sheet IS
  'Rows of the warehouse issue workbook: every live SRV issue with its sheet (NULL until exported), Cairo issue day, place, Stage/Storage, issued and replaced valve.';
GRANT SELECT ON v_srv_issue_sheet TO authenticated;
REVOKE ALL ON v_srv_issue_sheet FROM anon;
