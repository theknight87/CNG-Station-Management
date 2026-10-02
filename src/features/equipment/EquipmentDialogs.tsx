import { useState } from 'react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { useStations, useUnits } from '@/features/admin/useMappingOptions'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { cn } from '@/lib/utils'
import { KINDS, STORE_STATES, type EquipmentKind, type StoreState } from './equipmentKinds'
import { useEquipmentHistory, useReplacementCandidates, type StockRow } from './useEquipmentWorkflow'

const fieldLabel = 'flex flex-col gap-0.5 text-xs text-muted-foreground'
const input = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

/** A non-negative number, or null for an empty box; undefined when what was typed is not a number. */
function numberOrNull(v: string): number | null | undefined {
  if (!v.trim()) return null
  const n = Number(v)
  return Number.isFinite(n) && n >= 0 ? n : undefined
}

/**
 * Admin: add items to the warehouse — one per serial (one per line), or a quantity when they have no serial yet.
 * cng_equipment_stock_add derives the actor, audits, and refuses a serial already in the store. A next date is
 * recorded only when given; nothing is computed from an interval.
 */
export function AddStockDialog({ kind, onClose, onAdded }: { kind: EquipmentKind; onClose: () => void; onAdded: () => void }) {
  const spec = KINDS[kind]
  const [availability, setAvailability] = useState<StoreState>('available_new')
  const [serials, setSerials] = useState('')
  const [quantity, setQuantity] = useState('')
  const [manufacturer, setManufacturer] = useState('')
  const [model, setModel] = useState('')
  const [description, setDescription] = useState('')
  const [working, setWorking] = useState('')
  const [test, setTest] = useState('')
  const [unit, setUnit] = useState<'BAR' | 'PSI'>('BAR')
  const [code, setCode] = useState('')
  const [last, setLast] = useState('')
  const [next, setNext] = useState('')
  const [notes, setNotes] = useState('')
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)

  const serialList = serials.split(/[\n,]+/).map((s) => s.trim()).filter(Boolean)
  const count = serialList.length || Number(quantity) || 0

  async function save() {
    setError(null)
    const w = numberOrNull(working), t = numberOrNull(test)
    if (w === undefined || t === undefined) { setError('Pressures: write one number, e.g. 350.'); return }
    const err = await run('cng_equipment_stock_add', {
      p_kind: kind, p_availability: availability,
      p_serials: serialList.length ? serialList : null, p_quantity: serialList.length ? null : Number(quantity) || null,
      p_manufacturer: manufacturer || null, p_model: kind === 'gas_detector' ? model || null : null,
      p_description: kind === 'hose' ? description || null : null,
      p_working_pressure: kind === 'hose' ? w : null, p_working_unit: kind === 'hose' && w !== null ? unit : null,
      p_test_pressure: kind === 'hose' ? t : null, p_test_unit: kind === 'hose' && t !== null ? unit : null,
      p_last_date: last || null, p_next_date: next || null, p_warehouse_code: code || null, p_notes: notes || null,
    })
    if (err) { setError(err); return }
    onAdded(); onClose()
  }

  return (
    <RecordDetailsDialog open title={`Add ${spec.many} to the warehouse`} description="New purchase, or stock already in the store" onClose={onClose}>
      <div className="grid gap-2 sm:grid-cols-2">
        <label className={fieldLabel}>Condition
          <select className={input} value={availability} onChange={(e) => setAvailability(e.target.value as StoreState)}>
            {STORE_STATES.map((s) => <option key={s} value={s}>{spec.stateLabel[s]}</option>)}
          </select>
        </label>
        <label className={fieldLabel}>Warehouse code
          <input className={input} value={code} onChange={(e) => setCode(e.target.value)} />
        </label>
        <label className={cn(fieldLabel, 'sm:col-span-2')}>Serial numbers (one per line)
          <textarea className="min-h-20 rounded border bg-background px-2 py-1 text-sm text-foreground font-technical" value={serials}
                    onChange={(e) => setSerials(e.target.value)} />
        </label>
        <label className={fieldLabel}>…or quantity with no serial yet
          <input className={input} inputMode="numeric" value={quantity} disabled={serialList.length > 0}
                 onChange={(e) => setQuantity(e.target.value.replace(/\D/g, ''))} />
        </label>
        {kind === 'gas_detector' ? (
          <>
            <label className={fieldLabel}>Manufacturer<input className={input} value={manufacturer} onChange={(e) => setManufacturer(e.target.value)} /></label>
            <label className={fieldLabel}>Model<input className={input} value={model} onChange={(e) => setModel(e.target.value)} /></label>
          </>
        ) : (
          <>
            <label className={fieldLabel}>Description<input className={input} dir="auto" value={description} onChange={(e) => setDescription(e.target.value)} /></label>
            <label className={fieldLabel}>Working pressure<input className={input} inputMode="decimal" value={working} onChange={(e) => setWorking(e.target.value)} /></label>
            <label className={fieldLabel}>Test pressure<input className={input} inputMode="decimal" value={test} onChange={(e) => setTest(e.target.value)} /></label>
            <label className={fieldLabel}>Pressure unit
              <select className={input} value={unit} onChange={(e) => setUnit(e.target.value as 'BAR' | 'PSI')}>
                <option value="BAR">BAR</option><option value="PSI">PSI</option>
              </select>
            </label>
          </>
        )}
        <label className={fieldLabel}>{spec.lastLabel}<input type="date" className={input} value={last} onChange={(e) => setLast(e.target.value)} /></label>
        <label className={fieldLabel}>{spec.nextLabel} (only if known)<input type="date" className={input} value={next} onChange={(e) => setNext(e.target.value)} /></label>
        <label className={cn(fieldLabel, 'sm:col-span-2')}>Notes<input className={input} dir="auto" value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
      </div>
      <FormMessage error={error} />
      <div className="mt-2 flex gap-2">
        <Button size="sm" disabled={busy || count < 1} onClick={() => void save()}>
          {busy ? 'Adding…' : `Add ${count || ''} ${count === 1 ? spec.one : spec.many}`.replace('  ', ' ')}
        </Button>
        <Button size="sm" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
      </div>
    </RecordDetailsDialog>
  )
}

