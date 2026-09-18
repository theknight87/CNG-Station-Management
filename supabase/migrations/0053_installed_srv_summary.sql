-- 0053_installed_srv_summary.sql
-- One-round-trip attention summary for Installed SRV Management (Prompt 25J-B).
--
-- ADDS NO TABLE, NO COLUMN, NO ENUM, NO CONSTRAINT, NO INDEX, NO POLICY and NO
-- FUNCTION. It adds exactly ONE view and changes nothing that exists.
--
-- ============================== WHY IT EXISTS ===============================
--
-- `/manage/srvs/installed` rendered "The attention summary could not be loaded"
-- in production. DIAGNOSIS, from `pg_stat_statements` on the real browser
-- traffic, not from the banner: the summary fired SEVEN parallel count queries
-- at `v_installed_srv_management`, and those statements peaked at
-- 7910 / 7855 / 7581 / 7327 ms against the `authenticated` role's
-- `statement_timeout = 8s`. Whichever one crossed the line was cancelled
-- (57014), and the hook fails the WHOLE strip if ANY of the seven errors --
-- deliberately, because seven metrics where one silently reads 0 is a lie in a
-- smaller box. So the table kept working and only the counts went red.
--
-- WHY IT SURFACED NOW. The Prompt 25J batch confirmed a Station on 1,054 rows,
-- which moves them from the `irv_select` branch `cng_can_access_unmapped_srv()`
-- -- a bare role check, no argument, foldable -- to
-- `cng_can_read_region(region_id)`, which takes a per-row argument and is
-- evaluated per row. Measured in production under real RLS: 0.21 ms/row on the
-- Station-unconfirmed branch versus 0.51 ms/row on the Station-confirmed one,
-- ~2.4x. The seven-way fan-out was ALREADY marginal; the batch pushed it over.
-- The defect is the fan-out, not the mapping, and nothing about the 1,054 rows
-- is wrong.
--
-- THE FIX IS TO STOP SCANNING SEVEN TIMES. One view, evaluated once, returns
-- all seven counts in a single row: one round trip instead of seven, one
-- RLS-evaluated scan instead of seven, and six fewer chances to trip the
-- timeout. Raising `statement_timeout` was deliberately NOT the fix -- a
-- 2,662-row summary has no business taking 8 seconds, and a longer timeout
-- would only let the same fan-out bite a larger dataset later.
--
-- WHY A VIEW AND NOT CLIENT-SIDE TALLYING. Counting in the browser would mean
-- fetching every row and tallying, which PostgREST may silently truncate at its
-- max-rows limit -- producing counts that are WRONG rather than absent. A wrong
-- count is worse than a stated failure (section 11.5), so the aggregation stays
-- in SQL where it cannot be truncated.
--
-- SECURITY IS UNCHANGED. `security_invoker = true` is stated explicitly -- a
-- view created without it runs with OWNER rights and would silently bypass the
-- RLS that bounds it (the Prompt 19B defect). Because it is invoker, every
-- count is still computed under the CALLER's own policies: the same seven
-- numbers they would have got from seven queries, so a Region-scoped user can
-- never learn the size of a Region they cannot read. No grant beyond SELECT to
-- `authenticated`, and `anon` gets nothing.
CREATE VIEW v_installed_srv_summary WITH (security_invoker = true) AS
  SELECT
    count(*)::bigint AS total,
    count(*) FILTER (WHERE m.due_status = 'overdue')::bigint AS overdue,
    -- Stated explicitly, exactly as the UI states it: this bucket INCLUDES
    -- overdue. It is "needs attention", not "due but not yet overdue".
    count(*) FILTER (WHERE m.due_status IN
      ('overdue','due_today','due_7','due_15','due_30','due_60'))::bigint AS attention,
    count(*) FILTER (WHERE m.mapping_status = 'needs_station_mapping')::bigint AS needs_station_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'needs_unit_mapping')::bigint AS needs_unit_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'needs_equipment_mapping')::bigint AS needs_equipment_mapping,
    count(*) FILTER (WHERE m.mapping_status = 'conflict')::bigint AS conflict
  FROM v_installed_srv_management m;

COMMENT ON VIEW v_installed_srv_summary IS
  'The Installed SRV attention strip as ONE row, so the screen makes one round trip and the '
  'database performs one RLS-evaluated scan instead of seven. Counts the whole authorized dataset, '
  'never the active filters. security_invoker, so every count is the caller''s own and the totals '
  'can never reveal the size of a Region they cannot read.';

REVOKE ALL ON v_installed_srv_summary FROM PUBLIC;
GRANT SELECT ON v_installed_srv_summary TO authenticated;
