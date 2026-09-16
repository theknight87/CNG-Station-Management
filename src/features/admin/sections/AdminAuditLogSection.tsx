import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar, SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { useAdminAuditLog } from '../useAdminAuditLog'

const ACTIONS = [
  { value: '', label: 'Every action' },
  { value: 'user_role_changed', label: 'Role changed' },
  { value: 'user_activation_changed', label: 'Activation changed' },
  { value: 'region_access_changed', label: 'Region access changed' },
  { value: 'alert_rule_changed', label: 'Alert rule changed' },
  { value: 'mapping_changed', label: 'Mapping resolved' },
]

/**
 * Audit history.
 *
 * READ ONLY — and not by convention. No browser role holds UPDATE or DELETE on
 * `audit_logs`, so this history cannot be rewritten from the application at all,
 * by anyone. The actor on each row was derived server-side from the verified
 * Clerk subject at write time; it was never a value the client supplied.
 */
export function AdminAuditLogSection() {
  const [action, setAction] = useState('')
  const { entries, loadError } = useAdminAuditLog(action)

  return (
    <section className="space-y-3" aria-labelledby="admin-audit-heading">
      <SectionHeader
        id="admin-audit-heading"
        title="Audit log"
        description="Who changed what, and when. Append-only: this record cannot be edited or deleted from the application."
      />

      <DataToolbar label="Filter the audit log">
        <label className="text-xs text-muted-foreground" htmlFor="audit-action">Action</label>
        <select
          id="audit-action"
          className="h-7 rounded border bg-background px-1 text-xs"
          value={action}
          onChange={(e) => setAction(e.target.value)}
        >
          {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
        </select>
      </DataToolbar>

      {loadError ? (
        <ErrorState title="The audit log could not be loaded" message={loadError} />
      ) : !entries ? (
        <LoadingState label="Loading the audit log" />
      ) : entries.length === 0 ? (
        <EmptyState
          title="No audit entries match"
          description="Nothing has been recorded under this filter. That is a real result, not a missing one."
        />
      ) : (
        <TableScroll label="Audit history">
          <DataTable caption="Audit history, most recent first">
            <TableHead>
              <TableRow>
                <TableHeader>When</TableHeader>
                <TableHeader>Action</TableHeader>
                <TableHeader>Actor</TableHeader>
                <TableHeader>Entity</TableHeader>
                <TableHeader>Summary</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {entries.map((entry) => (
                <TableRow key={entry.id}>
                  <TableCell className="tabular whitespace-nowrap">
                    {new Date(entry.occurred_at).toISOString().replace('T', ' ').slice(0, 19)}
                  </TableCell>
                  <TableCell>{entry.action}</TableCell>
                  <TableCell>{entry.actor_label ?? <NullValue />}</TableCell>
                  <TableCell>{entry.entity_table}</TableCell>
                  <TableCell>{entry.summary ?? <NullValue />}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}