/**
 * Issue (صرف) a store item to a Station, and its Unit when known. The items of this kind already at that Station are
 * offered as the one it replaces; replacing is optional, and the replaced item goes to the Log, still at the station.
 */
export function IssueDialog({ kind, row, onClose, onDone }: { kind: EquipmentKind; row: StockRow; onClose: () => void; onDone: () => void }) {
  const spec = KINDS[kind]
  const stations = useStations()
  const [stationId, setStationId] = useState<string | null>(null)
  const units = useUnits(stationId)
  const [unitId, setUnitId] = useState<string | null>(null)
  const [replace, setReplace] = useState('')
  const [emergency, setEmergency] = useState(false)
  const [notes, setNotes] = useState('')
  const candidates = useReplacementCandidates(kind, stationId, unitId)
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)

  async function submit() {
    setError(null)
    const err = await run('cng_equipment_issue', {
      p_stock_id: row.id, p_expected_updated_at: row.updated_at, p_station_id: stationId, p_unit_id: unitId,
      p_replace_id: replace || null, p_emergency: emergency, p_notes: notes.trim() || null,
    })
    if (err) { setError(err); return }
    onDone(); onClose()
  }

  return (
    <RecordDetailsDialog open title={`Issue ${spec.one} ${row.serial_number ?? ''}`.trim()} description="From the warehouse to a Station" onClose={onClose}>
      <div className="flex flex-col gap-2">
        <div className="flex flex-wrap gap-2">
          <label className={fieldLabel}>Station
            <select className={cn(input, 'min-w-48')} dir="auto" value={stationId ?? ''}
                    onChange={(e) => { setStationId(e.target.value || null); setUnitId(null); setReplace('') }}>
              <option value="">Choose a Station…</option>
              {stations.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </label>
          <label className={fieldLabel}>Unit (if known)
            <select className={cn(input, 'min-w-40')} dir="auto" value={unitId ?? ''} disabled={!stationId}
                    onChange={(e) => { setUnitId(e.target.value || null); setReplace('') }}>
              <option value="">Not known</option>
              {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
            </select>
          </label>
        </div>
        <p className="text-xs text-muted-foreground">The Region is the Station&apos;s Region. A Unit left unknown stays unknown — unless the replaced {spec.one} had one.</p>
        {stationId ? (
          <fieldset className="flex flex-col gap-1">
            <legend className="text-xs text-muted-foreground">The {spec.one} it replaces (installed at this Station)</legend>
            {candidates.status === 'loading' ? <LoadingState label="Loading installed items" /> : null}
            {candidates.status === 'error' ? <p className="text-sm text-destructive">{candidates.message}</p> : null}
            <label className="flex items-center gap-2 text-sm">
              <input type="radio" name="replace" checked={replace === ''} onChange={() => setReplace('')} />
              Do not replace (add it only)
            </label>
            {candidates.status === 'ready' ? candidates.data.map((c) => (
              <label key={c.id} className="flex flex-wrap items-center gap-2 text-sm">
                <input type="radio" name="replace" checked={replace === c.id} onChange={() => setReplace(c.id)} />
                <span className="font-technical">{c.serial_number ?? 'no serial'}</span>
                {c.manufacturer || c.model ? <span>{[c.manufacturer, c.model].filter(Boolean).join(' ')}</span> : null}
                {c.description ? <span dir="auto">{c.description}</span> : null}
                {c.unit_name ? <span dir="auto" className="text-xs text-muted-foreground">{c.unit_name}</span> : null}
              </label>
            )) : null}
          </fieldset>
        ) : null}
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={emergency} onChange={(e) => setEmergency(e.target.checked)} />Emergency
        </label>
        <label className={fieldLabel}>Notes<input className={input} dir="auto" value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
        <FormMessage error={error} />
        <div className="flex gap-2">
          <Button size="sm" disabled={!stationId || busy} onClick={() => void submit()}>{busy ? 'Issuing…' : 'Confirm issue'}</Button>
          <Button size="sm" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
        </div>
      </div>
    </RecordDetailsDialog>
  )
}

/** The certificate step: its date becomes the last calibration / test date; a next date only if the admin gives one. */
export function CertifyDialog({ kind, jobIds, onClose, onDone }: { kind: EquipmentKind; jobIds: string[]; onClose: () => void; onDone: () => void }) {
  const spec = KINDS[kind]
  const [date, setDate] = useState('')
  const [number, setNumber] = useState('')
  const [next, setNext] = useState('')
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  async function submit() {
    setError(null)
    const err = await run('cng_equipment_calibration_certify', {
      p_job_ids: jobIds, p_certificate_date: date, p_certificate_number: number.trim() || null, p_next_date: next || null,
    })
    if (err) { setError(err); return }
    onDone(); onClose()
  }
  return (
    <RecordDetailsDialog open title={`Certificate received (${jobIds.length})`} description={`The ${spec.many} return to the store as ${spec.stateLabel.available_calibrated}`} onClose={onClose}>
      <div className="flex flex-wrap gap-2">
        <label className={fieldLabel}>Certificate date<input type="date" className={input} value={date} onChange={(e) => setDate(e.target.value)} /></label>
        <label className={fieldLabel}>Certificate no.<input className={input} value={number} onChange={(e) => setNumber(e.target.value)} /></label>
        <label className={fieldLabel}>{spec.nextLabel} (only if on the certificate)<input type="date" className={input} value={next} onChange={(e) => setNext(e.target.value)} /></label>
      </div>
      <FormMessage error={error} />
      <div className="mt-2 flex gap-2">
        <Button size="sm" disabled={!date || busy} onClick={() => void submit()}>{busy ? 'Saving…' : 'Save certificate'}</Button>
        <Button size="sm" variant="ghost" onClick={onClose} disabled={busy}>Cancel</Button>
      </div>
    </RecordDetailsDialog>
  )
}

/** Every recorded step of one item, newest first, following it between the store and the station. */
export function ItemHistory({ kind, id }: { kind: EquipmentKind; id: string }) {
  const state = useEquipmentHistory(kind, id)
  return (
    <section aria-label="History" className="mt-3 border-t pt-2">
      <h3 className="mb-1 text-sm font-semibold">History</h3>
      {state.status === 'loading' ? <LoadingState label="Loading history" /> : null}
      {state.status === 'error' ? <p className="text-sm text-destructive">History could not be loaded: {state.message}</p> : null}
      {state.status === 'ready' && state.data.length === 0 ? <p className="text-sm text-muted-foreground">No movements recorded yet.</p> : null}
      {state.status === 'ready' && state.data.length > 0 ? (
        <ol className="flex flex-col gap-1 text-sm">
          {state.data.map((e, i) => (
            <li key={i} className="flex gap-2">
              <span className="tabular w-24 shrink-0 text-muted-foreground">{e.occurred_at.slice(0, 10)}</span>
              <span dir="auto">{e.summary}{e.actor_name ? <span className="ml-1 text-xs text-muted-foreground">— {e.actor_name}</span> : null}</span>
            </li>
          ))}
        </ol>
      ) : null}
    </section>
  )
}
