import { useState } from 'react'

import { Button } from '@/components/ui/button'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { EntityName, Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { ErrorState, LoadingState } from '@/components/states/AppStates'
import { AttentionBadge } from '@/features/hierarchy/HierarchyPieces'
import { useStation, type UnitSummary } from '@/features/hierarchy/useHierarchy'

/** The Units under one Station row, as the next level of the hierarchy. Clicking a Unit opens its popup. */
export function StationUnits({ stationId, stationName, onOpen, onRemoved }: {
  stationId: string; stationName?: string; onOpen: (unit: UnitSummary) => void; onRemoved?: () => void
}) {
  const { state, reload } = useStation(stationId)
  if (state.status === 'loading') return <LoadingState label="Loading Units" />
  if (state.status === 'error') return <ErrorState message={state.message} onRetry={reload} />
  if (state.status !== 'ready' || !state.data) return null
  const units = state.data.units
  const remove = onRemoved && stationName ? <DeleteStationButton stationId={stationId} name={stationName} onDone={onRemoved} /> : null
  if (units.length === 0) {
    return (
      <div className="flex flex-wrap items-center justify-between gap-2">
        <p className="text-sm text-muted-foreground">No Unit is recorded for this Station. Its equipment is held at Station level.</p>
        {remove}
      </div>
    )
  }
  return (
    <div className="flex flex-col gap-2">
    <ul aria-label="Units" className="flex flex-col gap-1 border-l-2 border-[var(--brand)] pl-3">
      {units.map((u) => (
        <li key={u.unit_id}>
          <button type="button" onClick={() => onOpen(u)}
                  className="flex w-full flex-wrap items-center gap-x-4 gap-y-1 rounded px-2 py-1 text-left text-sm hover:bg-muted">
            <span className="min-w-40 font-medium text-[var(--brand-strong)]"><EntityName name={u.unit_name} /></span>
            <span className="text-xs text-muted-foreground">Job {u.job_number ? <Identifier value={u.job_number} /> : <NullValue />}</span>
            <span className="tabular text-xs text-muted-foreground">
              SRVs {u.installed_srvs} · Storage {u.storage_vessels} · Recovery {u.recovery_tanks} · Detectors {u.gas_detectors} · Dispensers {u.dispensers} · Hoses {u.hoses}
            </span>
            <AttentionBadge overdue={u.overdue} unresolved={0} />
          </button>
        </li>
      ))}
    </ul>
    {remove ? <div className="flex justify-end">{remove}</div> : null}
    </div>
  )
}

/** Admin: remove (archive) a Station with no live equipment — e.g. a test Station added by mistake. */
function DeleteStationButton({ stationId, name, onDone }: { stationId: string; name: string; onDone: () => void }) {
  const isAdmin = useIsAdmin()
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  if (!isAdmin) return null
  async function remove() {
    if (!window.confirm(`Delete the Station "${name}" and its Units? It is archived (kept in the audit history), not destroyed.`)) return
    setError(null)
    const err = await run('cng_admin_archive_station', { p_station_id: stationId })
    if (err) { setError(err); return }
    onDone()
  }
  return (
    <span className="flex items-center gap-2">
      {error ? <span role="alert" className="text-xs text-destructive">{error}</span> : null}
      <Button size="sm" variant="destructive" className="h-7" disabled={busy} onClick={() => void remove()}>Delete this Station</Button>
    </span>
  )
}
