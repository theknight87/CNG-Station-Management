-- 0020_rls_policies.sql
-- Row Level Security policies. Every policy is scoped `TO authenticated`, so
-- `anon` matches no policy anywhere and — having no grants either — is denied
-- twice over.
--
-- UPDATE policies always carry BOTH `USING` and `WITH CHECK`. `USING` decides
-- which rows may be touched; `WITH CHECK` decides what they may become. Without
-- the second half an engineer could take a row they legitimately own and move it
-- into a region they do not — the classic cross-region escape. Both halves use
-- the same predicate, so a row can never be edited out of the caller's scope.
--
-- DELETE has no policy on any table except `user_region_access` and the two
-- personal notification tables; combined with the absent DELETE grants, hard
-- deletion is impossible through the API for every role.

-- ---------------------------------------------------------------------------
-- Reference: regions. You see the regions you are authorized for; admin and
-- manager are company-wide.
-- ---------------------------------------------------------------------------

CREATE POLICY regions_select ON regions FOR SELECT TO authenticated
  USING (cng_can_read_region(id));

-- ---------------------------------------------------------------------------
-- Hierarchy: stations, units
--
-- `units.region_id` is pinned to its station's region by the composite FK
-- `units_station_region_fk`, so checking region_id is equivalent to checking the
-- station's region and needs no join.
-- ---------------------------------------------------------------------------

CREATE POLICY stations_select ON stations FOR SELECT TO authenticated
  USING (cng_can_read_region(region_id));
CREATE POLICY stations_insert ON stations FOR INSERT TO authenticated
  WITH CHECK (cng_can_write_region(region_id));
CREATE POLICY stations_update ON stations FOR UPDATE TO authenticated
  USING (cng_can_write_region(region_id))
  WITH CHECK (cng_can_write_region(region_id));

CREATE POLICY units_select ON units FOR SELECT TO authenticated
  USING (cng_can_read_region(region_id));
CREATE POLICY units_insert ON units FOR INSERT TO authenticated
  WITH CHECK (cng_can_write_region(region_id));
CREATE POLICY units_update ON units FOR UPDATE TO authenticated
  USING (cng_can_write_region(region_id))
  WITH CHECK (cng_can_write_region(region_id));

-- ---------------------------------------------------------------------------
-- Equipment. Identical shape on every table: region_id is pinned to the
-- station's region by each table's `*_station_region_fk` composite FK, so it is
-- a trustworthy authorization key rather than a denormalized copy that could
-- drift.
-- ---------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'compressors', 'recovery_tanks', 'storage_vessels', 'dispensers',
    'gas_detectors', 'gas_detector_presence', 'hoses'
  ]
  LOOP
    EXECUTE format($f$
      CREATE POLICY %1$s_select ON %1$I FOR SELECT TO authenticated
        USING (cng_can_read_region(region_id));
      CREATE POLICY %1$s_insert ON %1$I FOR INSERT TO authenticated
        WITH CHECK (cng_can_write_region(region_id));
      CREATE POLICY %1$s_update ON %1$I FOR UPDATE TO authenticated
        USING (cng_can_write_region(region_id))
        WITH CHECK (cng_can_write_region(region_id));
    $f$, t);
  END LOOP;
END;
$$;

-- ---------------------------------------------------------------------------
-- Installed relief valves — the sensitive case.
--
-- When station_id IS NOT NULL the row's region is pinned to that station by
-- `irv_station_region_fk`, so ordinary region scoping applies.
--
-- When station_id IS NULL the record is `needs_station_mapping`: its region_id
-- came from the source Area column and `source_station_name_raw` is raw source
-- text. Neither is a confirmed authorization boundary, so region-scoped roles
-- get nothing — admin and manager only.
--
-- Because an engineer cannot SELECT such a row, the UPDATE `USING` clause can
-- never pass for them, so mapping cannot be used to claim an unresolved SRV into
-- their own region. The matching `WITH CHECK` additionally prevents anyone from
-- pushing a mapped SRV back into the unmapped state unless they are admin or
-- manager.
-- ---------------------------------------------------------------------------

CREATE POLICY irv_select ON installed_relief_valves FOR SELECT TO authenticated
  USING (
    CASE WHEN station_id IS NOT NULL
         THEN cng_can_read_region(region_id)
         ELSE cng_can_access_unmapped_srv()
    END
  );

CREATE POLICY irv_insert ON installed_relief_valves FOR INSERT TO authenticated
  WITH CHECK (
    CASE WHEN station_id IS NOT NULL
         THEN cng_can_write_region(region_id)
         ELSE cng_can_access_unmapped_srv()
    END
  );

