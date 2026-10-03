import { useEffect, useMemo, useState } from 'react'
import { Replace } from 'lucide-react'

import { NullValue } from '@/components/data/NullValue'
import { Button } from '@/components/ui/button'
import { LoadingState } from '@/components/states/AppStates'
import { useStations, useUnits } from '@/features/admin/useMappingOptions'
import { AVAILABILITY_LABEL } from '@/features/relief-valves/useSrvManagement'
import { Code, FormMessage, Pressure, ValveSize } from '@/features/relief-valves/SrvWorkflowPieces'
import { sizeText, useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { useSupabaseClient } from '@/lib/supabase/client'
import { cn } from '@/lib/utils'
import { STOCK_COLUMNS, matchesSpec, type ReplaceableValve, type StockRow } from './replaceMatch'

/**
 * Replace an installed relief valve with a matching valve from the store (owner request 2026-09-29), from the valve's
 * own details — Installed SRVs, the Unit window and the Unit page.
 *
 * MATCHING: the same set pressure exactly (value and unit — the rule cng_srv_issue itself enforces), the same size
 * type, inlet and outlet (compared ignoring spaces, quotes and case), and — by default, switchable — the same
 * manufacturer. A part the installed valve does not record is not used to narrow. Only valves IN THE STORE are
 * offered: calibrated by default, new ones on request.
 *
 * THE DATABASE DECIDES. Confirming calls the existing cng_srv_issue with this valve as the one replaced: admin only,
 * version-checked on the chosen store valve, audited; the old valve moves to the SRV Log until it returns.
 */

const field = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

export function ReplaceValvePanel({ valve, onDone, startOpen = false, onCancel }: {
  valve: ReplaceableValve
  onDone: () => void
  /** Open straight on the form (the Replace button beside a valve in a list), with Cancel going to `onCancel`. */
  startOpen?: boolean
  onCancel?: () => void
}) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(startOpen)
  if (!isAdmin) return null
  if (!open) {
    return (
      <div className="mt-3 border-t pt-3">
        <Button size="sm" variant="outline" onClick={() => setOpen(true)}>
          <Replace className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />Replace this valve
        </Button>
      </div>
    )
  }
  return <ReplaceForm valve={valve} onDone={onDone} onCancel={onCancel ?? (() => setOpen(false))} />
}

