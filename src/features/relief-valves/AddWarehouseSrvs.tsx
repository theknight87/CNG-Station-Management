import { useRef, useState } from 'react'
import { Plus } from 'lucide-react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Button } from '@/components/ui/button'
import { oneYearAfter, parsePressure } from '@/features/record-tools/recordTools'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { DestinationInput } from '@/features/relief-valves/DestinationInput'
import { SerialWhereaboutsNote } from '@/features/relief-valves/SerialWhereaboutsNote'
import { serialKey, useSerialWhereabouts } from '@/features/relief-valves/serialWhereabouts'
import { useDestinationOptions, type Destination } from '@/features/relief-valves/destinationOptions'
import { ValveTemplatePicker } from '@/features/relief-valves/ValveTemplatePicker'
import { useValveTemplates, type ValveTemplate } from '@/features/relief-valves/valveTemplates'

/**
 * Admin: add relief valves to the warehouse from scratch — a new purchase, or stock that is already calibrated or
 * under calibration (owner request 2026-09-28). One row per serial (one per line), or a quantity when the valves have
 * no serial yet. It calls cng_admin_add_warehouse_srvs: actor derived server-side, audited, a serial already in stock
 * refused. The warehouse code follows the condition (mb 9 new, mbc 9 calibrated, mbu 9 under calibration) by the
 * existing database rule, so the base code is enough. Installing a valve at a station stays the issue (صرف) step.
 * Typing the manufacturer and set pressure fills part number, size and base code from valves already recorded with
 * the same two (owner request 2026-10-04): one combination fills untouched fields by itself, several are offered.
 * A destination (Station or Unit) is optional: one for all the valves, and any serial may carry its own (owner
 * request 2026-10-04); the database derives the Region and refuses a Unit of another Station.
 * The condition starts unchosen and must be picked (owner request 2026-10-04). Each typed serial shows where it already
 * is in the system; one installed, in the store, at calibration or awaiting return cannot be added (the database
 * refuses it too), while a store-sheet row that only says it was sent to a station is closed when the valve is added.
 */

const field = 'flex flex-col gap-0.5 text-xs text-muted-foreground'
const input = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

export function AddWarehouseSrvsButton({ onAdded }: { onAdded: () => void }) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(false)
  if (!isAdmin) return null
  return (
    <>
      <Button size="sm" className="h-7" onClick={() => setOpen(true)}>
        <Plus className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Add relief valves
      </Button>
      {open ? <AddDialog onClose={() => setOpen(false)} onAdded={onAdded} /> : null}
    </>
  )
}

