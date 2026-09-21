import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { DetailGrid, DetailItem, RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { useAppUser } from '@/hooks/useAppUser'
import type { AppRole } from '@/types/domain'
import { useAdminUsers, type AdminUserRow } from '../useAdminUsers'

const ROLES: AppRole[] = ['admin', 'manager', 'engineer', 'viewer']

/**
 * Users, roles and Region access.
 *
 * Every control here is a REQUEST, not a decision: the database refuses a
 * self-demotion, the removal of the last active administrator, and any change
 * made against a row version that has since moved. This screen's job is to make
 * the refusal legible, never to pre-empt it — a rule duplicated in the client
 * that drifts from SQL is worse than no rule at all.
 */
export function AdminUsersSection() {
  const state = useAdminUsers()
  const me = useAppUser()
  const myId = me.status === 'active' ? me.user.id : null
  const [grantFor, setGrantFor] = useState<string | null>(null)

  if (state.loadError) {
    return <ErrorState title="The user list could not be loaded" message={state.loadError} />
  }
  if (!state.users) return <LoadingState label="Loading users" />

  return (
    <section className="space-y-3" aria-labelledby="admin-users-heading">
      <SectionHeader
        id="admin-users-heading"
        title="Users and access"
        description="Roles and Region authorization. Every change is audited to the acting administrator, and the database — not this screen — decides whether it is allowed."
      />

      {state.actionError ? (
        <ErrorState title="That change was refused" message={state.actionError} />
      ) : null}

      {state.users.length === 0 ? (
        <EmptyState
          title="No user accounts"
          description="Accounts appear here after someone signs in. A new account is inactive and holds the least-privileged role until an administrator activates it."
        />
      ) : (
        <TableScroll label="Application users">
          <DataTable className="responsive-records compact-records" caption="Application users, with role, activation state and Region access">
            <TableHead>
              <TableRow>
                <TableHeader>Name</TableHeader>
                <TableHeader>Email</TableHeader>
                <TableHeader>Role</TableHeader>
                <TableHeader>Account</TableHeader>
                <TableHeader>Region access</TableHeader>
                <TableHeader>Actions</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {state.users.map((user) => (
                <UserRow
                  key={user.id}
                  user={user}
                  isSelf={user.id === myId}
                  busy={state.busy}
                  regions={state.regions}
                  granting={grantFor === user.id}
                  onToggleGrant={() => setGrantFor(grantFor === user.id ? null : user.id)}
                  onRole={(role) => void state.setRole(user, role)}
                  onActive={(active) => void state.setActive(user, active)}
                  onRemove={() => void state.removeUser(user)}
                  onGrant={(regionId, canMap) => void state.grantRegion(user, regionId, canMap)}
                  onRevoke={(regionId) => void state.revokeRegion(user, regionId)}
                />
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}

function UserRow({
  user, isSelf, busy, regions, granting, onToggleGrant, onRole, onActive, onRemove, onGrant, onRevoke,
}: {
  user: AdminUserRow
  isSelf: boolean
  busy: boolean
  regions: { id: string; name: string }[]
  granting: boolean
  onToggleGrant: () => void
  onRole: (role: AppRole) => void
  onActive: (active: boolean) => void
  onRemove: () => void
  onGrant: (regionId: string, canMap: boolean) => void
  onRevoke: (regionId: string) => void
}) {
  const [region, setRegion] = useState('')
  const [canMap, setCanMap] = useState(true)
  const [manageOpen, setManageOpen] = useState(false)
  const [confirmRemove, setConfirmRemove] = useState(false)
  const who = user.full_name ?? user.email ?? user.auth_user_id ?? user.clerk_user_id ?? 'user'

  return (
    <TableRow>
      <TableCell>
        {user.full_name ?? <NullValue />}
        {isSelf ? <span className="ml-1 text-xs text-muted-foreground">(you)</span> : null}
      </TableCell>
      <TableCell>{user.email ?? <NullValue />}</TableCell>
      <TableCell>
        <span className="capitalize">{user.role}</span>
        <label className="sr-only" htmlFor={`role-${user.id}`}>Role for {who}</label>
        <select id={`role-${user.id}`} className="sr-only" value={user.role} disabled={busy} onChange={(e) => onRole(e.target.value as AppRole)}>
          {ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
      </TableCell>
      <TableCell>
        <StatusBadge
          kind={user.is_active ? 'ok' : 'unmapped'}
          label={user.is_active ? 'Active' : 'Inactive'}
          description={
            user.is_active
              ? 'The account may sign in and act within its role'
              : 'The account exists but grants nothing until an administrator activates it'
          }
        />
      </TableCell>
      <TableCell>
        {user.region_grants.length === 0 ? (
          <span className="text-xs text-muted-foreground">No Regions</span>
        ) : (
          <ul className="flex flex-wrap gap-1">
            {user.region_grants.map((g) => (
              <li key={g.region_id} className="inline-flex items-center gap-1 rounded border px-1 text-xs">
                <span>{g.region_name}</span>
                <span className="text-muted-foreground">{g.can_map ? 'may map' : 'read'}</span>
                <button
                  type="button"
                  className="text-muted-foreground underline"
                  disabled={busy}
                  aria-label={`Revoke ${g.region_name} from ${who}`}
                  onClick={() => onRevoke(g.region_id)}
                >
                  Revoke
                </button>
              </li>
            ))}
          </ul>
        )}
      </TableCell>
      <TableCell>
        <Button type="button" variant="outline" size="sm" className="whitespace-nowrap" onClick={() => setManageOpen(true)}>
          Manage
        </Button>
        <button type="button" className="sr-only" disabled={busy} aria-label={`${user.is_active ? 'Deactivate' : 'Activate'} ${who}`} onClick={() => onActive(!user.is_active)}>{user.is_active ? 'Deactivate' : 'Activate'}</button>
        <RecordDetailsDialog
          open={manageOpen}
          title={who}
          description="Account role, status and Region access"
          onClose={() => { setManageOpen(false); setConfirmRemove(false); if (granting) onToggleGrant() }}
          actions={<>
            {!confirmRemove ? <>
              <Button type="button" variant="outline" disabled={busy || isSelf} onClick={() => onActive(!user.is_active)}>{user.is_active ? 'Deactivate' : 'Activate'}</Button>
              <Button type="button" variant="destructive" disabled={busy || isSelf} onClick={() => setConfirmRemove(true)}>Remove user</Button>
            </> : <>
              <span className="mr-auto text-sm text-destructive">Remove this account and all Region grants?</span>
              <Button type="button" variant="outline" onClick={() => setConfirmRemove(false)}>Cancel</Button>
              <Button type="button" variant="destructive" disabled={busy} onClick={() => { onRemove(); setManageOpen(false) }}>Confirm removal</Button>
            </>}
            <Button type="button" onClick={() => setManageOpen(false)}>Done</Button>
          </>}
        >
          <div className="space-y-5">
            <DetailGrid>
              <DetailItem label="Email">{user.email ?? <NullValue />}</DetailItem>
              <DetailItem label="Account"><StatusBadge kind={user.is_active ? 'ok' : 'unmapped'} label={user.is_active ? 'Active' : 'Inactive'} description="Application access state" /></DetailItem>
              <DetailItem label="Created"><span className="whitespace-nowrap tabular">{new Date(user.created_at).toLocaleDateString('en-GB')}</span></DetailItem>
            </DetailGrid>
            <div>
              <label className="mb-1 block text-sm font-medium" htmlFor={`role-dialog-${user.id}`}>Role</label>
              <select id={`role-dialog-${user.id}`} className="h-9 rounded border bg-background px-2 text-sm" value={user.role} disabled={busy || isSelf} onChange={(e) => onRole(e.target.value as AppRole)}>
                {ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
              </select>
            </div>
            <div className="space-y-2">
              <h3 className="text-sm font-semibold">Region access</h3>
              {user.region_grants.length === 0 ? <p className="text-sm text-muted-foreground">No Regions granted.</p> : (
                <ul className="divide-y rounded border">
                  {user.region_grants.map((g) => <li key={g.region_id} className="flex items-center justify-between gap-3 px-3 py-2 text-sm"><span>{g.region_name} <span className="text-muted-foreground">· {g.can_map ? 'may map' : 'read only'}</span></span><Button type="button" variant="ghost" size="sm" disabled={busy} onClick={() => onRevoke(g.region_id)}>Revoke</Button></li>)}
                </ul>
              )}
              <Button type="button" variant="outline" size="sm" onClick={onToggleGrant}>{granting ? 'Cancel grant' : 'Grant Region'}</Button>
            </div>
            {granting ? (
              <div className="flex flex-wrap items-center gap-2 rounded border bg-muted/30 p-3">
            <label className="sr-only" htmlFor={`grant-${user.id}`}>Region to grant {who}</label>
            <select
              id={`grant-${user.id}`}
              className="h-7 rounded border bg-background px-1 text-xs"
              value={region}
              onChange={(e) => setRegion(e.target.value)}
            >
              <option value="">Select a Region</option>
              {regions.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
            </select>
            <label className="flex items-center gap-1 text-xs">
              <input type="checkbox" checked={canMap} onChange={(e) => setCanMap(e.target.checked)} />
              May resolve mappings
            </label>
            <Button
              type="button" size="sm" disabled={busy || region === ''}
              onClick={() => { onGrant(region, canMap); setRegion('') }}
            >
              Grant
            </Button>
              </div>
            ) : null}
          </div>
        </RecordDetailsDialog>
      </TableCell>
    </TableRow>
  )
}

