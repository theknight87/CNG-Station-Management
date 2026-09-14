-- 0022_alert_rules_read.sql
-- `alert_rules` is threshold configuration (60/30/15/7/due today/overdue per
-- subject), not operational data. Prompt 5 left it with RLS enabled, no policy
-- and no grant, which is safe but indistinguishable from an oversight — and it
-- would stop the UI explaining WHY an alert fired.
--
-- Make the decision explicit: any activated user may READ the thresholds;
-- nobody may write them through the API. Changing a threshold remains a
-- migration, which keeps it reviewed and attributable in git, exactly like the
-- owner-confirmed rules.

GRANT SELECT ON alert_rules TO authenticated;

CREATE POLICY alert_rules_select ON alert_rules FOR SELECT TO authenticated
  USING (cng_current_role() IS NOT NULL);

COMMENT ON TABLE alert_rules IS
  'Alert threshold configuration. Readable by any activated user; not writable through the API by any role — thresholds change by migration.';
