-- 0019_grants.sql
-- SQL privileges. Closed by default: `anon` receives NOTHING, and
-- `authenticated` receives only the specific privileges the application needs.
--
-- GRANT and RLS are two independent layers. A request must satisfy BOTH: it
-- needs the SQL privilege AND a policy that admits the row. Everything not
-- granted here is impossible regardless of any policy.
--
-- Deliberate absences (these operations are IMPOSSIBLE through the API, for
-- every role including admin):
--   * DELETE on every operational, import, audit and authorization table except
--     `user_region_access` (revoking a grant) and a user's own notification rows.
--     Records carrying history are archived (`archived_at`), never destroyed.
--   * INSERT on `app_users` — accounts are created only by the Clerk webhook
--     running server-side, so a user cannot forge a row claiming another Clerk id.
--   * INSERT/UPDATE/DELETE on `owner_confirmed_station_aliases` and
--     `owner_confirmed_part_numbers` — owner rulings change only by migration,
--     which makes every change reviewed and permanently attributable in git.
--   * INSERT/UPDATE/DELETE on `regions` — a closed six-value reference set.
--   * UPDATE/DELETE on `audit_logs` and `asset_mapping_audit` — append-only.
--   * INSERT on `alerts` — generated server-side by the alert engine.
--
-- Column-level grants are used where a role legitimately updates only part of a
-- row (acknowledging an alert, resolving an import issue, changing a user's
-- role). A column that is not granted cannot be written even by a policy that
-- admits the row — this is what stops mass-assignment escalation.

-- The API roles are created in 0018, which must run first.

-- ---------------------------------------------------------------------------
-- Baseline: revoke everything from both API roles, then grant back explicitly.
-- ---------------------------------------------------------------------------

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON SCHEMA public FROM anon, authenticated;

-- USAGE on the schema only; it conveys no access to any object by itself.
GRANT USAGE ON SCHEMA public TO authenticated;
-- `anon` deliberately receives no schema usage at all: an unauthenticated
-- request cannot even resolve an object name in `public`.

-- ---------------------------------------------------------------------------
-- A. Operational hierarchy and equipment
-- ---------------------------------------------------------------------------

GRANT SELECT ON regions TO authenticated;          -- reference data, read-only

GRANT SELECT, INSERT, UPDATE ON stations        TO authenticated;
GRANT SELECT, INSERT, UPDATE ON units           TO authenticated;
GRANT SELECT, INSERT, UPDATE ON compressors     TO authenticated;
GRANT SELECT, INSERT, UPDATE ON recovery_tanks  TO authenticated;
GRANT SELECT, INSERT, UPDATE ON storage_vessels TO authenticated;
GRANT SELECT, INSERT, UPDATE ON dispensers      TO authenticated;
GRANT SELECT, INSERT, UPDATE ON gas_detectors   TO authenticated;
GRANT SELECT, INSERT, UPDATE ON gas_detector_presence TO authenticated;
GRANT SELECT, INSERT, UPDATE ON hoses           TO authenticated;
GRANT SELECT, INSERT, UPDATE ON installed_relief_valves TO authenticated;
GRANT SELECT, INSERT, UPDATE ON warehouse_relief_valves TO authenticated;

-- Alias resolution is part of the mapping workflow.
GRANT SELECT, INSERT, UPDATE ON station_aliases TO authenticated;
GRANT SELECT, INSERT, UPDATE ON unit_aliases    TO authenticated;

-- ---------------------------------------------------------------------------
-- B. Owner-confirmed rules — readable, never writable through the API
-- ---------------------------------------------------------------------------

GRANT SELECT ON owner_confirmed_station_aliases TO authenticated;
GRANT SELECT ON owner_confirmed_part_numbers    TO authenticated;

-- ---------------------------------------------------------------------------
-- C. Authorization tables
-- ---------------------------------------------------------------------------

GRANT SELECT ON app_users TO authenticated;
-- Only these columns may ever be written, and only by an admin (see policies).
-- `clerk_user_id` is intentionally absent: identity cannot be re-pointed.
GRANT UPDATE (role, is_active, full_name, email) ON app_users TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON user_region_access TO authenticated;

-- ---------------------------------------------------------------------------
-- D. Import / Data Quality
-- ---------------------------------------------------------------------------

GRANT SELECT ON import_batches TO authenticated;
GRANT SELECT ON import_issues  TO authenticated;
-- Resolving an issue touches only the resolution fields.
GRANT UPDATE (status, resolution, resolved_by, resolved_at) ON import_issues TO authenticated;

-- ---------------------------------------------------------------------------
-- E. Alerts and notifications
-- ---------------------------------------------------------------------------

GRANT SELECT ON alerts TO authenticated;
-- Acknowledging an alert must not let a client rewrite the alert's subject,
-- due date, asset or region.
GRANT UPDATE (state, acknowledged_by, acknowledged_at, resolved_at) ON alerts TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON notification_preferences TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON push_subscriptions       TO authenticated;
GRANT SELECT ON notification_deliveries TO authenticated;

-- ---------------------------------------------------------------------------
-- F. Audit — append-only
-- ---------------------------------------------------------------------------

GRANT SELECT, INSERT ON asset_mapping_audit TO authenticated;
GRANT SELECT, INSERT ON audit_logs          TO authenticated;

-- ---------------------------------------------------------------------------
-- G. Views. These are security_invoker, so base-table RLS still applies to
--    whoever queries them; the grant only makes the name resolvable.
-- ---------------------------------------------------------------------------

GRANT SELECT ON v_installed_srv_management TO authenticated;
GRANT SELECT ON v_unit_srvs                TO authenticated;
GRANT SELECT ON v_srv_mapping_queue        TO authenticated;
GRANT SELECT ON v_warehouse_srv_management TO authenticated;
GRANT SELECT ON v_vessel_management        TO authenticated;
GRANT SELECT ON v_gas_detector_management  TO authenticated;
GRANT SELECT ON v_hose_management          TO authenticated;
GRANT SELECT ON v_data_quality_queue       TO authenticated;

-- ---------------------------------------------------------------------------
-- Future objects must not inherit privileges by accident.
-- ---------------------------------------------------------------------------

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon;