CREATE POLICY irv_update ON installed_relief_valves FOR UPDATE TO authenticated
  USING (
    CASE WHEN station_id IS NOT NULL
         THEN cng_can_map_region(region_id)
         ELSE cng_can_access_unmapped_srv()
    END
  )
  WITH CHECK (
    CASE WHEN station_id IS NOT NULL
         THEN cng_can_map_region(region_id)
         ELSE cng_can_access_unmapped_srv()
    END
  );

-- ---------------------------------------------------------------------------
-- Warehouse relief valves — global stock, deliberately NOT station-scoped.
-- Applying region logic here would be wrong: warehouse inventory belongs to the
-- company, not to a station.
-- ---------------------------------------------------------------------------

CREATE POLICY wrv_select ON warehouse_relief_valves FOR SELECT TO authenticated
  USING (cng_current_role() IS NOT NULL);           -- any activated user
CREATE POLICY wrv_insert ON warehouse_relief_valves FOR INSERT TO authenticated
  WITH CHECK (cng_is_admin());
CREATE POLICY wrv_update ON warehouse_relief_valves FOR UPDATE TO authenticated
  USING (cng_is_manager_or_admin())
  WITH CHECK (cng_is_manager_or_admin());

-- ---------------------------------------------------------------------------
-- Alias tables.
--
-- Creating a PROPOSAL is ordinary mapping work. CONFIRMING an alias establishes
-- canonical identity for every future import, so it is restricted to
-- admin/manager even inside an engineer's own region.
-- ---------------------------------------------------------------------------

CREATE POLICY station_aliases_select ON station_aliases FOR SELECT TO authenticated
  USING (cng_can_read_region(region_id));
CREATE POLICY station_aliases_insert ON station_aliases FOR INSERT TO authenticated
  WITH CHECK (
    cng_can_map_region(region_id)
    AND (alias_status <> 'confirmed' OR cng_is_manager_or_admin())
  );
CREATE POLICY station_aliases_update ON station_aliases FOR UPDATE TO authenticated
  USING (cng_can_map_region(region_id))
  WITH CHECK (
    cng_can_map_region(region_id)
    AND (alias_status <> 'confirmed' OR cng_is_manager_or_admin())
  );

CREATE POLICY unit_aliases_select ON unit_aliases FOR SELECT TO authenticated
  USING (cng_can_read_region(region_id));
CREATE POLICY unit_aliases_insert ON unit_aliases FOR INSERT TO authenticated
  WITH CHECK (
    cng_can_map_region(region_id)
    AND (alias_status <> 'confirmed' OR cng_is_manager_or_admin())
  );
CREATE POLICY unit_aliases_update ON unit_aliases FOR UPDATE TO authenticated
  USING (cng_can_map_region(region_id))
  WITH CHECK (
    cng_can_map_region(region_id)
    AND (alias_status <> 'confirmed' OR cng_is_manager_or_admin())
  );

-- ---------------------------------------------------------------------------
-- Owner-confirmed rules: readable by any activated user, writable by nobody
-- through the API (no INSERT/UPDATE/DELETE grant exists).
-- ---------------------------------------------------------------------------

CREATE POLICY ocsa_select ON owner_confirmed_station_aliases FOR SELECT TO authenticated
  USING (cng_current_role() IS NOT NULL);
CREATE POLICY ocpn_select ON owner_confirmed_part_numbers FOR SELECT TO authenticated
  USING (cng_current_role() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- app_users
--
-- Self-read deliberately does NOT go through cng_current_role(): a user awaiting
-- activation must still be able to read their own row so the UI can show
-- "pending approval" rather than an unexplained empty screen.
--
-- UPDATE is admin-only, and the grant restricts it to (role, is_active,
-- full_name, email). `clerk_user_id` carries no UPDATE grant at all, so identity
-- can never be re-pointed. There is no INSERT or DELETE grant or policy:
-- accounts are created only by the server-side Clerk webhook, which is why a
-- user cannot forge a row claiming someone else's Clerk id.
-- ---------------------------------------------------------------------------

CREATE POLICY app_users_select ON app_users FOR SELECT TO authenticated
  USING (clerk_user_id = cng_jwt_sub() OR cng_is_admin());

CREATE POLICY app_users_update ON app_users FOR UPDATE TO authenticated
  USING (cng_is_admin())
  WITH CHECK (cng_is_admin());

-- ---------------------------------------------------------------------------
-- user_region_access
--
-- A user may see their own grants so the UI can show which regions they hold.
-- Only an admin may create, change or revoke a grant — this is the single
-- mechanism by which region authorization changes, and it is why a user cannot
-- add themselves to another region.
-- ---------------------------------------------------------------------------

CREATE POLICY ura_select ON user_region_access FOR SELECT TO authenticated
  USING (app_user_id = cng_current_app_user_id() OR cng_is_admin());
CREATE POLICY ura_insert ON user_region_access FOR INSERT TO authenticated
  WITH CHECK (cng_is_admin());
CREATE POLICY ura_update ON user_region_access FOR UPDATE TO authenticated
  USING (cng_is_admin()) WITH CHECK (cng_is_admin());
CREATE POLICY ura_delete ON user_region_access FOR DELETE TO authenticated
  USING (cng_is_admin());

-- ---------------------------------------------------------------------------
-- Import / Data Quality — admin and manager only (prompt §22).
-- Engineers and viewers get no import administration at all.
-- ---------------------------------------------------------------------------

CREATE POLICY import_batches_select ON import_batches FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());

