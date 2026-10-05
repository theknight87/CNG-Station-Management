import { useCallback, useEffect, useState } from 'react'

import { NullValue } from '@/components/data/NullValue'
import { Identifier } from '@/components/data/TechnicalText'
import { ErrorState, LoadingState } from '@/components/states/AppStates'
import { Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import { RecordAdminTools } from '@/features/record-tools/RecordAdminTools'
import { ReplaceValvePanel } from '@/features/relief-valves/ReplaceValvePanel'
import { RemoveValveButton } from '@/features/relief-valves/SrvAdminActions'
import { ParentCell, RegionChip } from '@/features/relief-valves/SrvPieces'
import { ValveHistory } from '@/features/relief-valves/SrvWorkflowPieces'
import { INSTALLED_COLUMNS } from '@/features/relief-valves/srvColumns'
import type { InstalledSrvRow } from '@/features/relief-valves/useSrvManagement'
import { DueBadge, PrecisionDate, PressureRange, Serial, Text } from '@/features/units/assetDisplay'
import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * ONE details panel for an installed relief valve (owner request 2026-10-05: "unify the work and the data").
 *
 * Installed SRVs, the Unit window and the Unit page used to draw three different panels — the Unit window
 * listed raw columns and none of them could delete. Every place now reads the same row from
 * `v_installed_srv_management` and shows the same facts and the same admin actions (replace, history, delete,
 * edit, photos). The actions are admin-only SECURITY DEFINER functions; hiding them is UX only.
 */

/** Details panel only. A recorded code, or the code of the single warehouse record with the same serial, labelled as such. */
function WarehouseCode({ row }: { row: InstalledSrvRow }) {
  if (!row.warehouse_code) return <NullValue />
  // Owner rule: an installed valve carries the code it LEFT the warehouse with — new (mb 9) or calibrated (mbc 9).
  // An under-calibration code (mbu 9) cannot belong to a valve on a station, so a serial match to one is not shown.
  if (/^[a-z]{2}u\s*\d/i.test(row.warehouse_code.trim())) {
    return <span className="text-xs text-muted-foreground">Not shown — the serial matches a warehouse record under calibration ({row.warehouse_code})</span>
  }
  return (
    <span className="inline-flex items-center gap-1 whitespace-nowrap">
      <Identifier value={row.warehouse_code} />
      {row.warehouse_code_source === 'serial_match' ? (
        <span className="cell-note text-[0.7rem] text-muted-foreground" title="Found by matching the serial to exactly one warehouse record">by serial</span>
      ) : null}
    </span>
  )
}

export function ValveSize({ type, inlet, outlet }: { type: string | null; inlet: string | null; outlet: string | null }) {
  const t = type?.toLowerCase()
  const prefix = t === 'male' ? 'M' : t === 'female' ? 'F' : t === 'flange' ? 'Flange' : type
  const value = [prefix, inlet].filter(Boolean).join(' ') + (outlet ? ` X ${outlet}` : '')
  return value.trim() ? <span className="whitespace-nowrap font-technical">{value}</span> : <NullValue />
}

/** The facts of one installed valve, as cells of a FactGrid. */
export function InstalledSrvFacts({ row: r }: { row: InstalledSrvRow }) {
  const unconfirmed = r.mapping_status === 'needs_station_mapping'
  return (
    <>
      <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
      <Fact label="Part number">{r.part_number ? <Identifier value={r.part_number} /> : <NullValue />}</Fact>
      <Fact label="Warehouse code"><WarehouseCode row={r} /></Fact>
      <Fact label="Tag number">{r.tag_number ? <Identifier value={r.tag_number} /> : <NullValue />}</Fact>
      <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
      <Fact label="Size type"><Text value={r.size_type} /></Fact>
      <Fact label="Inlet size">{r.inlet_size ? <Identifier value={r.inlet_size} /> : <NullValue />}</Fact>
      <Fact label="Outlet size">{r.outlet_size ? <Identifier value={r.outlet_size} /> : <NullValue />}</Fact>
      <Fact label="Set pressure">
        <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
      </Fact>
      <Fact label="Region">{unconfirmed ? <span className="text-muted-foreground">Not confirmed</span> : <RegionChip name={r.region_name} />}</Fact>
      <Fact label="Station">{unconfirmed ? <span className="text-muted-foreground">Not confirmed</span> : <Text value={r.station_name} />}</Fact>
      <Fact label="Unit"><Text value={r.unit_name} /></Fact>
      <Fact label="Equipment parent"><ParentCell row={r} /></Fact>
      <Fact label="Last calibration">
        <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />
      </Fact>
      <Fact label="Next calibration">
        <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
      </Fact>
      <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
      <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
      <Fact label="Notes"><Text value={r.notes} /></Fact>
    </>
  )
}

/** Replace, history and delete — the same three wherever a valve's details open. */
export function InstalledSrvActions({ row, onDone }: { row: InstalledSrvRow; onDone: () => void }) {
  return (
    <>
      <ReplaceValvePanel valve={row} onDone={onDone} />
      <ValveHistory valveId={row.id} />
      <RemoveValveButton table="installed_relief_valves" id={row.id} onDone={onDone} />
    </>
  )
}

function useInstalledSrv(id: string) {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<InstalledSrvRow | null>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { setState({ status: 'unconfigured' }); return }
      const { data, error } = await supabase.from('v_installed_srv_management').select(INSTALLED_COLUMNS).eq('id', id).maybeSingle()
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data as unknown as InstalledSrvRow | null) ?? null })
    })()
    return () => { cancelled = true }
  }, [supabase, id, nonce])
  return { state, reload }
}

/**
 * The full panel for a valve known only by id (the Unit window and the Unit page list a narrower row).
 * `onChanged` runs after a replace, a delete or an edit, so the list it came from reloads.
 */
export function InstalledSrvDetails({ id, onChanged, onGone }: { id: string; onChanged: () => void; onGone?: () => void }) {
  const { state, reload } = useInstalledSrv(id)
  if (state.status === 'loading') return <LoadingState label="Loading the relief valve" />
  if (state.status === 'unconfigured') return <ErrorState message="The database is not configured." />
  if (state.status === 'error') return <ErrorState message={state.message} onRetry={reload} />
  if (!state.data) return <p className="text-sm text-muted-foreground">This relief valve is no longer on the list (it was replaced or removed).</p>
  const done = () => { onChanged(); if (onGone) onGone(); else reload() }
  return (
    <div className="flex flex-col gap-1">
      <FactGrid><InstalledSrvFacts row={state.data} /></FactGrid>
      <InstalledSrvActions row={state.data} onDone={done} />
      <RecordAdminTools record={{ table: 'installed_relief_valves', id }} onSaved={() => { reload(); onChanged() }} />
    </div>
  )
}
