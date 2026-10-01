-- Owner request 2026-10-01: the Installed SRV "Due" bucket is overdue PLUS due within 30 days, not 60. Only the
-- bucket list changes (due_60 leaves it) in the summary view and the filtered summary function; columns, grants,
-- security_invoker and every other predicate are unchanged (the view's reloptions are restated, the 19B lesson).
-- The mapping counts stay in the summary for compatibility; the screen no longer shows the three "Needs" tiles.

CREATE OR REPLACE VIEW v_installed_srv_summary WITH (security_invoker = true) AS
  SELECT
    count(*)::bigint AS total,
    count(*) FILTER (WHERE m.due_status = 'overdue')::bigint AS overdue,
    -- Owner request 2026-10-01: the attention bucket is overdue PLUS due within 30 days (was 60).
    count(*) FILTER (WHERE m.due_status IN
      ('overdue','due_today','due_7','due_15','due_30'))::bigint AS attention,
    count(*) FILTER (WHERE m.mapping_status = 'needs_station_mapping')::bigint AS needs_station_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'needs_unit_mapping')::bigint AS needs_unit_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'needs_equipment_mapping')::bigint AS needs_equipment_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'conflict')::bigint AS conflict
  FROM v_installed_srv_management m;

COMMENT ON VIEW v_installed_srv_summary IS
  'The Installed SRV attention strip as ONE row, so the screen makes one round trip and the '
  'database performs one RLS-evaluated scan instead of seven. Counts the whole authorized dataset, '
  'never the active filters. security_invoker, so every count is the caller''s own and the totals '
  'can never reveal the size of a Region they cannot read. attention = overdue + due within 30 days.';

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
         count(*) FILTER (WHERE m.due_status IN ('overdue','due_today','due_7','due_15','due_30')),
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
                         WHEN 'attention' THEN m.due_status::text IN ('overdue','due_today','due_7','due_15','due_30')
                         ELSE true END)
     AND (nullif(p->>'serial', '') IS NULL OR m.serial_number ILIKE '%' || (p->>'serial') || '%')
     AND (nullif(p->>'station', '') IS NULL OR m.station_display ILIKE '%' || (p->>'station') || '%')
     AND (nullif(p->>'size_type', '') IS NULL OR m.size_type ILIKE p->>'size_type')
     AND (nullif(p->>'inlet', '') IS NULL OR m.inlet_size ILIKE (p->>'inlet') || '%')
     AND (nullif(p->>'outlet', '') IS NULL OR m.outlet_size ILIKE (p->>'outlet') || '%')
     AND (nullif(p->>'pressure', '') IS NULL OR (m.pressure_min <= (p->>'pressure')::numeric AND m.pressure_max >= (p->>'pressure')::numeric))
     AND (nullif(p->>'pressure_lo', '') IS NULL OR m.pressure_max >= (p->>'pressure_lo')::numeric)
     AND (nullif(p->>'pressure_hi', '') IS NULL OR m.pressure_min <= (p->>'pressure_hi')::numeric)
     AND (nullif(p->>'manufacturer', '') IS NULL OR m.manufacturer ILIKE p->>'manufacturer')
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
  'The Installed SRV attention strip for the active filters (same predicates as the table), one scan, SECURITY INVOKER so RLS bounds every count. attention = overdue + due within 30 days (owner request 2026-10-01).';
REVOKE ALL ON FUNCTION cng_installed_srv_summary_filtered(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_installed_srv_summary_filtered(jsonb) TO authenticated;
