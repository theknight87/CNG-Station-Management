-- ---------------------------------------------------------------------------
-- 0038 — Admin module (Prompt 19): privileged mutation, atomically audited.
--
-- WHAT WAS ALREADY TRUE, AND IS NOT REBUILT HERE:
--
--   * The DATABASE already enforces the physical hierarchy. `irv_unit_station_fk
--     (unit_id, station_id) -> units(id, station_id)` makes a Unit from another
--     Station impossible; `irv_compressor_unit_fk (compressor_id, unit_id)` and
--     its vessel/dispenser siblings make equipment from another Unit impossible;
--     `irv_status_shape_ck` requires exactly one equipment parent for `resolved`
--     and none before it. None of that is re-implemented in application code and
--     NONE of it is relaxed — the functions below lean on it.
--   * `audit_logs` and `asset_mapping_audit` are already append-only: only
--     SELECT and INSERT are granted, so no application role can rewrite history.
--     Their INSERT policies require `actor_id = cng_current_app_user_id()`, so
--     the actor cannot be forged.
--
-- WHAT WAS WRONG, AND IS FIXED HERE:
--
--   `authenticated` held DIRECT `UPDATE (role, is_active, ...)` on `app_users`
--   and full INSERT/UPDATE/DELETE on `user_region_access`, gated only by
--   `cng_is_admin()`. That is authorization-bearing mutation performed straight
--   from a browser, which means:
--     - NO audit record is guaranteed. Writing one was a separate client call an
--       admin could simply not make.
--     - NOTHING stopped an admin demoting or deactivating themselves, or
--       removing the last active administrator and locking the product.
--     - A stale tab could silently overwrite a newer decision.
--
--   Those grants are revoked below and replaced by narrow SECURITY DEFINER
--   functions. Each one: verifies admin, derives the actor server-side, checks a
--   caller-supplied `updated_at` precondition, applies the change, and writes the
--   audit row IN THE SAME STATEMENT — so an audited mutation cannot become an
--   unaudited one by dropping a second call.
--
-- WHY `GRANT EXECUTE ... TO authenticated` IS CORRECT FOR A SECURITY DEFINER
-- FUNCTION HERE: the browser must be able to CALL them. Being callable is not
-- being permitted — every one re-checks `cng_is_admin()` internally and raises
-- otherwise, exactly as `cng_acknowledge_alert` has since 0031.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- 1. Close the direct authorization-bearing write paths.
--
-- `full_name` and `email` are IDENTITY, not authorization, and are synchronised
-- from Clerk by service_role; they are deliberately left alone. Only the two
-- columns that decide what a person may do are withdrawn.
-- ===========================================================================
REVOKE UPDATE (role, is_active) ON app_users FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON user_region_access FROM authenticated;

-- ===========================================================================
-- Shared internals.
-- ===========================================================================

/**
 * Raise unless the caller is an active administrator.
 * Called first in every function below, before any argument is even read.
 */
CREATE FUNCTION cng_require_admin()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE v_actor uuid := cng_current_app_user_id();
BEGIN
  IF v_actor IS NULL THEN
    RAISE EXCEPTION 'no active application user' USING ERRCODE = '42501';
  END IF;
  IF NOT cng_is_admin() THEN
    RAISE EXCEPTION 'administrator privilege required' USING ERRCODE = '42501';
  END IF;
  RETURN v_actor;
END $$;

COMMENT ON FUNCTION cng_require_admin() IS
  'Returns the acting admin''s app_user id, or raises 42501. The actor is derived from the verified Clerk subject and is never a parameter.';

REVOKE ALL ON FUNCTION cng_require_admin() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_require_admin() TO authenticated;

/**
 * The stale-write guard.
 *
 * Every admin mutation takes the `updated_at` the caller last SAW. If the row
 * has moved on, the write is refused rather than applied on top of a decision
 * the caller never read. Last-write-wins on a role or a mapping is how one
 * admin silently undoes another.
 *
 * NULL means "no precondition" and is used only by callers that have just read
 * the row inside the same statement.
 */
