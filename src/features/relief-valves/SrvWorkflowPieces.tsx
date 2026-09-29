import { useState, type ReactNode } from 'react'

import { NullValue } from '@/components/data/NullValue'
import { Identifier } from '@/components/data/TechnicalText'
import { Button } from '@/components/ui/button'
import { ErrorState, LoadingState } from '@/components/states/AppStates'
import { useStations, useUnits } from '@/features/admin/useMappingOptions'
import { PressureRange } from '@/features/units/assetDisplay'
import type { WarehouseSrvRow } from '@/features/relief-valves/useSrvManagement'
import {
  sizeText, useIsAdmin, useReplacementCandidates, useValveHistory, useWorkflowAction, type ValveFields,
} from '@/features/relief-valves/useSrvWorkflow'
import { cn } from '@/lib/utils'
import { compareValues, type SortValue } from '@/features/relief-valves/srvSort'

export function ValveSize({ v }: { v: Pick<ValveFields, 'size_type' | 'inlet_size' | 'outlet_size'> }) {
  const value = sizeText(v.size_type, v.inlet_size, v.outlet_size)
  return value ? <span className="whitespace-nowrap font-technical">{value}</span> : <NullValue />
}

export function Pressure({ v }: { v: Pick<ValveFields, 'pressure_min' | 'pressure_max' | 'pressure_unit' | 'set_pressure_raw'> }) {
  return <PressureRange min={v.pressure_min} max={v.pressure_max} unit={v.pressure_unit} raw={v.set_pressure_raw} />
}

export function Code({ value }: { value: string | null }) {
  return value ? <Identifier value={value} /> : <NullValue />
}

export function FormMessage({ error, done }: { error: string | null; done?: string | null }) {
  if (error) return <p role="alert" className="text-sm text-destructive">{error}</p>
  if (done) return <p role="status" className="text-sm text-muted-foreground">{done}</p>
  return null
}

function day(ts: string | null): string {
  return ts ? ts.slice(0, 10) : ''
}

/** Every recorded step of this valve, newest first, following it between warehouse and station. */
export function ValveHistory({ valveId }: { valveId: string }) {
  const state = useValveHistory(valveId)
  return (
    <section aria-label="Valve history" className="mt-3 border-t pt-2">
      <h3 className="mb-1 text-sm font-semibold">History</h3>
      {state.status === 'loading' ? <LoadingState label="Loading history" /> : null}
      {state.status === 'error' ? <p className="text-sm text-destructive">History could not be loaded: {state.message}</p> : null}
      {state.status === 'ready' && state.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">No movements recorded for this valve yet.</p>
      ) : null}
      {state.status === 'ready' && state.data.length > 0 ? (
        <ol className="flex flex-col gap-1 text-sm">
          {state.data.map((e, i) => (
            <li key={i} className="flex gap-2">
              <span className="tabular w-24 shrink-0 text-muted-foreground">{day(e.occurred_at)}</span>
              <span dir="auto">
                {e.summary}
                {e.actor_name ? <span className="ml-1 text-xs text-muted-foreground">— {e.actor_name}</span> : null}
                {e.from_source ? <span className="ml-1 text-xs text-muted-foreground">(from the source workbook)</span> : null}
              </span>
            </li>
          ))}
        </ol>
      ) : null}
    </section>
  )
}

const field = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

/**
 * Issue (صرف) a store valve to a Region / Station / Unit. After the Unit is chosen, the valves at that
 * Station with the same set pressure are offered as the one it replaces; replacing is optional.
 */