function AddDialog({ onClose, onAdded }: { onClose: () => void; onAdded: () => void }) {
  const [availability, setAvailability] = useState('')
  const [serials, setSerials] = useState('')
  const [quantity, setQuantity] = useState('')
  const [manufacturer, setManufacturer] = useState('')
  const [partNumber, setPartNumber] = useState('')
  const [sizeType, setSizeType] = useState('Male')
  const [inlet, setInlet] = useState('')
  const [outlet, setOutlet] = useState('')
  const [pressure, setPressure] = useState('')
  const [unit, setUnit] = useState('BAR')
  const [code, setCode] = useState('')
  const [lastCal, setLastCal] = useState('')
  const [notes, setNotes] = useState('')
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  // A destination: chosen, null (none) or undefined (text that matches no Station or Unit — not saved).
  const destinations = useDestinationOptions()
  const [allDest, setAllDest] = useState<Destination | null | undefined>(null)
  const [rowDest, setRowDest] = useState<Record<string, Destination | null | undefined>>({})

  const serialList = serials.split(/[\n,]+/).map((s) => s.trim()).filter(Boolean)
  const pressureValue = parsePressure(pressure)
  const count = serialList.length || Number(quantity) || 0
  const where = useSerialWhereabouts(serialList)

  // Fields the user typed are never overwritten by the automatic fill; a chosen version fills everything it carries.
  const touched = useRef(new Set<string>())
  const [filled, setFilled] = useState<ValveTemplate | null>(null)
  const typed = (k: string, set: (v: string) => void) => (v: string) => { touched.current.add(k); set(v) }
  function fill(t: ValveTemplate, force: boolean) {
    const put = (k: string, v: string | null, set: (v: string) => void) => {
      if (v !== null && (force || !touched.current.has(k))) set(v)
    }
    put('part_number', t.part_number, setPartNumber)
    put('size_type', t.size_type && ['male', 'female', 'flange'].includes(t.size_type.toLowerCase())
      ? t.size_type[0].toUpperCase() + t.size_type.slice(1).toLowerCase() : null, setSizeType)
    put('inlet', t.inlet_size, setInlet)
    put('outlet', t.outlet_size, setOutlet)
    put('code', t.base_code, setCode)
    setFilled(t)
  }
  const templates = useValveTemplates(manufacturer, pressureValue, unit, (list) => {
    setFilled(null)
    if (list.length === 1) fill(list[0], false)
  })

  async function save() {
    setError(null); setDone(null)
    if (!availability) { setError('Condition: choose New, Calibrated or Under calibration.'); return }
    if (where.blocked.length) { setError(`Already recorded in the system: ${where.blocked.join(', ')} — see where beside each serial.`); return }
    if (pressureValue === undefined) { setError('Set pressure: write one number, e.g. 275.'); return }
    if (allDest === undefined || serialList.some((s) => s in rowDest && rowDest[s] === undefined)) {
      setError('Destination: choose a Station or Unit from the list, or leave it empty.'); return
    }
    const ownDest = serialList.some((s) => rowDest[s])
    const err = await run('cng_admin_add_warehouse_srvs', {
      p: {
        availability, serials: serialList, quantity: serialList.length ? null : Number(quantity) || null,
        manufacturer, part_number: partNumber, size_type: sizeType, inlet_size: inlet, outlet_size: outlet,
        // One set pressure, no range; next calibration one year after the last (owner ruling 2026-09-29).
        pressure_min: pressureValue ?? null, pressure_max: pressureValue ?? null, pressure_unit: pressureValue == null ? null : unit,
        warehouse_code: code, last_calibration_date: lastCal || null, next_calibration_date: lastCal ? oneYearAfter(lastCal) : null, notes,
        station_id: allDest?.station_id ?? null, unit_id: allDest?.unit_id ?? null,
        ...(ownDest ? { items: serialList.map((s) => ({ serial: s, station_id: rowDest[s]?.station_id ?? null, unit_id: rowDest[s]?.unit_id ?? null })) } : {}),
      },
    })
    if (err) { setError(err); return }
    setDone(`${count} relief valve(s) added to the warehouse.`)
    onAdded()
    setSerials(''); setQuantity(''); setRowDest({})
  }

  return (
    <RecordDetailsDialog open title="Add relief valves to the warehouse" size="wide"
                         description="Everything you type is stored as typed; anything left empty stays empty." onClose={onClose}
                         actions={<>
                           <Button size="sm" variant="outline" onClick={onClose}>Close</Button>
                           <Button size="sm" disabled={busy || count < 1 || !availability || where.blocked.length > 0} onClick={() => void save()}>
                             {busy ? 'Saving…' : `Add ${count || ''} valve${count === 1 ? '' : 's'}`}
                           </Button>
                         </>}>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <label className={field}>Condition
          <select className={input} value={availability} aria-invalid={!availability} onChange={(e) => setAvailability(e.target.value)}>
            <option value="" disabled>Choose the condition…</option>
            <option value="available_new">New (purchased)</option>
            <option value="available_calibrated">Calibrated</option>
            <option value="available_in_store_uc">Under calibration (UC)</option>
          </select>
        </label>
        <label className={field}>Manufacturer
          <input className={input} value={manufacturer} list="add-srv-makers" onChange={(e) => setManufacturer(e.target.value)} />
          <datalist id="add-srv-makers">
            {['Anderson', 'Aspro', 'COI', 'DK-LOK', 'EKC', 'Farinola', 'Mercer', 'TAKEI', 'Taylor', 'Technical', 'Tyco Anderson']
              .map((m) => <option key={m} value={m} />)}
          </datalist>
        </label>
        <div className="flex gap-2">
          <label className={`${field} flex-1`}>Set pressure
            <input inputMode="decimal" className={`${input} text-right tabular`} value={pressure} placeholder="275"
                   onChange={(e) => setPressure(e.target.value.replace(/[^\d.]/g, ''))} />
          </label>
          <label className={field}>Unit
            <select className={input} value={unit} onChange={(e) => setUnit(e.target.value)}>
              <option value="BAR">BAR</option>
              <option value="PSI">PSI</option>
            </select>
          </label>
        </div>
        <label className={field}>Last calibration
          <input type="date" className={input} value={lastCal} onChange={(e) => setLastCal(e.target.value)} />
        </label>
        <div className="sm:col-span-2 lg:col-span-4">
          <ValveTemplatePicker {...templates} filled={filled} onPick={(t) => fill(t, true)} />
        </div>
        <label className={field}>Part number
          <input className={input} value={partNumber} onChange={(e) => typed('part_number', setPartNumber)(e.target.value)} />
        </label>
        <label className={field}>Warehouse code (base, e.g. mb 9)
          <input className={input} value={code} onChange={(e) => typed('code', setCode)(e.target.value)} />
        </label>
        <label className={field}>Size type
          <select className={input} value={sizeType} onChange={(e) => typed('size_type', setSizeType)(e.target.value)}>
            <option value="Male">Male (M)</option>
            <option value="Female">Female (F)</option>
            <option value="Flange">Flange</option>
            <option value="">Not recorded</option>
          </select>
        </label>
        <label className={field}>Inlet
          <input className={input} value={inlet} placeholder={'1/2"'} onChange={(e) => typed('inlet', setInlet)(e.target.value)} />
        </label>
        <label className={field}>Outlet
          <input className={input} value={outlet} placeholder={'3/4"'} onChange={(e) => typed('outlet', setOutlet)(e.target.value)} />
        </label>
        <p className="self-end pb-2 text-xs text-muted-foreground">Next calibration: one year after the last, set automatically.</p>
        <label className={`${field} sm:col-span-2`}>Notes
          <input dir="auto" className={input} value={notes} onChange={(e) => setNotes(e.target.value)} />
        </label>
        <label className={`${field} sm:col-span-2 lg:col-span-3`}>Serials — one per line (or separated by commas)
          <textarea className="min-h-24 rounded border bg-background px-2 py-1 font-technical text-sm text-foreground" value={serials}
                    onChange={(e) => setSerials(e.target.value)} />
        </label>
        <label className={field}>…or a quantity without serials
          <input inputMode="numeric" className={input} value={quantity} disabled={serialList.length > 0}
                 onChange={(e) => setQuantity(e.target.value.replace(/\D/g, ''))} />
        </label>
        <div className="flex flex-col gap-1 sm:col-span-2 lg:col-span-4">
          <span className="text-xs text-muted-foreground">Destination for all these valves — Station or Unit (optional)</span>
          <DestinationInput options={destinations} value={allDest ?? null} onChange={setAllDest} label="Destination for all" className="max-w-md" />
        </div>
        {serialList.length > 0 ? (
          <div className="flex flex-col gap-1 sm:col-span-2 lg:col-span-4" role="group" aria-label="Destination per serial">
            <span className="text-xs text-muted-foreground">Where each serial is now, and a Station or Unit for any serial (empty takes the one above)</span>
            <ul className="flex flex-col gap-1">
              {serialList.map((s) => (
                <li key={s} className="grid items-start gap-2 sm:grid-cols-[12rem_minmax(0,28rem)]">
                  <div className="flex flex-col gap-0.5 pt-1.5">
                    <span className="font-technical text-sm" dir="ltr">{s}</span>
                    <SerialWhereaboutsNote places={where.found.get(serialKey(s))} closes />
                  </div>
                  <DestinationInput options={destinations} value={rowDest[s] ?? null} label={`Destination for ${s}`}
                                    onChange={(d) => setRowDest((p) => ({ ...p, [s]: d }))} />
                </li>
              ))}
            </ul>
          </div>
        ) : null}
        <div className="sm:col-span-2 lg:col-span-4"><FormMessage error={error} done={done} /></div>
      </div>
    </RecordDetailsDialog>
  )
}
