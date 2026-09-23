import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { DetailGrid, DetailItem, RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { DataToolbar, SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { PaginationControls } from '@/components/data/PaginationControls'
import { humanizeAuditAction, humanizeRecordType, humanizeTechnicalValue } from '@/lib/presentation/humanize'
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
 * The immutable before/after evidence remains stored in the database, while
 * this screen translates it into a compact, human-readable list of changes.
 */
export function AdminAuditLogSection() {
  const [filters, setFilters] = useState<AuditFilters>(EMPTY_AUDIT_FILTERS)
  const { entries, loadError, loading, total, page, pageSize, onPage } = useAdminAuditLog(filters)
  const actors = useAuditActors()
  const [open, setOpen] = useState<string | null>(null)

  const set = (patch: Partial<AuditFilters>) => setFilters({ ...filters, ...patch })
  const filtered = JSON.stringify(filters) !== JSON.stringify(EMPTY_AUDIT_FILTERS)

  return (
    <section className="space-y-3" aria-labelledby="admin-audit-heading">
      <SectionHeader
        id="admin-audit-heading"
        title="Audit log"
        description="Who changed what and when, with readable change details. Append-only: this record cannot be edited or deleted from the application by anyone, administrators included."
      />

      <DataToolbar label="Filter the audit log">
        <Field label="Day" htmlFor="audit-day">
          <input
            id="audit-day" name="audit-day" type="date" value={filters.from === filters.to ? filters.from : ''}
            onChange={(e) => set({ from: e.target.value, to: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          />
        </Field>
        <Field label="Actor" htmlFor="audit-actor">
          <select
            id="audit-actor" name="audit-actor" value={filters.actorId}
            onChange={(e) => set({ actorId: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            <option value="">Anyone</option>
            {actors.map((a) => <option key={a.id} value={a.id}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Action" htmlFor="audit-action">
          <select
            id="audit-action" name="audit-action" value={filters.action}
            onChange={(e) => set({ action: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            {ACTIONS.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Record type" htmlFor="audit-entity">
          <select
            id="audit-entity" name="audit-entity" value={filters.entityTable}
            onChange={(e) => set({ entityTable: e.target.value })}
            className="h-7 rounded border bg-background px-1 text-xs"
          >
            {ENTITIES.map((a) => <option key={a.value} value={a.value}>{a.label}</option>)}
          </select>
        </Field>
        <Field label="Record ID or summary" htmlFor="audit-search">
          <input
            id="audit-search" name="audit-search" type="search" value={filters.search}
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
            <DataTable className="responsive-records compact-records" caption="Audit history, most recent first">
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
                      <span className="whitespace-nowrap">{humanizeAuditAction(entry.action)}</span>
                      <span className="hidden">{entry.action}</span>
                    </TableCell>
                    <TableCell dataLabel="Record">
                      <span>{humanizeRecordType(entry.entity_table)}</span>
                      {entry.entity_id ? <span className="ml-1 font-technical text-xs text-muted-foreground" title={entry.entity_id}>#{shortId(entry.entity_id)}</span> : null}
                      <span className="hidden">{entry.entity_table}</span>
                      <span className="hidden">{entry.entity_id}</span>
                    </TableCell>
                    <TableCell dataLabel="Summary"><span className="line-clamp-1" title={entry.summary ?? undefined}>{entry.summary ?? <NullValue />}</span></TableCell>
                    <TableCell dataLabel="Details">
                      <Button
                        type="button" variant="outline" size="sm"
                        aria-label={`${open === entry.id ? 'Hide' : 'Show'} change details for ${entry.action} at ${entry.occurred_at}`}
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

          {total !== null ? <PaginationControls label="Audit log" page={page} pageSize={pageSize} total={total} visibleRows={entries.length} loading={loading} onPage={onPage} /> : null}
        </>
      )}
    </section>
  )
}

function formatAuditDate(value: string) {
  return new Intl.DateTimeFormat('en-GB', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
}

function shortId(value: string) { return value.length > 12 ? `${value.slice(0, 8)}…${value.slice(-4)}` : value }

function AuditDetails({ entry, onClose }: { entry: AuditLogRow | null; onClose: () => void }) {
  return (
    <RecordDetailsDialog open={entry !== null} title="Audit record" description="Complete immutable change evidence" onClose={onClose}>
      {entry ? <div className="space-y-5">
        <DetailGrid>
          <DetailItem label="When"><span className="whitespace-nowrap tabular">{formatAuditDate(entry.occurred_at)}</span></DetailItem>
          <DetailItem label="Actor">{entry.actor_label ?? <NullValue />}</DetailItem>
          <DetailItem label="Action">{humanizeAuditAction(entry.action)}</DetailItem>
          <DetailItem label="Record type">{humanizeRecordType(entry.entity_table)}</DetailItem>
          <DetailItem label="Record ID"><span className="font-technical text-xs" title={entry.entity_id ?? undefined}>{entry.entity_id ? shortId(entry.entity_id) : <NullValue />}</span></DetailItem>
          <DetailItem label="Summary">{entry.summary ?? <NullValue />}</DetailItem>
        </DetailGrid>
        <ChangeDetails entry={entry} />
      </div> : null}
    </RecordDetailsDialog>
  )
}

function ChangeDetails({ entry }: { entry: { before_data: unknown; after_data: unknown } | null }) {
  if (!entry) return null
  const before = asRecord(entry.before_data)
  const after = asRecord(entry.after_data)
  const keys = Array.from(new Set([...Object.keys(before), ...Object.keys(after)]))
  return (
    <section aria-labelledby="recorded-change-title" className="space-y-2">
      <div>
        <h3 id="recorded-change-title" className="text-sm font-semibold">Recorded change</h3>
        <p className="text-xs text-muted-foreground">Stored audit evidence, presented as readable field changes.</p>
      </div>
      {keys.length ? (
        <DetailGrid>
          {keys.map((key) => (
            <DetailItem key={key} label={humanizeTechnicalValue(key) ?? key}>
              <ChangeValue before={before[key]} after={after[key]} hasBefore={key in before} hasAfter={key in after} />
            </DetailItem>
          ))}
        </DetailGrid>
      ) : <p className="rounded border bg-muted/30 p-3 text-sm text-muted-foreground">No field-level values were recorded for this event.</p>}
    </section>
  )
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : {}
}

function displayValue(value: unknown) {
  if (value === null || value === undefined || value === '') return 'Not recorded'
  if (typeof value === 'object') return JSON.stringify(value)
  return String(value)
}

function ChangeValue({ before, after, hasBefore, hasAfter }: { before: unknown; after: unknown; hasBefore: boolean; hasAfter: boolean }) {
  if (!hasBefore) return <span>{displayValue(after)}</span>
  if (!hasAfter) return <span className="text-muted-foreground">Removed (was {displayValue(before)})</span>
  if (JSON.stringify(before) === JSON.stringify(after)) return <span>{displayValue(after)}</span>
  return <span><span className="text-muted-foreground line-through">{displayValue(before)}</span><span aria-hidden="true"> → </span>{displayValue(after)}</span>
}

function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <label className="text-xs font-medium" htmlFor={htmlFor}>{label}</label>
      {children}
    </div>
  )
}
