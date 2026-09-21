import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { DetailGrid, DetailItem, RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { DataToolbar, SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import {
  EMPTY_AUDIT_FILTERS, useAdminAuditLog, useAuditActors, type AuditFilters, type AuditLogRow,
} from '../useAdminAuditLog'

const ACTIONS = [
  { value: '', label: 'Every action' },
  { value: 'user_role_changed', label: 'Role changed' },
  { value: 'user_activation_changed', label: 'Activation changed' },
  { value: 'region_access_changed', label: 'Region access changed' },
  { value: 'alert_rule_changed', label: 'Alert rule / channel policy' },
  { value: 'mapping_changed', label: 'Mapping resolved' },
]

const ENTITIES = [
  { value: '', label: 'Every record type' },
  { value: 'app_users', label: 'Users' },
  { value: 'user_region_access', label: 'Region access' },
  { value: 'alert_rules', label: 'Alert rules' },
  { value: 'notification_channel_policy', label: 'Channel policy' },
  { value: 'installed_relief_valves', label: 'Installed SRVs' },
  { value: 'import_mapping_decisions', label: 'Pre-import decisions' },
]

/**
 * Audit history.
 *
 * READ ONLY — and not by convention. No browser role holds UPDATE or DELETE on
 * `audit_logs`, so this history cannot be rewritten from the application at all,
 * by anyone. The actor on each row was derived server-side from the verified
 * Clerk subject at write time; it was never a value the client supplied.
 *
 * Before/after are rendered as raw JSON on purpose. This is evidence, and a
 * prettified diff invites an argument about whether the prettifier is honest.
 */
export function AdminAuditLogSection() {
  const [filters, setFilters] = useState<AuditFilters>(EMPTY_AUDIT_FILTERS)
  const { entries, loadError, loading, hasMore, loadMore } = useAdminAuditLog(filters)
  const actors = useAuditActors()
  const [open, setOpen] = useState<string | null>(null)

  const set = (patch: Partial<AuditFilters>) => setFilters({ ...filters, ...patch })
  const filtered = JSON.stringify(filters) !== JSON.stringify(EMPTY_AUDIT_FILTERS)

  return (
    <section className="space-y-3" aria-labelledby="admin-audit-heading">
      <SectionHeader
        id="admin-audit-heading"
        title="Audit log"
        description="Who changed what, and when, with the values before and after. Append-only: this record cannot be edited or deleted from the application by anyone, administrators included."
      />

      <DataToolbar label="Filter the audit log">
        <Field label="From" htmlFor="audit-from">
          <input
            id="audit-from" type="date" value={filters.from}
            onChange={(e) => set({ from: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          />
        </Field>
        <Field label="To" htmlFor="audit-to">
          <input
            id="audit-to" type="date" value={filters.to}
            onChange={(e) => set({ to: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          />
        </Field>
        <Field label="Actor" htmlFor="audit-actor">
          <select
            id="audit-actor" value={filters.actorId}
            onChange={(e) => set({ actorId: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            <option value="">Anyone</option>
            {actors.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Action" htmlFor="audit-action">
          <select
            id="audit-action" value={filters.action}
            onChange={(e) => set({ action: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Record type" htmlFor="audit-entity">
          <select
            id="audit-entity" value={filters.entityTable}
            onChange={(e) => set({ entityTable: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            {ENTITIES.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Record ID or summary" htmlFor="audit-search">
          <input
            id="audit-search" type="search" value={filters.search}
            onChange={(e) => set({ search: e.target.value })}
            placeholder="id or text"
            className="h-7 w-52 rounded border bg-background px-1 text-xs"
          />
        </Field>
        {filtered ? (
          <Button type="button" variant="outline" size="sm"
                  onClick={() => setFilters(EMPTY_AUDIT_FILTERS)}>
            Clear filters
          </Button>
        ) : null}
      </DataToolbar>

      {loadError ? (
        <ErrorState title="The audit log could not be loaded" message={loadError} />
      ) : !entries ? (
        <LoadingState label="Loading the audit log" />
      ) : entries.length === 0 ? (
        <EmptyState
          title="No audit entries match"
          description="Nothing has been recorded under these filters. That is a real result, not a missing one."
        />
      ) : (
        <>
          <TableScroll label="Audit history">
            <DataTable className="responsive-records compact-records" caption="Audit history, most recent first, with before and after values">
              <TableHead>
                <TableRow>
                  <TableHeader>When</TableHeader>
                  <TableHeader>Actor</TableHeader>
                  <TableHeader>Action</TableHeader>
                  <TableHeader>Record</TableHeader>
                  <TableHeader>Summary</TableHeader>
                  <TableHeader className="w-24">Details</TableHeader>
                </TableRow>
              </TableHead>
              <TableBody>
                {entries.map((entry) => (
                  <TableRow key={entry.id} selected={open === entry.id} onClick={() => setOpen(entry.id)} className="cursor-pointer">
                    <TableCell numeric dataLabel="When">
                      <span className="whitespace-nowrap">{formatAuditDate(entry.occurred_at)}</span>
                      <span className="hidden">{entry.occurred_at.replace('T', ' ').replace('Z', '')}</span>
                    </TableCell>
                    <TableCell dataLabel="Actor">{entry.actor_label ?? <NullValue />}</TableCell>
                    <TableCell dataLabel="Action">
                      <span className="whitespace-nowrap">{humanize(entry.action)}</span>
                      <span className="hidden">{entry.action}</span>
                    </TableCell>
                    <TableCell dataLabel="Record">
                      <span>{humanize(entry.entity_table)}</span>
                      {entry.entity_id ? <span className="ml-1 font-technical text-xs text-muted-foreground" title={entry.entity_id}>#{shortId(entry.entity_id)}</span> : null}
                      <span className="hidden">{entry.entity_table}</span>
                      <span className="hidden">{entry.entity_id}</span>
                    </TableCell>
                    <TableCell dataLabel="Summary"><span className="line-clamp-1" title={entry.summary ?? undefined}>{entry.summary ?? <NullValue />}</span></TableCell>
                    <TableCell dataLabel="Details">
                      <Button
                        type="button" variant="outline" size="sm"
                        aria-label={`${open === entry.id ? 'Hide' : 'Show'} before and after values for ${entry.action} at ${entry.occurred_at}`}
                        onClick={(event) => { event.stopPropagation(); setOpen(entry.id) }}
                      >
                        View
                      </Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </DataTable>
          </TableScroll>

          <AuditDetails entry={entries.find((e) => e.id === open) ?? null} onClose={() => setOpen(null)} />

          <div className="flex items-center gap-3">
            <span className="text-xs text-muted-foreground">
              Showing <span className="tabular">{entries.length}</span> entries
              {hasMore ? ', more available' : ' — this is the end of the history under these filters'}
            </span>
            {hasMore ? (
              <Button type="button" variant="outline" size="sm" disabled={loading} onClick={loadMore}>
                Load more
              </Button>
            ) : null}
          </div>
        </>
      )}
    </section>
  )
}

function formatAuditDate(value: string) {
  return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
}

function humanize(value: string) { return value.replaceAll('_', ' ').replace(/\b\w/g, (c) => c.toUpperCase()) }
function shortId(value: string) { return value.length > 12 ? `${value.slice(0, 8)}…${value.slice(-4)}` : value }

function AuditDetails({ entry, onClose }: { entry: AuditLogRow | null; onClose: () => void }) {
  return (
    <RecordDetailsDialog open={entry !== null} title="Audit record" description="Complete immutable change evidence" onClose={onClose}>
      {entry ? <div className="space-y-5">
        <DetailGrid>
          <DetailItem label="When"><span className="whitespace-nowrap tabular">{formatAuditDate(entry.occurred_at)}</span></DetailItem>
          <DetailItem label="Actor">{entry.actor_label ?? <NullValue />}</DetailItem>
          <DetailItem label="Action">{humanize(entry.action)}</DetailItem>
          <DetailItem label="Record type">{humanize(entry.entity_table)}</DetailItem>
          <DetailItem label="Record ID"><span className="font-technical text-xs" title={entry.entity_id ?? undefined}>{entry.entity_id ?? <NullValue />}</span></DetailItem>
          <DetailItem label="Summary">{entry.summary ?? <NullValue />}</DetailItem>
        </DetailGrid>
        <BeforeAfter entry={entry} />
      </div> : null}
    </RecordDetailsDialog>
  )
}

function BeforeAfter({ entry }: { entry: { before_data: unknown; after_data: unknown } | null }) {
  if (!entry) return null
  return (
    <div className="grid gap-2 rounded border bg-muted/40 p-2 md:grid-cols-2">
      <Side title="Before" value={entry.before_data} absent="No previous value — this record was created." />
      <Side title="After" value={entry.after_data} absent="No resulting value — this record was removed." />
    </div>
  )
}

function Side({ title, value, absent }: { title: string; value: unknown; absent: string }) {
  return (
    <div className="min-w-0">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">{title}</h3>
      {value === null || value === undefined ? (
        // NULL here is a fact about the change, not a missing value, so it is
        // stated rather than rendered as a placeholder.
        <p className="text-xs text-muted-foreground">{absent}</p>
      ) : (
        <pre className="overflow-auto whitespace-pre-wrap break-all text-xs">
          {JSON.stringify(value, null, 2)}
        </pre>
      )}
    </div>
  )
}

function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <label className="text-xs font-medium" htmlFor={htmlFor}>{label}</label>
      {children}
    </div>
  )
}