function ReplaceForm({ valve, onDone, onCancel }: { valve: ReplaceableValve; onDone: () => void; onCancel: () => void }) {
  const supabase = useSupabaseClient()
  const stations = useStations()
  const [stationId, setStationId] = useState<string | null>(valve.station_id)
  const units = useUnits(stationId)
  const [unitId, setUnitId] = useState<string | null>(valve.unit_id)
  const [includeNew, setIncludeNew] = useState(false)
  const [sameMaker, setSameMaker] = useState(Boolean(valve.manufacturer))
  const [stock, setStock] = useState<{ status: 'loading' } | { status: 'error'; message: string } | { status: 'ready'; rows: StockRow[] }>({ status: 'loading' })
  const [chosen, setChosen] = useState<string>('')
  const [emergency, setEmergency] = useState(false)
  const [notes, setNotes] = useState('')
  const [error, setError] = useState<string | null>(null)
  const { run, busy } = useWorkflowAction()

  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { setStock({ status: 'error', message: 'The database is not configured.' }); return }
      setStock({ status: 'loading' })
      let q = supabase.from('v_srv_warehouse_stock').select(STOCK_COLUMNS)
        .in('availability_status', includeNew ? ['available_calibrated', 'available_new'] : ['available_calibrated'])
      // Exactly the set-pressure rule cng_srv_issue enforces (IS NOT DISTINCT FROM on min, max and unit).
      q = valve.pressure_min === null ? q.is('pressure_min', null) : q.eq('pressure_min', valve.pressure_min)
      q = valve.pressure_max === null ? q.is('pressure_max', null) : q.eq('pressure_max', valve.pressure_max)
      q = valve.pressure_unit === null ? q.is('pressure_unit', null) : q.eq('pressure_unit', valve.pressure_unit)
      const { data, error: e } = await q.order('availability_status').order('warehouse_code', { nullsFirst: false }).order('serial_number').limit(500)
      if (cancelled) return
      if (e) setStock({ status: 'error', message: e.message })
      else setStock({ status: 'ready', rows: (data ?? []) as unknown as StockRow[] })
    })()
    return () => { cancelled = true }
  }, [supabase, includeNew, valve.pressure_min, valve.pressure_max, valve.pressure_unit])

  const matches = useMemo(() => (stock.status === 'ready' ? stock.rows.filter((s) => matchesSpec(valve, s, sameMaker)) : []), [stock, valve, sameMaker])
  const picked = matches.find((s) => s.id === chosen) ?? null

  async function confirm() {
    if (!picked || !unitId) return
    setError(null)
    const err = await run('cng_srv_issue', {
      p_warehouse_valve_id: picked.id,
      p_expected_updated_at: picked.updated_at,
      p_unit_id: unitId,
      p_replace_installed_valve_id: valve.id,
      p_emergency: emergency,
      p_notes: notes.trim() || null,
    })
    if (err) { setError(err); return }
    onDone()
  }

  const spec = [sizeText(valve.size_type, valve.inlet_size, valve.outlet_size), valve.manufacturer].filter(Boolean).join(' · ')

  return (
    <section aria-label="Replace this valve" className="mt-3 flex flex-col gap-2 border-t pt-3">
      <h3 className="text-sm font-semibold">Replace serial {valve.serial_number ?? '(none)'} from the store</h3>
      <p className="text-xs text-muted-foreground">
        Same set pressure (<Pressure v={valve} />){spec ? <>, {spec}</> : null}. The old valve goes to the SRV Log until it comes back.
      </p>

      {valve.unit_id ? null : (
        <div className="flex flex-wrap gap-2">
          {valve.station_id ? null : (
            <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Station
              <select className={cn(field, 'min-w-48')} dir="auto" value={stationId ?? ''}
                      onChange={(e) => { setStationId(e.target.value || null); setUnitId(null) }}>
                <option value="">Choose a Station…</option>
                {stations.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
              </select>
            </label>
          )}
          <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Unit (this valve has none recorded)
            <select className={cn(field, 'min-w-40')} dir="auto" value={unitId ?? ''} disabled={!stationId}
                    onChange={(e) => setUnitId(e.target.value || null)}>
              <option value="">Choose a Unit…</option>
              {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
            </select>
          </label>
        </div>
      )}

      <div className="flex flex-wrap gap-4 text-sm">
        {valve.manufacturer ? (
          <label className="flex items-center gap-2">
            <input type="checkbox" checked={sameMaker} onChange={(e) => { setSameMaker(e.target.checked); setChosen('') }} />
            Same manufacturer only
          </label>
        ) : null}
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={includeNew} onChange={(e) => { setIncludeNew(e.target.checked); setChosen('') }} />
          Include new valves
        </label>
      </div>

      {stock.status === 'loading' ? <LoadingState label="Finding matching valves in the store" /> : null}
      {stock.status === 'error' ? <p role="alert" className="text-sm text-destructive">{stock.message}</p> : null}
      {stock.status === 'ready' && matches.length === 0 ? (
        <p className="rounded border px-3 py-3 text-sm text-muted-foreground">
          No {includeNew ? 'calibrated or new' : 'calibrated'} valve in the store matches.
          {sameMaker ? ' Try without "Same manufacturer only".' : ''}{includeNew ? '' : ' Try "Include new valves".'}
        </p>
      ) : null}
      {matches.length > 0 ? (
        <fieldset className="flex max-h-72 flex-col gap-1 overflow-y-auto rounded border p-2">
          <legend className="px-1 text-xs text-muted-foreground">{matches.length} matching in the store — choose one</legend>
          {matches.map((s) => (
            <label key={s.id} className={cn('flex flex-wrap items-center gap-x-3 gap-y-1 rounded px-1 py-1 text-sm hover:bg-muted', chosen === s.id && 'bg-muted')}>
              <input type="radio" name={`replace-${valve.id}`} value={s.id} checked={chosen === s.id} onChange={() => setChosen(s.id)} />
              <span className="font-technical">{s.serial_number ?? <NullValue />}</span>
              <Code value={s.warehouse_code} />
              <Pressure v={s} />
              <ValveSize v={s} />
              <span>{s.manufacturer ?? <NullValue />}</span>
              <span className="text-xs text-muted-foreground">
                {s.availability_status ? AVAILABILITY_LABEL[s.availability_status] ?? s.availability_status : null}
                {s.next_calibration_display ? ` · next calibration ${s.next_calibration_display}` : ''}
              </span>
            </label>
          ))}
        </fieldset>
      ) : null}

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={emergency} onChange={(e) => setEmergency(e.target.checked)} />
        Emergency
      </label>
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">Notes
        <input className={field} dir="auto" value={notes} onChange={(e) => setNotes(e.target.value)} />
      </label>
      <FormMessage error={error} />
      <div className="flex gap-2">
        <Button size="sm" disabled={!picked || !unitId || busy} onClick={() => void confirm()}>
          {busy ? 'Replacing…' : 'Confirm replacement'}
        </Button>
        <Button size="sm" variant="ghost" onClick={onCancel} disabled={busy}>Cancel</Button>
      </div>
    </section>
  )
}
