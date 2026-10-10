-- 20261010100000_equipment_issue_sheets.sql — the warehouse issue sheet for hoses and gas detectors (owner request
-- 2026-10-10: what the relief valves have, every section has; the SRV sheet is 20261003130000 / 20261004090000 /
-- 20261006110000). One workbook per kind, Region and month, one sheet per Cairo issue day; a later export the same day
-- gets a NEW sheet "(2)", "(3)"…, and sheets already sent are written again unchanged.
--
-- (1) equipment_issue_sheets: one row per sheet — kind, Region, issue day, sequence for that day, who exported it and
--     when. Select-only RLS like equipment_issues; no browser write grant.
-- (2) equipment_issues.sheet_id: the sheet an issue was first exported in (NULL until then).
-- (3) cng_equipment_issue_sheet_assign(kind, region, month): admin only, SECURITY DEFINER, audited, serialised per kind,
--     Region and month. Places every issue of that kind/Region/month that LEFT THE WAREHOUSE and is on no sheet yet into a
--     new sheet for its day: live issues, issues undone as "still at the station" (await_return) and issues moved on to
--     another Station (transferred). An issue undone "back in the warehouse" (to_stock) never left; a move between
--     Stations is not a warehouse exit — neither is ever placed.
-- (4) v_equipment_issue_sheet: the rows. A moved item reads as issued straight to where it ended up (the SRV ruling of
--     2026-10-06): Station, Unit and the item it replaced (and when that one came back) come from the LAST issue of the
--     move chain; the row keeps the day and Region it left the warehouse. An undone issue is marked cancelled.
--     security_invoker, so equipment_issues' RLS bounds it.

-- (1)
CREATE TABLE equipment_issue_sheets (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        text NOT NULL CHECK (kind IN ('hose', 'gas_detector')),
  region_id   uuid NOT NULL REFERENCES regions(id),
  issue_day   date NOT NULL,
  seq         integer NOT NULL CHECK (seq >= 1),
  exported_by uuid NOT NULL REFERENCES app_users(id),
  exported_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT equipment_issue_sheets_day_seq_uq UNIQUE (kind, region_id, issue_day, seq)
);
COMMENT ON TABLE equipment_issue_sheets IS
  'One sheet of a hose / gas detector warehouse issue workbook (kind, Region, issue day, n-th export that day). Written only by cng_equipment_issue_sheet_assign.';
ALTER TABLE equipment_issue_sheets ENABLE ROW LEVEL SECURITY;
CREATE POLICY equipment_issue_sheets_select ON equipment_issue_sheets FOR SELECT TO authenticated
  USING ((SELECT cng_is_manager_or_admin()) OR cng_has_region_grant(region_id, false));
REVOKE ALL ON equipment_issue_sheets FROM PUBLIC, anon, authenticated;
GRANT SELECT ON equipment_issue_sheets TO authenticated;

-- (2)
ALTER TABLE equipment_issues ADD COLUMN IF NOT EXISTS sheet_id uuid NULL REFERENCES equipment_issue_sheets(id);
CREATE INDEX IF NOT EXISTS equipment_issues_sheet_idx ON equipment_issues (sheet_id);
CREATE INDEX IF NOT EXISTS equipment_issues_region_issued_idx ON equipment_issues (kind, region_id, issued_at);
COMMENT ON COLUMN equipment_issues.sheet_id IS 'The issue sheet this issue was first exported in; NULL until exported.';

-- (3)
CREATE OR REPLACE FUNCTION cng_equipment_issue_sheet_assign(p_kind text, p_region_id uuid, p_month date)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_from date; v_to date; v_day date; v_seq integer; v_sheet uuid; v_n integer; v_total integer := 0;
  v_region text;
