import { useState, type ComponentType, type ReactNode } from 'react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Button } from '@/components/ui/button'
import { useStations, useUnits } from '@/features/admin/useMappingOptions'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useConfirmedAction, useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'

/**
 * Admin-only delete / edit controls for the SRV screens (owner request 2026-09-28).
 *
 * "Delete" ARCHIVES: the record leaves every list but is kept with who and when (CLAUDE.md §10, no hard
 * deletes). Every control calls an admin-only SECURITY DEFINER function that derives the actor server-side
 * and writes an audit row; hiding the buttons from non-admins is UX only — the database refuses them anyway.
 */

/**
 * A small button inside a clickable row: it never opens the row's details. With an `icon` it renders
 * icon-only (the label becomes its accessible name and tooltip) so a row of actions stays narrow enough
 * for the table to fit the page without sideways scrolling.
 */
export function RowAction({ label, onClick, danger, disabled, icon: Icon }: {
  label: string; onClick: () => void; danger?: boolean; disabled?: boolean; icon?: ComponentType<{ className?: string }>
}) {
  if (Icon) {
    return (
      <button type="button" aria-label={label} title={label} disabled={disabled}
              onClick={(e) => { e.stopPropagation(); onClick() }}
              className={'flex h-7 w-7 shrink-0 items-center justify-center rounded border bg-background disabled:opacity-50 '
                + (danger ? 'border-destructive/40 text-destructive hover:bg-destructive hover:text-destructive-foreground'
                          : 'text-muted-foreground hover:bg-muted hover:text-foreground')}>
        <Icon className="h-3.5 w-3.5" aria-hidden="true" />
      </button>
    )
  }
  return (
    <Button type="button" size="sm" variant={danger ? 'destructive' : 'outline'} className="h-6 px-2 text-xs" disabled={disabled}
            onClick={(e) => { e.stopPropagation(); onClick() }}>
      {label}
    </Button>
  )
}

export function RowActions({ children }: { children: ReactNode }) {
  return <span className="flex flex-nowrap items-center gap-1" onClick={(e) => e.stopPropagation()}>{children}</span>
}

/** Move an SRV Log entry to another Station (and optionally one of its Units). */
export function LogMoveDialog({ logId, onClose, onDone }: { logId: string | null; onClose: () => void; onDone: () => void }) {
  const stations = useStations()
  const [stationId, setStationId] = useState('')
  const units = useUnits(stationId || null)
  const [unitId, setUnitId] = useState('')
  const [filter, setFilter] = useState('')
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  const shown = stations.filter((s) => s.label.includes(filter.trim()))
  async function save() {
    setError(null)
    const err = await run('cng_srv_log_move', { p_log_id: logId, p_station_id: stationId, p_unit_id: unitId || null })
    if (err) { setError(err); return }
    setStationId(''); setUnitId(''); onDone(); onClose()
  }
  return (
    <RecordDetailsDialog open={logId !== null} title="Move to another station" description="The log entry moves; the valve's record is not changed." onClose={onClose}>
      <div className="flex flex-col gap-2">
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Find station
          <input dir="auto" className="h-8 rounded border bg-background px-2 text-sm" value={filter} onChange={(e) => setFilter(e.target.value)} />
        </label>
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Station
          <select dir="auto" className="h-8 rounded border bg-background px-2 text-sm text-foreground" value={stationId}
                  onChange={(e) => { setStationId(e.target.value); setUnitId('') }}>
            <option value="">Choose…</option>
            {shown.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
          </select>
        </label>
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Unit (optional)
          <select dir="auto" className="h-8 rounded border bg-background px-2 text-sm text-foreground" value={unitId}
                  disabled={!stationId} onChange={(e) => setUnitId(e.target.value)}>
            <option value="">Not specified</option>
            {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
          </select>
        </label>
        <FormMessage error={error} done={null} />
        <div className="flex justify-end gap-2">
          <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
          <Button size="sm" disabled={!stationId || busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Move'}</Button>
        </div>
      </div>
    </RecordDetailsDialog>
  )
}

/** Edit the certificate fields of a 3rd party calibration entry. */
export function CalibrationEditDialog({ job, onClose, onDone }: {
  job: { id: string; certificate_date: string | null; certificate_number: string | null; next_calibration_date: string | null } | null
  onClose: () => void
  onDone: () => void
}) {
  const [date, setDate] = useState('')
  const [no, setNo] = useState('')
  const [next, setNext] = useState('')
  const [seen, setSeen] = useState<string | null>(null)
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  if (job && seen !== job.id) {
    setSeen(job.id); setDate(job.certificate_date ?? ''); setNo(job.certificate_number ?? ''); setNext(job.next_calibration_date ?? '')
  }
  async function save() {
    if (!job) return
    setError(null)
    const err = await run('cng_srv_calibration_edit', {
      p_job_id: job.id, p_certificate_date: date || null, p_certificate_number: no.trim() || null, p_next_calibration_date: next || null,
    })
    if (err) { setError(err); return }
    onDone(); onClose()
  }
  return (
    <RecordDetailsDialog open={job !== null} title="Edit calibration entry" onClose={() => { setSeen(null); onClose() }}>
      <div className="flex flex-col gap-2">
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Certificate date
          <input type="date" className="h-8 rounded border bg-background px-2 text-sm" value={date} onChange={(e) => setDate(e.target.value)} />
        </label>
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Certificate no.
          <input className="h-8 rounded border bg-background px-2 text-sm" value={no} onChange={(e) => setNo(e.target.value)} />
        </label>
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Next calibration
          <input type="date" className="h-8 rounded border bg-background px-2 text-sm" value={next} onChange={(e) => setNext(e.target.value)} />
        </label>
        <FormMessage error={error} done={null} />
        <div className="flex justify-end gap-2">
          <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
          <Button size="sm" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save'}</Button>
        </div>
      </div>
    </RecordDetailsDialog>
  )
}

/** Remove an installed or warehouse relief valve (archive), from its details panel. */
export function RemoveValveButton({ table, id, onDone }: { table: 'installed_relief_valves' | 'warehouse_relief_valves'; id: string; onDone: () => void }) {
  const isAdmin = useIsAdmin()
  const { act, busy, error, done } = useConfirmedAction(onDone)
  if (!isAdmin) return null
  return (
    <div className="mt-3 flex flex-col gap-1 border-t pt-3">
      <div>
        <Button size="sm" variant="destructive" disabled={busy}
                onClick={() => void act('Remove this relief valve from the list? It is archived (kept in the audit history), not destroyed.',
                  'cng_admin_archive_srv', { p_table: table, p_id: id }, 'Relief valve removed.')}>
          Delete this relief valve
        </Button>
      </div>
      <FormMessage error={error} done={done} />
    </div>
  )
}
