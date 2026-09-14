-- 0021_authz_indexes.sql
-- Indexes that exist specifically because an RLS policy depends on them.
--
-- Every policy call resolves the caller's identity and region grants, so these
-- lookups run on essentially every query. Each index below is justified by a
-- concrete policy path; no speculative indexes are added.

-- cng_jwt_sub() -> app_users.clerk_user_id, on every helper call.
-- app_users.clerk_user_id is already UNIQUE, which provides this index. Adding a
-- second one would be redundant, so none is created here — noted so the omission
-- reads as deliberate.

-- cng_has_region_grant(): joins user_region_access to app_users and filters on
-- region. The existing user_region_access_user_idx covers the app_user_id side;
-- this composite covers the exact (user, region) probe the function performs and
-- lets it be answered from the index alone.
CREATE INDEX IF NOT EXISTS user_region_access_user_region_idx
  ON user_region_access (app_user_id, region_id, can_map);

-- alerts policies resolve the alert's station to its region.
-- stations.id is the primary key; stations_id_region_uq already indexes
-- (id, region_id), so the lookup is index-only. No new index required.

-- Partial indexes on the asset tables are scoped `WHERE archived_at IS NULL`,
-- which suits list queries but not authorization probes on a specific row by id.
-- Those probes hit the primary key, so they need nothing extra.

ANALYZE user_region_access;
ANALYZE app_users;