CREATE FUNCTION cng_check_precondition(p_actual timestamptz, p_expected timestamptz)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF p_expected IS NOT NULL AND p_actual IS DISTINCT FROM p_expected THEN
    RAISE EXCEPTION 'stale_write: this record changed since you loaded it'
      USING ERRCODE = '40001';
  END IF;
END $$;

REVOKE ALL ON FUNCTION cng_check_precondition(timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_check_precondition(timestamptz, timestamptz) TO authenticated;

-- ===========================================================================
-- 2. USER ADMINISTRATION
-- ===========================================================================

/**
 * Change a user's application role.
 *
 * THREE SAFETY RULES, chosen as the safest operational behaviour and documented
 * rather than invented silently:
 *
 *  1. An admin may NOT change their own role. Self-demotion is the single
 *     easiest way to lock yourself out, and it has no legitimate use that a
 *     second administrator cannot serve.
 *  2. The LAST ACTIVE ADMIN may not be demoted. The product must never be left
 *     with zero administrators by an ordinary UI action.
 *  3. A stale write is refused.
 */
CREATE FUNCTION cng_admin_set_user_role(
  p_app_user_id      uuid,
  p_role             app_role,
  p_expected_updated_at timestamptz DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor  uuid := cng_require_admin();
  v_before app_users%ROWTYPE;
  v_after  app_users%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM app_users WHERE id = p_app_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  IF v_before.id = v_actor AND p_role <> v_before.role THEN
    RAISE EXCEPTION 'an administrator cannot change their own role'
      USING ERRCODE = '42501';
  END IF;

  IF v_before.role = 'admin' AND p_role <> 'admin' AND v_before.is_active
     AND NOT EXISTS (SELECT 1 FROM app_users u
                      WHERE u.role = 'admin' AND u.is_active AND u.id <> v_before.id) THEN
    RAISE EXCEPTION 'the last active administrator cannot be demoted'
      USING ERRCODE = '23514';
  END IF;

  UPDATE app_users SET role = p_role, updated_at = now()
   WHERE id = p_app_user_id
  RETURNING * INTO v_after;

  -- Atomic with the change: the audit row cannot be omitted by a caller.
  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('user_role_changed', 'app_users', p_app_user_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('role %s -> %s', v_before.role, p_role),
          jsonb_build_object('role', v_before.role),
          jsonb_build_object('role', v_after.role));

  RETURN v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_set_user_role(uuid, app_role, timestamptz) IS
  'Admin-only. Refuses self-demotion, refuses demoting the last active admin, refuses a stale write, and audits atomically. The actor is server-derived.';

REVOKE ALL ON FUNCTION cng_admin_set_user_role(uuid, app_role, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_set_user_role(uuid, app_role, timestamptz) TO authenticated;

/**
 * Activate or deactivate application access.
 *
 * Deactivation is how access is withdrawn: `cng_current_app_user_id()` requires
 * `is_active`, so every policy in the system stops matching for that user on
 * their next statement — a stale browser session confers nothing.
 */
CREATE FUNCTION cng_admin_set_user_active(
  p_app_user_id      uuid,
  p_is_active        boolean,
  p_expected_updated_at timestamptz DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor  uuid := cng_require_admin();
  v_before app_users%ROWTYPE;
  v_after  app_users%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM app_users WHERE id = p_app_user_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  IF v_before.id = v_actor AND NOT p_is_active THEN
    RAISE EXCEPTION 'an administrator cannot deactivate themselves'
      USING ERRCODE = '42501';
  END IF;

  IF v_before.role = 'admin' AND v_before.is_active AND NOT p_is_active
     AND NOT EXISTS (SELECT 1 FROM app_users u
                      WHERE u.role = 'admin' AND u.is_active AND u.id <> v_before.id) THEN
    RAISE EXCEPTION 'the last active administrator cannot be deactivated'
      USING ERRCODE = '23514';
  END IF;

  UPDATE app_users SET is_active = p_is_active, updated_at = now()
   WHERE id = p_app_user_id
  RETURNING * INTO v_after;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('admin_action', 'app_users', p_app_user_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          CASE WHEN p_is_active THEN 'activated' ELSE 'deactivated' END,
          jsonb_build_object('is_active', v_before.is_active),
          jsonb_build_object('is_active', v_after.is_active));

  RETURN v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_set_user_active(uuid, boolean, timestamptz) IS
  'Admin-only. Refuses self-deactivation and deactivating the last active admin. Audited atomically.';

REVOKE ALL ON FUNCTION cng_admin_set_user_active(uuid, boolean, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_set_user_active(uuid, boolean, timestamptz) TO authenticated;

/**
 * Grant a Region to a user, or update the existing grant's `can_map`.
 *
 * Duplicates are impossible: `user_region_access_uq` already makes
 * (app_user_id, region_id) unique, so this upserts rather than inventing a
 * second grant. An INACTIVE user may still be granted a Region — the grant is a
 * stored intention, and `cng_current_app_user_id()` independently refuses to
 * resolve an inactive user, so a grant confers nothing until they are activated.
 * Refusing the grant instead would force admins to sequence two actions for no
 * security gain.
 */
CREATE FUNCTION cng_admin_grant_region(
  p_app_user_id uuid,
  p_region_id   uuid,
  p_can_map     boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_id    uuid;
  v_was   boolean;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM app_users WHERE id = p_app_user_id) THEN
    RAISE EXCEPTION 'user not found' USING ERRCODE = '42704';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM regions WHERE id = p_region_id) THEN
    RAISE EXCEPTION 'region not found' USING ERRCODE = '42704';
  END IF;

  SELECT can_map INTO v_was FROM user_region_access
   WHERE app_user_id = p_app_user_id AND region_id = p_region_id;

  INSERT INTO user_region_access (app_user_id, region_id, can_map, granted_by)
  VALUES (p_app_user_id, p_region_id, p_can_map, v_actor)
  ON CONFLICT (app_user_id, region_id)
  DO UPDATE SET can_map = excluded.can_map, granted_by = v_actor, updated_at = now()
  RETURNING id INTO v_id;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('region_access_changed', 'user_region_access', v_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          CASE WHEN v_was IS NULL THEN 'granted' ELSE 'updated' END,
          CASE WHEN v_was IS NULL THEN NULL
               ELSE jsonb_build_object('can_map', v_was) END,
          jsonb_build_object('app_user_id', p_app_user_id,
                             'region_id', p_region_id, 'can_map', p_can_map));
  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION cng_admin_grant_region(uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_grant_region(uuid, uuid, boolean) TO authenticated;

CREATE FUNCTION cng_admin_revoke_region(p_app_user_id uuid, p_region_id uuid)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor uuid := cng_require_admin();
  v_id    uuid;
  v_n     integer;
BEGIN
  SELECT id INTO v_id FROM user_region_access
   WHERE app_user_id = p_app_user_id AND region_id = p_region_id;
  DELETE FROM user_region_access
   WHERE app_user_id = p_app_user_id AND region_id = p_region_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF v_n > 0 THEN
    INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                            summary, before_data, after_data)
    VALUES ('region_access_changed', 'user_region_access', v_id, v_actor,
            (SELECT full_name FROM app_users WHERE id = v_actor),
            'revoked',
            jsonb_build_object('app_user_id', p_app_user_id, 'region_id', p_region_id),
            NULL);
  END IF;
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION cng_admin_revoke_region(uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_revoke_region(uuid, uuid) TO authenticated;

-- ===========================================================================
-- 3. ALERT RULES
--
-- Before this migration alert_rules had SELECT only, so the 30 seeded rules
-- could not be changed by anyone through the application. Only `is_enabled` is
-- editable: `threshold`, `days_before` and `subject` define the rule's IDENTITY
-- and are constrained by alert_rules_days_ck, and changing them would silently
-- reinterpret alerts already generated against them.
-- ===========================================================================
CREATE FUNCTION cng_admin_set_alert_rule_enabled(
  p_rule_id    uuid,
  p_is_enabled boolean,
  p_expected_updated_at timestamptz DEFAULT NULL
)
RETURNS timestamptz
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor  uuid := cng_require_admin();
  v_before alert_rules%ROWTYPE;
  v_after  alert_rules%ROWTYPE;
BEGIN
  SELECT * INTO v_before FROM alert_rules WHERE id = p_rule_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'alert rule not found' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  UPDATE alert_rules SET is_enabled = p_is_enabled, updated_at = now()
   WHERE id = p_rule_id
  RETURNING * INTO v_after;

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('alert_rule_changed', 'alert_rules', p_rule_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('%s %s: %s', v_before.subject, v_before.threshold,
                 CASE WHEN p_is_enabled THEN 'enabled' ELSE 'disabled' END),
          jsonb_build_object('is_enabled', v_before.is_enabled),
          jsonb_build_object('is_enabled', v_after.is_enabled));

  RETURN v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_set_alert_rule_enabled(uuid, boolean, timestamptz) IS
  'Admin-only. Enables or disables one alert rule. Subject, threshold and days_before are rule IDENTITY and are deliberately not editable: changing them would reinterpret alerts already generated. Disabling stops FUTURE generation and deletes no existing alert.';

REVOKE ALL ON FUNCTION cng_admin_set_alert_rule_enabled(uuid, boolean, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_set_alert_rule_enabled(uuid, boolean, timestamptz) TO authenticated;

-- ===========================================================================
-- 4. MANUAL SRV MAPPING
--
-- One function for the whole lifecycle, because the lifecycle is one decision:
-- how far up the chain has a human actually PROVEN this valve sits?
--
--     needs_station_mapping -> needs_unit_mapping
--                           -> needs_equipment_mapping -> resolved
--
-- The resulting SHAPE is not validated here in application logic. It is handed
-- to the database, where `irv_status_shape_ck` and the composite foreign keys
-- decide. A Unit belonging to another Station, equipment belonging to another
-- Unit, two equipment parents, or `resolved` without a parent are all rejected
-- by constraints that existed before this prompt and are untouched by it.
-- ===========================================================================
CREATE FUNCTION cng_admin_map_srv(
  p_srv_id      uuid,
  p_station_id  uuid,
  p_unit_id     uuid DEFAULT NULL,
  p_parent_kind srv_parent_kind DEFAULT NULL,
  p_parent_id   uuid DEFAULT NULL,
  p_expected_updated_at timestamptz DEFAULT NULL,
  p_reason      text DEFAULT NULL
)
RETURNS TABLE (mapping_status srv_mapping_status, updated_at timestamptz)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_actor  uuid := cng_require_admin();
  v_before installed_relief_valves%ROWTYPE;
  v_after  installed_relief_valves%ROWTYPE;
  v_status srv_mapping_status;
  v_region uuid;
BEGIN
  SELECT * INTO v_before FROM installed_relief_valves WHERE id = p_srv_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'relief valve not found' USING ERRCODE = '42704';
  END IF;
  PERFORM cng_check_precondition(v_before.updated_at, p_expected_updated_at);

  IF p_station_id IS NULL THEN
    RAISE EXCEPTION 'a Station must be confirmed before any deeper mapping'
      USING ERRCODE = '23514';
  END IF;
  -- The Region follows the Station. It is never taken from the caller, and never
  -- from the unconfirmed raw source value on the row.
  SELECT region_id INTO v_region FROM stations WHERE id = p_station_id;
  IF v_region IS NULL THEN
    RAISE EXCEPTION 'station not found' USING ERRCODE = '42704';
  END IF;

  IF (p_parent_kind IS NULL) <> (p_parent_id IS NULL) THEN
    RAISE EXCEPTION 'an equipment parent needs both a kind and an id'
      USING ERRCODE = '23514';
  END IF;
  IF p_parent_id IS NOT NULL AND p_unit_id IS NULL THEN
    RAISE EXCEPTION 'equipment cannot be confirmed before its Unit'
      USING ERRCODE = '23514';
  END IF;

  -- The status is DERIVED from what was proven, never supplied by the caller.
  v_status := CASE
    WHEN p_unit_id IS NULL     THEN 'needs_unit_mapping'
    WHEN p_parent_id IS NULL   THEN 'needs_equipment_mapping'
    ELSE 'resolved'
  END;

  UPDATE installed_relief_valves SET
    station_id        = p_station_id,
    region_id         = v_region,
    unit_id           = p_unit_id,
    compressor_id     = CASE WHEN p_parent_kind = 'compressor'     THEN p_parent_id END,
    storage_vessel_id = CASE WHEN p_parent_kind = 'storage_vessel' THEN p_parent_id END,
    dispenser_id      = CASE WHEN p_parent_kind = 'dispenser'      THEN p_parent_id END,
    mapping_status    = v_status,
    -- irv_resolved_attribution_ck: a resolved row must say WHO resolved it and
    -- WHEN. The actor is the server-derived admin, never a caller parameter, and
    -- the attribution is cleared again if a later correction un-resolves the row.
    resolved_by       = CASE WHEN v_status = 'resolved' THEN v_actor END,
    resolved_at       = CASE WHEN v_status = 'resolved' THEN now() END,
    updated_at        = now()
  WHERE id = p_srv_id
  RETURNING * INTO v_after;

  -- Source evidence is never touched: source_station_name_raw, source_raw and
  -- the file/sheet/row provenance columns are not in the UPDATE above.
  INSERT INTO asset_mapping_audit (
    asset_type, asset_id,
    previous_station_id, new_station_id, previous_unit_id, new_unit_id,
    previous_parent_type, previous_parent_id, new_parent_type, new_parent_id,
    previous_mapping_status, new_mapping_status, changed_by, reason)
  VALUES (
    'installed_relief_valve', p_srv_id,
    v_before.station_id, v_after.station_id, v_before.unit_id, v_after.unit_id,
    CASE WHEN v_before.compressor_id IS NOT NULL THEN 'compressor'::srv_parent_kind
         WHEN v_before.storage_vessel_id IS NOT NULL THEN 'storage_vessel'
         WHEN v_before.dispenser_id IS NOT NULL THEN 'dispenser' END,
    coalesce(v_before.compressor_id, v_before.storage_vessel_id, v_before.dispenser_id),
    p_parent_kind, p_parent_id,
    v_before.mapping_status::text, v_after.mapping_status::text, v_actor, p_reason);

  INSERT INTO audit_logs (action, entity_table, entity_id, actor_id, actor_label,
                          summary, before_data, after_data)
  VALUES ('mapping_changed', 'installed_relief_valves', p_srv_id, v_actor,
          (SELECT full_name FROM app_users WHERE id = v_actor),
          format('%s -> %s', v_before.mapping_status, v_after.mapping_status),
          jsonb_build_object('mapping_status', v_before.mapping_status,
                             'station_id', v_before.station_id,
                             'unit_id', v_before.unit_id),
          jsonb_build_object('mapping_status', v_after.mapping_status,
                             'station_id', v_after.station_id,
                             'unit_id', v_after.unit_id));

  RETURN QUERY SELECT v_after.mapping_status, v_after.updated_at;
END $$;

COMMENT ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) IS
  'Admin-only manual SRV mapping. The resulting mapping_status is DERIVED from what was proven, never supplied. Hierarchy validity is enforced by the pre-existing composite foreign keys and irv_status_shape_ck, not re-implemented here. Source evidence columns are never written. Audited atomically in both asset_mapping_audit and audit_logs.';

REVOKE ALL ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION cng_admin_map_srv(uuid, uuid, uuid, srv_parent_kind, uuid, timestamptz, text) TO authenticated;

-- ===========================================================================
-- 5. ADMIN READ SURFACES
--
-- security_invoker, so the existing policies decide visibility: app_users_select
-- already limits a non-admin to their own row, and audit_logs_select to their
-- own actions. These views add no reach.
-- ===========================================================================

CREATE VIEW v_admin_users WITH (security_invoker = true) AS
SELECT u.id, u.clerk_user_id, u.email, u.full_name, u.role, u.is_active,
       u.created_at, u.updated_at,
       coalesce((SELECT jsonb_agg(jsonb_build_object(
                          'region_id', r.id, 'region_name', r.name,
                          'can_map', ura.can_map) ORDER BY r.name)
                   FROM user_region_access ura
                   JOIN regions r ON r.id = ura.region_id
                  WHERE ura.app_user_id = u.id), '[]'::jsonb) AS region_grants
  FROM app_users u;

GRANT SELECT ON v_admin_users TO authenticated;

CREATE VIEW v_admin_audit_log WITH (security_invoker = true) AS
SELECT a.id, a.action, a.entity_table, a.entity_id, a.actor_id,
       coalesce(act.full_name, a.actor_label) AS actor_label,
       a.summary, a.before_data, a.after_data, a.occurred_at
  FROM audit_logs a
  LEFT JOIN app_users act ON act.id = a.actor_id;

GRANT SELECT ON v_admin_audit_log TO authenticated;

/**
 * Data-quality queues, counted from the DATA — never from a hard-coded figure.
 * Each row is one actionable queue; a zero is a real zero.
 */
CREATE VIEW v_admin_data_quality WITH (security_invoker = true) AS
SELECT 'installed_relief_valve'::text AS asset, 'needs_station_mapping'::text AS queue,
       count(*)::bigint AS open_count
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_station_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'needs_unit_mapping', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_unit_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'needs_equipment_mapping', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'needs_equipment_mapping'
UNION ALL
SELECT 'installed_relief_valve', 'conflict', count(*)
  FROM installed_relief_valves WHERE archived_at IS NULL AND mapping_status = 'conflict'
UNION ALL
SELECT 'storage_vessel', 'unresolved', count(*)
  FROM storage_vessels WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'recovery_tank', 'unresolved', count(*)
  FROM recovery_tanks WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'gas_detector', 'unresolved', count(*)
  FROM gas_detectors WHERE archived_at IS NULL AND mapping_status <> 'resolved'
UNION ALL
SELECT 'hose', 'unresolved', count(*)
  FROM hoses WHERE archived_at IS NULL AND mapping_status <> 'resolved';

COMMENT ON VIEW v_admin_data_quality IS
  'Open data-quality queues, counted from live data. No count is hard-coded: the ~1,104 staged blocker figure from project history is a PIPELINE fact and must never be typed into a UI.';

GRANT SELECT ON v_admin_data_quality TO authenticated;

/**
 * The SRV mapping queue, with the source evidence a human needs to decide.
 * Candidate suggestion is deliberately absent: a candidate is not a mapping,
 * and nothing here may become truth without an explicit human confirmation.
 */
CREATE VIEW v_admin_srv_mapping_queue WITH (security_invoker = true) AS
SELECT v.id, v.mapping_status, v.updated_at,
       v.region_id, r.name AS region_name,
       v.station_id, s.station_name,
       v.unit_id, u.unit_name,
       -- Source evidence, RAW alongside normalized, so the human decides from
       -- what the workbook actually said (data principle #6).
       v.source_station_name_raw, v.source_region_raw,
       v.serial_number, v.serial_number_raw, v.serial_status,
       v.part_number, v.manufacturer, v.manufacturer_raw, v.set_pressure_raw,
       v.expected_parent_kind,
       v.source_file, v.source_sheet, v.source_row
  FROM installed_relief_valves v
  LEFT JOIN regions  r ON r.id = v.region_id
  LEFT JOIN stations s ON s.id = v.station_id
  LEFT JOIN units    u ON u.id = v.unit_id
 WHERE v.archived_at IS NULL
   AND v.mapping_status <> 'resolved';

GRANT SELECT ON v_admin_srv_mapping_queue TO authenticated;
