import { useState, type ReactNode } from 'react'
import { Link } from 'react-router-dom'

import { Button } from '@/components/ui/button'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { EntityName } from '@/components/data/TechnicalText'
import { Count, Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { STATIONS_CHANGED, StationPopupContext, useOpenStation } from '@/features/hierarchy/stationPopupContext'
import { StationUnits } from '@/features/hierarchy/StationUnits'
import { useStation, type UnitSummary } from '@/features/hierarchy/useHierarchy'
import { UnitPopup } from '@/features/units/UnitPopup'

/**
 * Clicking a Station anywhere opens its hierarchy in place (owner request 2026-09-28): the Station's totals and its
 * Units; a Unit opens the tabbed Unit popup on top. Nothing navigates away; the full Station page is one link away.
 */
export function StationPopupProvider({ children }: { children: ReactNode }) {
  const [station, setStation] = useState<{ id: string; name: string } | null>(null)
  const [unit, setUnit] = useState<UnitSummary | null>(null)
  return (
    <StationPopupContext.Provider value={setStation}>
      {children}
      <RecordDetailsDialog open={station !== null} size="wide" title={station?.name ?? ''} onClose={() => setStation(null)}
                           actions={station ? (<>
                             <DeleteStationButton stationId={station.id} name={station.name} onDone={() => setStation(null)} />
                             <Link to={`/stations/${station.id}`} onClick={() => setStation(null)}
                                   className="inline-flex h-8 items-center rounded border px-3 text-sm hover:bg-muted">Open the Station page</Link>
                           </>) : null}>
        {station ? <StationBody stationId={station.id} onOpenUnit={setUnit} /> : null}
      </RecordDetailsDialog>
      <UnitPopup unit={unit} onClose={() => setUnit(null)} />
    </StationPopupContext.Provider>
  )
}

function StationBody({ stationId, onOpenUnit }: { stationId: string; onOpenUnit: (u: UnitSummary) => void }) {
  const { state } = useStation(stationId)
  const s = state.status === 'ready' ? state.data.station : null
  return (
    <div className="flex flex-col gap-3">
      {s ? (
        <FactGrid>
          <Fact label="Region">{s.region_name}</Fact>
          <Fact label="Units"><Count value={s.units} /></Fact>
          <Fact label="Assets"><Count value={s.assets} /></Fact>
          <Fact label="Overdue"><Count value={s.overdue} tone="overdue" /></Fact>
          <Fact label="Due ≤60d"><Count value={s.approaching_due} tone="due" /></Fact>
          <Fact label="Bay status"><ValueOrNull value={s.bay_status} /></Fact>
        </FactGrid>
      ) : null}
      <h3 className="text-sm font-semibold">Units</h3>
      <StationUnits stationId={stationId} onOpen={onOpenUnit} />
    </div>
  )
}

/** A Station name that opens the Station popup; plain text when no provider is mounted or the Station is unknown. */
export function StationName({ id, name, className }: { id: string | null | undefined; name: string | null | undefined; className?: string }) {
  const open = useOpenStation()
  if (!name) return <NullValue />
  if (!id || !open) return <span dir="auto" className={className}><EntityName name={name} /></span>
  return (
    <button type="button" dir="auto"
            className={`text-left font-medium text-[var(--brand-strong)] underline-offset-2 hover:underline ${className ?? ''}`}
            onClick={(e) => { e.stopPropagation(); open({ id, name }) }}>
      <EntityName name={name} />
    </button>
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
    window.dispatchEvent(new Event(STATIONS_CHANGED))
    onDone()
  }
  return (
    <span className="mr-auto flex items-center gap-2">
      <Button size="sm" variant="destructive" disabled={busy} onClick={() => void remove()}>Delete this Station</Button>
      {error ? <span role="alert" className="text-xs text-destructive">{error}</span> : null}
    </span>
  )
}
