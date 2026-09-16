import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { AppRole } from '@/types/domain'

/**
 * User administration.
 *
 * EVERY MUTATION HERE IS AN RPC, never a table write. Migration 0038 revoked the
 * `authenticated` grants on `app_users (role, is_active)` and on
 * `user_region_access` entirely, so an unaudited privilege change is not
 * expressible from a browser — not even by an admin, and not even by a hand
 * written request that ignores this file. What the screen shows is UX; the
 * refusal is the database's (CLAUDE.md §10).
 *
 * STALE WRITES. Each mutation carries the row version it was decided against.
 * Two administrators editing the same user in different tabs is not exotic, and
 * a silent last-write-wins on a ROLE is a privilege bug.
 */

export interface RegionGrant {
  region_id: string
  region_name: string
  can_map: boolean
}

export interface AdminUserRow {
  id: string
  clerk_user_id: string
  email: string | null
  full_name: string | null
  role: AppRole
  is_active: boolean
  created_at: string
  updated_at: string
  region_grants: RegionGrant[]
}

export interface RegionOption {
  id: string
  name: string
}

export interface AdminUsersState {
  users: AdminUserRow[] | null
  regions: RegionOption[]
  /** A failure to READ: the screen cannot be shown. */
  loadError: string | null
  /** A failure to WRITE: the screen is fine, one change did not stick. */
  actionError: string | null
  busy: boolean
  setRole: (user: AdminUserRow, role: AppRole) => Promise<void>
  setActive: (user: AdminUserRow, isActive: boolean) => Promise<void>
  grantRegion: (user: AdminUserRow, regionId: string, canMap: boolean) => Promise<void>
  revokeRegion: (user: AdminUserRow, regionId: string) => Promise<void>
  reload: () => void
}

/**
 * Turns a database refusal into something an administrator can act on.
 *
 * The rules themselves live in SQL; this only makes the SQLSTATE legible. It
 * never decides anything — a message is not an authorization outcome.
 */
export function describeAdminError(message: string): string {
  if (/stale_write/i.test(message)) {
    return 'This user changed since the screen loaded, so the change was refused rather than silently overwriting the newer value. Reload and decide again.'
  }
  if (/last active administrator/i.test(message)) {
    return 'Refused: this would leave the system with no active administrator.'
  }
  if (/own role|own account|themselves/i.test(message)) {
    return 'Refused: an administrator cannot change their own role or deactivate their own account. Ask another administrator.'
  }
  if (/administrator privilege|42501|permission denied/i.test(message)) {
    return 'Refused by the database: this action requires an active administrator.'
  }
  return message
}

export function useAdminUsers(): AdminUsersState {
  const supabase = useSupabaseClient()
  const [users, setUsers] = useState<AdminUserRow[] | null>(null)
  const [regions, setRegions] = useState<RegionOption[]>([])
  const [loadError, setLoadError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      const [u, r] = await Promise.all([
        supabase.from('v_admin_users').select('*').order('full_name', { nullsFirst: false }),
        supabase.from('regions').select('id, name').order('name'),
      ])
      if (cancelled) return
      if (u.error) {
        setLoadError(u.error.message)
        return
      }
      setLoadError(null)
      setUsers((u.data ?? []) as AdminUserRow[])
      // A failed Region read is not a failed screen: the list is only needed to
      // OFFER a grant, and the grants already held are carried on each user row.
      setRegions(r.error ? [] : ((r.data ?? []) as RegionOption[]))
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  const call = useCallback(
    async (fn: string, args: Record<string, unknown>) => {
      if (!supabase) return
      setBusy(true)
      setActionError(null)
      const { error } = await supabase.rpc(fn, args)
      setBusy(false)
      if (error) {
        setActionError(describeAdminError(error.message))
        return
      }
      setNonce((n) => n + 1)
    },
    [supabase],
  )

  return {
    users,
    regions,
    loadError,
    actionError,
    busy,
    reload: () => setNonce((n) => n + 1),
    setRole: (user, role) =>
      call('cng_admin_set_user_role', {
        p_app_user_id: user.id,
        p_role: role,
        p_expected_updated_at: user.updated_at,
      }),
    setActive: (user, isActive) =>
      call('cng_admin_set_user_active', {
        p_app_user_id: user.id,
        p_is_active: isActive,
        p_expected_updated_at: user.updated_at,
      }),
    grantRegion: (user, regionId, canMap) =>
      call('cng_admin_grant_region', {
        p_app_user_id: user.id,
        p_region_id: regionId,
        p_can_map: canMap,
      }),
    revokeRegion: (user, regionId) =>
      call('cng_admin_revoke_region', { p_app_user_id: user.id, p_region_id: regionId }),
  }
}
