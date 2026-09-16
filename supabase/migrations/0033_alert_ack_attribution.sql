-- ---------------------------------------------------------------------------
-- 0033 — Close a forgeable-acknowledgement hole (Prompt 15).
--
-- WHAT WAS FOUND, and proved by attack rather than by reading.
--
-- Migration 0019 issued a COLUMN-level grant:
--
--   GRANT UPDATE (state, acknowledged_by, acknowledged_at, resolved_at)
--     ON alerts TO authenticated;
--
-- It is invisible in `information_schema.role_table_grants`, which lists
-- table-level grants only — the table view showed a reassuring "SELECT" and the
-- column grant sat underneath it. `role_column_grants` shows the truth.
--
-- The consequence: any signed-in engineer could UPDATE an alert in their own
-- region and set `acknowledged_by` to ANY user and `acknowledged_at` to ANY
-- timestamp. The RLS policy checks the alert's region; it does not and cannot
-- check whether the actor is claiming to be someone else. Reproduced end to
-- end: an engineer attributed an acknowledgement to an admin, backdated to
-- 2020-01-01, and it was accepted.
--
-- That breaks the durable rule that an audit actor cannot be forged
-- (CLAUDE.md §10) and the requirement that acknowledgement carry a
-- server-derived actor and timestamp.
--
-- THE FIX. Revoke the four column privileges. `cng_acknowledge_alert`
-- (migration 0031) is SECURITY DEFINER, takes no identity parameter, re-checks
-- region authorization itself, and stamps `cng_current_app_user_id()` and
-- `now()` — so with the direct path closed it becomes the ONLY way an alert can
-- become acknowledged, and attribution stops being client-supplied.
--
-- WHY THIS IS NOT A DESTRUCTIVE MIGRATION. It removes a privilege, not data.
-- No row is altered, no column dropped. Nothing in this repository ever used
-- the direct UPDATE path: the frontend acknowledges through the function, which
-- is unaffected. Migration 0024 set the precedent for revoking a privilege that
-- was broader than anything the application needed.
--
-- `resolved_at` and `state` go with them deliberately. A client that could set
-- `state = 'resolved'` or stamp `resolved_at` could retire an alert without any
-- record of who did it — the same forgery in a different column. Both belong to
-- server-side transitions, and a future resolve action should arrive as its own
-- audited function rather than as a raw column write.
-- ---------------------------------------------------------------------------

REVOKE UPDATE (state, acknowledged_by, acknowledged_at, resolved_at)
  ON alerts FROM authenticated;

-- Belt and braces: revoke any table-level UPDATE too, so a future default
-- privilege or a stray GRANT cannot quietly reopen the path.
REVOKE UPDATE ON alerts FROM authenticated;

COMMENT ON COLUMN alerts.acknowledged_by IS
  'Set ONLY by cng_acknowledge_alert(), from cng_current_app_user_id(). No client holds UPDATE on this column (migration 0033), so the actor cannot be forged or reattributed.';
COMMENT ON COLUMN alerts.acknowledged_at IS
  'Set ONLY by cng_acknowledge_alert(), from now(). No client holds UPDATE on this column (migration 0033), so the timestamp cannot be backdated.';
