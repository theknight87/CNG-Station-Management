import { EntityName, Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { ErrorState, LoadingState } from '@/components/states/AppStates'
import { AttentionBadge } from '@/features/hierarchy/HierarchyPieces'
import { useStation, type UnitSummary } from '@/features/hierarchy/useHierarchy'

/** The Units under one Station row, as the next level of the hierarchy. Clicking a Unit opens its popup. */
export function StationUnits({ stationId, onOpen }: { stationId: string; onOpen: (unit: UnitSummary) => void }) {
  const { state, reload } = useStation(stationId)
  if (state.status === 'loading') return <LoadingState label="Loading Units" />
  if (state.status === 'error') return <ErrorState message={state.message} onRetry={reload} />
  if (state.status !== 'ready' || !state.data) return null
  const units = state.data.units
  if (units.length === 0) {
    return <p className="text-sm text-muted-foreground">No Unit is recorded for this Station. Its equipment is held at Station level.</p>
  }
  return (
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
  )
}
