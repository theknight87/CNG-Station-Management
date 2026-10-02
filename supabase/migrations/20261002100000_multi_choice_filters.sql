-- Multi-choice filters (owner request 2026-10-02): a filter may hold several values and may exclude them —
-- "overdue valves of every manufacturer except EKC".
--
-- The browser stores such a choice as one string: '' = every row, 'a|b' = only a or b, '!a|b' = every row except
-- a and b (a row with nothing recorded is kept: it is neither a nor b). The tables apply it through PostgREST
-- directly; the ONE place a filter reaches SQL as a parameter is the Installed SRV attention strip, whose counts
-- must use the same predicate as the table they sit above. So:
--
--   cng_multi_match(value, choice, case_insensitive) — the predicate, pure and IMMUTABLE, no SET clause, every
--                                                      name built-in, so the planner can inline it;
--   cng_installed_srv_summary_filtered(p)            — the same body as 20261001110000 with region, mapping,
--                                                      parent kind, due and manufacturer read through it.
--
-- A single value ('overdue', a region id, 'EKC') is a one-item choice, so every caller written before this keeps
-- its meaning. The legacy due token 'attention' is still honoured. SECURITY INVOKER, grants and comment unchanged
-- in substance; no table, view, policy or data is touched.

CREATE OR REPLACE FUNCTION public.cng_multi_match(p_value text, p_choice text, p_case_insensitive boolean DEFAULT false)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
           WHEN p_choice IS NULL OR p_choice IN ('', 'all', '!') THEN true
           WHEN left(p_choice, 1) = '!' THEN NOT coalesce(
             CASE WHEN p_case_insensitive
                  THEN lower(p_value) = ANY (string_to_array(lower(substr(p_choice, 2)), '|'))
                  ELSE p_value = ANY (string_to_array(substr(p_choice, 2), '|')) END, false)
           ELSE coalesce(
             CASE WHEN p_case_insensitive
                  THEN lower(p_value) = ANY (string_to_array(lower(p_choice), '|'))
                  ELSE p_value = ANY (string_to_array(p_choice, '|')) END, false)
         END;
$$;
COMMENT ON FUNCTION public.cng_multi_match(text, text, boolean) IS
  'Multi-choice filter predicate (owner request 2026-10-02): '''' = all, ''a|b'' = only a or b, ''!a|b'' = all except a and b (an unrecorded value is kept).';
REVOKE ALL ON FUNCTION public.cng_multi_match(text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cng_multi_match(text, text, boolean) TO authenticated;

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
   WHERE public.cng_multi_match(m.region_id::text, p->>'region_id')
     AND public.cng_multi_match(m.mapping_status::text, p->>'mapping')
     AND public.cng_multi_match(m.parent_kind::text, p->>'parent_kind')
     AND public.cng_multi_match(m.due_status::text,
           replace(p->>'due', 'attention', 'overdue|due_today|due_7|due_15|due_30'))
     AND (nullif(p->>'serial', '') IS NULL OR m.serial_number ILIKE '%' || (p->>'serial') || '%')
     AND (nullif(p->>'station', '') IS NULL OR m.station_display ILIKE '%' || (p->>'station') || '%')
     AND (nullif(p->>'size_type', '') IS NULL OR m.size_type ILIKE p->>'size_type')
     AND (nullif(p->>'inlet', '') IS NULL OR m.inlet_size ILIKE (p->>'inlet') || '%')
     AND (nullif(p->>'outlet', '') IS NULL OR m.outlet_size ILIKE (p->>'outlet') || '%')
     AND (nullif(p->>'pressure', '') IS NULL OR (m.pressure_min <= (p->>'pressure')::numeric AND m.pressure_max >= (p->>'pressure')::numeric))
     AND (nullif(p->>'pressure_lo', '') IS NULL OR m.pressure_max >= (p->>'pressure_lo')::numeric)
     AND (nullif(p->>'pressure_hi', '') IS NULL OR m.pressure_min <= (p->>'pressure_hi')::numeric)
     AND public.cng_multi_match(m.manufacturer, p->>'manufacturer', true)
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
  'The Installed SRV attention strip for the active filters (same predicates as the table), one scan, SECURITY INVOKER so RLS bounds every count. attention = overdue + due within 30 days (owner request 2026-10-01). Region, mapping, parent kind, due and manufacturer accept multi-choice values via cng_multi_match (owner request 2026-10-02).';
REVOKE ALL ON FUNCTION cng_installed_srv_summary_filtered(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION cng_installed_srv_summary_filtered(jsonb) TO authenticated;