export function IssuePanel({ row, onDone, startOpen = false, onCancel }: {
  row: WarehouseSrvRow
  onDone: () => void
  /** Open straight on the form (the table's issue button), not on the "Issue from warehouse" button. */
  startOpen?: boolean
  /** Cancel leaves the panel entirely (closes the dialog it sits in) instead of folding it. */
  onCancel?: () => void
}) {
  const isAdmin = useIsAdmin()
  const stations = useStations()
  const [stationId, setStationId] = useState<string | null>(null)
  const units = useUnits(stationId)
  const [unitId, setUnitId] = useState<string | null>(null)
  const [replace, setReplace] = useState<string>('')
  const [emergency, setEmergency] = useState(false)
  const [notes, setNotes] = useState('')
  const [open, setOpen] = useState(startOpen)
  const [error, setError] = useState<string | null>(null)
  const candidates = useReplacementCandidates(unitId, row.id)
  const { run, busy } = useWorkflowAction()

  if (!isAdmin) return null
  if (row.availability_status !== 'available_new' && row.availability_status !== 'available_calibrated') {
    return (
      <p className="mt-3 border-t pt-2 text-sm text-muted-foreground">
        Only a new or calibrated valve can be issued. This one is under calibration.
      </p>
    )
  }
  if (!open) {
    return (
      <div className="mt-3 border-t pt-2">
        <Button size="sm" onClick={() => setOpen(true)}>Issue from warehouse</Button>
      </div>
    )
  }

  async function submit() {
    setError(null)
    const err = await run('cng_srv_issue', {
      p_warehouse_valve_id: row.id,
      p_expected_updated_at: row.updated_at,
      p_unit_id: unitId,
      p_replace_installed_valve_id: replace || null,
      p_emergency: emergency,
      p_notes: notes.trim() || null,
    })
    if (err) setError(err)
    else onDone()
  }

  return (
    <section aria-label="Issue from warehouse" className="mt-3 flex flex-col gap-2 border-t pt-2">
      <h3 className="text-sm font-semibold">Issue from warehouse</h3>
      <div className="flex flex-wrap gap-2">
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Station
          <select className={cn(field, 'min-w-48')} dir="auto" value={stationId ?? ''}
                  onChange={(e) => { setStationId(e.target.value || null); setUnitId(null); setReplace('') }}>
            <option value="">Choose a Station…</option>
            {stations.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
          </select>
        </label>
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Unit
          <select className={cn(field, 'min-w-40')} dir="auto" value={unitId ?? ''} disabled={!stationId}
                  onChange={(e) => { setUnitId(e.target.value || null); setReplace('') }}>
            <option value="">Choose a Unit…</option>
            {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
          </select>
        </label>
      </div>
      <p className="text-xs text-muted-foreground">The Region is the Station&apos;s Region.</p>

      {unitId ? (
        <fieldset className="flex flex-col gap-1">
          <legend className="text-xs text-muted-foreground">Valve it replaces (same set pressure, at this Station)</legend>
          {candidates.status === 'loading' ? <LoadingState label="Loading valves at the Station" /> : null}
          {candidates.status === 'error' ? <p className="text-sm text-destructive">{candidates.message}</p> : null}
          <label className="flex items-center gap-2 text-sm">
            <input type="radio" name="replace" value="" checked={replace === ''} onChange={() => setReplace('')} />
            Do not replace a valve (add it only)
          </label>
          {candidates.status === 'ready'
            ? candidates.data.map((c) => (
                <label key={c.id} className="flex flex-wrap items-center gap-2 text-sm">
                  <input type="radio" name="replace" value={c.id} checked={replace === c.id} onChange={() => setReplace(c.id)} />
                  <span className="font-technical">{c.serial_number ?? 'no serial'}</span>
                  <Pressure v={c} />
                  <ValveSize v={c} />
                  {c.warehouse_code ? <Code value={c.warehouse_code} /> : null}
                  {c.location_raw ? <span className="text-xs text-muted-foreground">{c.location_raw}</span> : null}
                  {!c.station_confirmed ? <span className="text-xs text-muted-foreground">(Station from source name)</span> : null}
                </label>
              ))
            : null}
          {candidates.status === 'ready' && candidates.data.length === 0 ? (
            <p className="text-sm text-muted-foreground">No valve with the same set pressure is recorded at this Station.</p>
          ) : null}
        </fieldset>
      ) : null}

      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={emergency} onChange={(e) => setEmergency(e.target.checked)} />
        Emergency
      </label>
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
        Notes
        <input className={field} dir="auto" value={notes} onChange={(e) => setNotes(e.target.value)} />
      </label>
      <FormMessage error={error} />
      <div className="flex gap-2">
        <Button size="sm" disabled={!unitId || busy} onClick={() => void submit()}>
          {busy ? 'Issuing…' : 'Confirm issue'}
        </Button>
        <Button size="sm" variant="ghost" onClick={() => (onCancel ? onCancel() : setOpen(false))} disabled={busy}>Cancel</Button>
      </div>
    </section>
  )
}

/** A workflow table with row checkboxes and select-all. */
export interface SelectableColumn<T> {
  key: string
  header: string
  render: (r: T) => ReactNode
  align?: 'right'
  /** Present = the header sorts by this value (nulls always last). */
  sortValue?: (r: T) => SortValue
  /** Let long text (Station names) wrap instead of widening the table. */
  wrap?: boolean
}

/**
 * A workflow table. Every tab loads its whole (bounded) list, so sorting happens here on the full set:
 * `defaultOrder` until a header is clicked, then that column, click again to reverse.
 */
export function SelectableTable<T extends { id: string }>({
  label, rows, columns, selected, onSelected, selectable, onOpen, defaultOrder,
}: {
  label: string
  rows: T[]
  columns: SelectableColumn<T>[]
  selected: Set<string>
  onSelected: (next: Set<string>) => void
  selectable: (r: T) => boolean
  onOpen?: (r: T) => void
  defaultOrder?: (a: T, b: T) => number
}) {
  const [sort, setSort] = useState<{ key: string; asc: boolean } | null>(null)
  const col = sort ? columns.find((c) => c.key === sort.key && c.sortValue) : undefined
  const ordered = col?.sortValue
    ? [...rows].sort((a, b) => {
        const va = col.sortValue!(a), vb = col.sortValue!(b)
        if (va === null || va === '' || vb === null || vb === '') return compareValues(va, vb)
        return sort!.asc ? compareValues(va, vb) : compareValues(vb, va)
      })
    : defaultOrder ? [...rows].sort(defaultOrder) : rows
  const pickable = rows.filter(selectable)
  const all = pickable.length > 0 && pickable.every((r) => selected.has(r.id))
  return (
    <div className="overflow-x-auto rounded border">
      <table className="w-full text-sm" aria-label={label}>
        <thead className="bg-muted/50 text-xs uppercase tracking-wide text-muted-foreground">
          <tr>
            <th className="w-8 px-2 py-1.5">
              <input type="checkbox" aria-label="Select all" checked={all} disabled={pickable.length === 0}
                     onChange={() => onSelected(all ? new Set() : new Set(pickable.map((r) => r.id)))} />
            </th>
            {columns.map((c) => {
              const active = sort?.key === c.key
              return (
                <th key={c.key} aria-sort={active ? (sort!.asc ? 'ascending' : 'descending') : undefined}
                    className={cn('whitespace-nowrap px-1.5 py-1.5 text-left font-semibold', c.align === 'right' && 'text-right')}>
                  {c.sortValue ? (
                    <button type="button" className="inline-flex items-center gap-1 uppercase tracking-wide hover:text-foreground"
                            onClick={() => setSort(active ? { key: c.key, asc: !sort!.asc } : { key: c.key, asc: true })}>
                      {c.header}<span aria-hidden="true">{active ? (sort!.asc ? '↑' : '↓') : '↕'}</span>
                    </button>
                  ) : c.header}
                </th>
              )
            })}
          </tr>
        </thead>
        <tbody>
          {ordered.map((r) => (
            <tr key={r.id} className={cn('border-t', onOpen && 'cursor-pointer hover:bg-muted/40')} onClick={() => onOpen?.(r)}>
              <td className="px-2 py-1" onClick={(e) => e.stopPropagation()}>
                {selectable(r) ? (
                  <input type="checkbox" aria-label="Select row" checked={selected.has(r.id)}
                         onChange={() => {
                           const next = new Set(selected)
                           if (next.has(r.id)) next.delete(r.id)
                           else next.add(r.id)
                           onSelected(next)
                         }} />
                ) : null}
              </td>
              {columns.map((c) => (
                <td key={c.key} className={cn('px-1.5 py-1 align-middle', c.wrap ? 'min-w-36 break-words' : 'whitespace-nowrap', c.align === 'right' && 'text-right tabular')}>{c.render(r)}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function ListStates({ state, label, reload, empty, children }: {
  state: { status: string; message?: string }
  label: string
  reload: () => void
  empty: boolean
  children: ReactNode
}) {
  if (state.status === 'loading') return <LoadingState label={`Loading ${label}`} />
  if (state.status === 'error') return <ErrorState title={`Could not load ${label}`} message={state.message ?? ''} onRetry={reload} />
  if (empty) return <p className="rounded border px-3 py-6 text-center text-sm text-muted-foreground">Nothing in {label} matches.</p>
  return <>{children}</>
}

export interface CountItem {
  /** The status (or group) this count stands for; clicking it shows those rows. */
  key: string
  label: string
  value: number | null
  hint?: string
  /** Small marker in the same colour as the row's status chip. */
  dot?: string
}

/**
 * A workflow tab's count strip (owner request 2026-09-29): one number per status, under the tab's current filters.
 * Each count is a button that shows its rows; the active one is marked by a border, weight and aria-pressed, never
 * by colour alone. A count that failed to load is left out rather than shown as 0.
 */
export function CountStrip({ label, items, active, onPick, note }: {
  label: string
  items: CountItem[]
  active: string | null
  onPick: (key: string) => void
  note?: string | null
}) {
  return (
    <section aria-label={label} className="rounded border bg-card p-1.5">
      <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-3 lg:grid-cols-5">
        {items.map((it) => {
          const on = active === it.key
          return (
            <button key={it.key} type="button" aria-pressed={on} onClick={() => onPick(it.key)}
                    className={cn(
                      'flex min-w-0 flex-col items-start rounded-md border px-2.5 py-1.5 text-left transition-colors',
                      'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                      on ? 'border-brand-strong bg-background shadow-sm' : 'border-transparent hover:border-border hover:bg-muted/60',
                    )}>
              <span className="flex items-center gap-1.5 text-xs uppercase tracking-wide text-muted-foreground">
                {it.dot ? <span aria-hidden="true" className={cn('h-2 w-2 shrink-0 rounded-full', it.dot)} /> : null}
                {it.label}
              </span>
              <span className={cn('tabular text-xl leading-tight', on ? 'font-bold text-foreground' : 'font-semibold')}>
                {it.value === null ? <NullValue /> : it.value.toLocaleString()}
              </span>
              {it.hint ? <span className="text-xs text-muted-foreground">{it.hint}</span> : null}
            </button>
          )
        })}
      </div>
      {note ? <p className="px-1 pt-1 text-xs text-muted-foreground">{note}</p> : null}
    </section>
  )
}
