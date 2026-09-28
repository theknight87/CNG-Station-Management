-- Owner request 2026-09-28: a Manufacturer filter, and Set pressure as a range ("30-35" = every valve whose recorded
-- range overlaps 30..35). The summary strip must count exactly what the table shows, so its function learns the same
-- two predicates: pressure_lo/pressure_hi (overlap) and manufacturer (case-insensitive exact). The old single 'pressure'
-- key is kept so an already-open page keeps working. Otherwise identical to 20260928110000.

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
         count(*) FILTER (WHERE m.due_status IN ('overdue','due_today','due_7','due_15','due_30','due_60')),
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
                         WHEN 'attention' THEN m.due_status::text IN ('overdue','due_today','due_7','due_15','due_30','due_60')
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
  'The Installed SRV attention strip for the active filters (same predicates as the table), one scan, SECURITY INVOKER so RLS bounds every count.';
REVOKE ALL ON FUNCTION cng_installed_srv_summary_filtered(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_installed_srv_summary_filtered(jsonb) TO authenticated;
