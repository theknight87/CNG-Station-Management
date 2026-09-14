-- 0003_users_and_access.sql
-- Identity mirror and region-level authorization.
--
-- Authorization facts live in the database, NOT only in Clerk metadata: RLS must
-- evaluate them in SQL, and a client must not be able to influence them by
-- editing a token claim (docs/architecture.md §2).

CREATE TABLE app_users (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  clerk_user_id  text NOT NULL UNIQUE,     -- Clerk subject; TEXT, never numeric
  email          text NULL,
  full_name      text NULL,
  role           app_role NOT NULL DEFAULT 'viewer',
  is_active      boolean NOT NULL DEFAULT true,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE app_users IS
  'Application identity mirrored from Clerk. Role and region scope live here so RLS can evaluate them; Clerk metadata is never the authorization source.';

-- Region-level authorization. Admin and manager map anywhere (decision D8), so
-- their rights do not depend on rows here; engineers are confined to the regions
-- listed for them, enforced in RLS in the auth phase.
CREATE TABLE user_region_access (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  app_user_id  uuid NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  region_id    uuid NOT NULL REFERENCES regions(id) ON DELETE RESTRICT,
  can_map      boolean NOT NULL DEFAULT true,   -- may resolve mappings in this region
  granted_by   uuid NULL REFERENCES app_users(id) ON DELETE SET NULL,
  granted_at   timestamptz NOT NULL DEFAULT now(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT user_region_access_uq UNIQUE (app_user_id, region_id)
);

COMMENT ON TABLE user_region_access IS
  'Region grants. ON DELETE CASCADE from app_users is deliberate: a grant has no meaning without its user, and the act is preserved in audit_logs.';

CREATE INDEX user_region_access_user_idx   ON user_region_access (app_user_id);
CREATE INDEX user_region_access_region_idx ON user_region_access (region_id);

-- Resolve the current request's app_user via the Clerk subject claim.
-- STABLE and plain (not SECURITY DEFINER): it reads only app_users, which RLS
-- will expose to the authenticated user anyway.
CREATE OR REPLACE FUNCTION cng_current_app_user_id()
RETURNS uuid
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public
AS $$
  SELECT u.id
  FROM app_users u
  WHERE u.clerk_user_id = nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')
    AND u.is_active;
$$;

COMMENT ON FUNCTION cng_current_app_user_id() IS
  'Current app_users.id from the Clerk `sub` claim, or NULL when unauthenticated.';

-- Deferred FKs from 0002 now that app_users exists.
ALTER TABLE stations
  ADD CONSTRAINT stations_archived_by_fk FOREIGN KEY (archived_by)
    REFERENCES app_users(id) ON DELETE SET NULL;
ALTER TABLE units
  ADD CONSTRAINT units_archived_by_fk FOREIGN KEY (archived_by)
    REFERENCES app_users(id) ON DELETE SET NULL;
ALTER TABLE station_aliases
  ADD CONSTRAINT station_aliases_confirmed_by_fk FOREIGN KEY (confirmed_by)
    REFERENCES app_users(id) ON DELETE RESTRICT;
ALTER TABLE unit_aliases
  ADD CONSTRAINT unit_aliases_confirmed_by_fk FOREIGN KEY (confirmed_by)
    REFERENCES app_users(id) ON DELETE RESTRICT;

CREATE TRIGGER app_users_set_updated_at BEFORE UPDATE ON app_users
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
CREATE TRIGGER user_region_access_set_updated_at BEFORE UPDATE ON user_region_access
  FOR EACH ROW EXECUTE FUNCTION cng_set_updated_at();