BEGIN
  IF p_kind IS NULL OR p_kind NOT IN ('hose', 'gas_detector') THEN RAISE EXCEPTION 'unknown equipment kind' USING ERRCODE = '22023'; END IF;
  IF p_region_id IS NULL OR p_month IS NULL THEN RAISE EXCEPTION 'choose a Region and a month' USING ERRCODE = '22023'; END IF;
  SELECT name INTO v_region FROM regions WHERE id = p_region_id;
  IF v_region IS NULL THEN RAISE EXCEPTION 'Region not found' USING ERRCODE = '42704'; END IF;
  v_from := date_trunc('month', p_month)::date;
  v_to := (v_from + interval '1 month')::date;
  PERFORM pg_advisory_xact_lock(hashtext('cng_equipment_issue_sheet:' || p_kind || ':' || p_region_id::text || ':' || v_from::text));

  FOR v_day IN
    SELECT DISTINCT (e.issued_at AT TIME ZONE 'Africa/Cairo')::date
      FROM equipment_issues e
     WHERE e.kind = p_kind AND e.region_id = p_region_id AND e.sheet_id IS NULL
       AND (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
       AND e.transferred_from_issue_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date >= v_from
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date < v_to
     ORDER BY 1
  LOOP
    SELECT coalesce(max(seq), 0) + 1 INTO v_seq FROM equipment_issue_sheets
     WHERE kind = p_kind AND region_id = p_region_id AND issue_day = v_day;
    INSERT INTO equipment_issue_sheets (kind, region_id, issue_day, seq, exported_by) VALUES (p_kind, p_region_id, v_day, v_seq, v_actor)
      RETURNING id INTO v_sheet;
    UPDATE equipment_issues e SET sheet_id = v_sheet
     WHERE e.kind = p_kind AND e.region_id = p_region_id AND e.sheet_id IS NULL
       AND (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
       AND e.transferred_from_issue_id IS NULL
       AND (e.issued_at AT TIME ZONE 'Africa/Cairo')::date = v_day;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_total := v_total + v_n;
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label, summary, after_data, occurred_at)
    VALUES ('admin_action', 'equipment_issue_sheets', v_sheet, v_actor, 'equipment_issue_sheet',
            format('%s issue sheet %s %s%s exported with %s item(s)', replace(p_kind, '_', ' '), v_region,
                   to_char(v_day, 'FMDD-FMMM-YYYY'), CASE WHEN v_seq > 1 THEN ' (' || v_seq || ')' ELSE '' END, v_n),
            jsonb_build_object('kind', p_kind, 'region_id', p_region_id, 'issue_day', v_day, 'seq', v_seq, 'issues', v_n), now());
  END LOOP;
  RETURN v_total;
END $$;
COMMENT ON FUNCTION cng_equipment_issue_sheet_assign(text, uuid, date) IS
  'Admin: put every hose / gas detector issue of the kind, Region and month that left the warehouse (live, undone awaiting return, or moved on to another Station) and is on no sheet yet into a new sheet for its day. A move between Stations is never placed. Returns how many issues were placed.';
REVOKE ALL ON FUNCTION cng_equipment_issue_sheet_assign(text, uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_equipment_issue_sheet_assign(text, uuid, date) TO authenticated;

-- (4)
CREATE OR REPLACE VIEW v_equipment_issue_sheet WITH (security_invoker = true) AS
WITH RECURSIVE chain AS (
  SELECT i.id AS origin, i.id AS cur, 0 AS depth FROM equipment_issues i WHERE i.transferred_from_issue_id IS NULL
  UNION ALL
  SELECT c.origin, t.id, c.depth + 1 FROM chain c JOIN equipment_issues t ON t.transferred_from_issue_id = c.cur
), final AS (
  SELECT DISTINCT ON (origin) origin, cur FROM chain ORDER BY origin, depth DESC
)
SELECT e.id, e.kind,
       e.issued_at,
       (e.issued_at AT TIME ZONE 'Africa/Cairo')::date AS issue_day,
       e.region_id, r.name AS region_name,
       e.sheet_id, sh.seq AS sheet_seq, sh.exported_at AS sheet_exported_at,
       e.is_emergency,
       s.station_name, u.unit_name,
       coalesce(u.unit_name, s.station_name) AS place_name,
       e.stock_id,
       w.serial_number AS issued_serial, w.warehouse_code AS issued_code,
       w.manufacturer, w.model, w.description,
       w.working_pressure_value, w.working_pressure_unit, w.test_pressure_value, w.test_pressure_unit,
       coalesce(f.replaced_hose_id, f.replaced_gas_detector_id) AS replaced_id,
       coalesce(rh.serial_number, rg.serial_number) AS replaced_serial,
       l.returned_at AS replaced_returned_at,
       (f.cancel_action = 'await_return' OR (f.id <> e.id AND f.cancel_action = 'to_stock')) IS TRUE AS is_cancelled,
       CASE WHEN f.cancel_action IN ('await_return', 'to_stock') THEN f.cancelled_at END AS cancelled_at,
       ul.returned_at AS cancelled_returned_at,
       CASE WHEN f.id <> e.id THEN coalesce(u.unit_name, s.station_name) END AS transferred_to
  FROM equipment_issues e
  JOIN final fi ON fi.origin = e.id
  JOIN equipment_issues f ON f.id = fi.cur
  JOIN regions r ON r.id = e.region_id
  JOIN stations s ON s.id = f.station_id
  LEFT JOIN units u ON u.id = f.unit_id
  JOIN equipment_stock w ON w.id = e.stock_id
  LEFT JOIN hoses rh ON rh.id = f.replaced_hose_id
  LEFT JOIN gas_detectors rg ON rg.id = f.replaced_gas_detector_id
  LEFT JOIN equipment_issue_sheets sh ON sh.id = e.sheet_id
  LEFT JOIN equipment_field_log l ON l.issue_id = f.id AND l.reason = 'replaced_on_issue' AND l.archived_at IS NULL
  LEFT JOIN equipment_field_log ul ON ul.issue_id = f.id AND ul.reason = 'issue_undone' AND ul.archived_at IS NULL
 WHERE (e.cancelled_at IS NULL OR e.cancel_action IN ('await_return', 'transferred'))
   AND e.transferred_from_issue_id IS NULL;
COMMENT ON VIEW v_equipment_issue_sheet IS
  'Rows of the hose / gas detector warehouse issue workbook: every issue that left the warehouse, on the day and Region it left; a moved item reads as issued straight to where it ended up (last issue of the move chain); an undone one is marked cancelled.';
REVOKE ALL ON v_equipment_issue_sheet FROM PUBLIC, anon;
GRANT SELECT ON v_equipment_issue_sheet TO authenticated;