CREATE POLICY import_issues_select ON import_issues FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin());
CREATE POLICY import_issues_update ON import_issues FOR UPDATE TO authenticated
  USING (cng_is_manager_or_admin())
  WITH CHECK (cng_is_manager_or_admin());

-- ---------------------------------------------------------------------------
-- Alerts
--
-- Authorization is derived from the alert's STATION, not from its region_id
-- column: unlike the asset tables, `alerts` has no composite FK pinning region
-- to station, so the station is the trustworthy key. An alert with no station is
-- an unresolved-SRV alert and follows the same admin/manager rule.
-- ---------------------------------------------------------------------------

CREATE POLICY alerts_select ON alerts FOR SELECT TO authenticated
  USING (
    CASE WHEN station_id IS NOT NULL
         THEN EXISTS (SELECT 1 FROM stations s
                       WHERE s.id = alerts.station_id AND cng_can_read_region(s.region_id))
         ELSE cng_can_access_unmapped_srv()
    END
  );

CREATE POLICY alerts_update ON alerts FOR UPDATE TO authenticated
  USING (
    CASE WHEN station_id IS NOT NULL
         THEN EXISTS (SELECT 1 FROM stations s
                       WHERE s.id = alerts.station_id AND cng_can_write_region(s.region_id))
         ELSE cng_can_access_unmapped_srv()
    END
  )
  WITH CHECK (
    CASE WHEN station_id IS NOT NULL
         THEN EXISTS (SELECT 1 FROM stations s
                       WHERE s.id = alerts.station_id AND cng_can_write_region(s.region_id))
         ELSE cng_can_access_unmapped_srv()
    END
  );

-- ---------------------------------------------------------------------------
-- Personal notification data — strictly own-row.
-- A user cannot read another user's push endpoint, replace it, or change
-- another user's preferences.
-- ---------------------------------------------------------------------------

CREATE POLICY notif_pref_all ON notification_preferences FOR ALL TO authenticated
  USING (app_user_id = cng_current_app_user_id())
  WITH CHECK (app_user_id = cng_current_app_user_id());

CREATE POLICY push_subs_all ON push_subscriptions FOR ALL TO authenticated
  USING (app_user_id = cng_current_app_user_id())
  WITH CHECK (app_user_id = cng_current_app_user_id());

CREATE POLICY notif_deliveries_select ON notification_deliveries FOR SELECT TO authenticated
  USING (app_user_id = cng_current_app_user_id());

-- ---------------------------------------------------------------------------
-- Audit — append-only, and never forgeable.
--
-- INSERT requires the actor column to equal the caller's own app_user id, so an
-- engineer cannot attribute a mapping change to somebody else. There is no
-- UPDATE or DELETE grant or policy, so history cannot be altered or erased by
-- any application role.
-- ---------------------------------------------------------------------------

CREATE POLICY ama_select ON asset_mapping_audit FOR SELECT TO authenticated
  USING (cng_is_manager_or_admin() OR changed_by = cng_current_app_user_id());
CREATE POLICY ama_insert ON asset_mapping_audit FOR INSERT TO authenticated
  WITH CHECK (changed_by = cng_current_app_user_id());

CREATE POLICY audit_logs_select ON audit_logs FOR SELECT TO authenticated
  USING (cng_is_admin() OR actor_id = cng_current_app_user_id());
CREATE POLICY audit_logs_insert ON audit_logs FOR INSERT TO authenticated
  WITH CHECK (actor_id = cng_current_app_user_id());
