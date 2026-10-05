import { Fragment, useRef, useState } from 'react'
import { Plus } from 'lucide-react'

import { cn } from '@/lib/utils'

import { oneYearAfter, parsePressure } from '@/features/record-tools/recordTools'
import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Button } from '@/components/ui/button'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import { SerialWhereaboutsNote } from '@/features/relief-valves/SerialWhereaboutsNote'
import { serialKey, useSerialWhereabouts } from '@/features/relief-valves/serialWhereabouts'
import { ValveTemplatePicker } from '@/features/relief-valves/ValveTemplatePicker'
import { VALVE_MANUFACTURERS, calibratedCode, useValveTemplates, type ValveTemplate } from '@/features/relief-valves/valveTemplates'

/**
 * Admin: add a piece of equipment to a Unit from its popup (owner request 2026-09-28, suggestion 3).
 * Calls cng_admin_add_unit_asset: Station and Region come from the Unit, status is derived, the actor is the server's.
 */

export type AssetKind = 'srv' | 'storage_vessel' | 'recovery_tank' | 'gas_detector' | 'dispenser' | 'hose' | 'compressor'

type FieldType = 'text' | 'number' | 'date' | 'unit' | 'range' | 'size' | 'maker' | 'serials'
interface Field { key: string; label: string; type?: FieldType }

const COMMON_DATES = (what: string): Field[] => [
  { key: 'last_date', label: `Last ${what}`, type: 'date' },
  { key: 'next_date', label: `Next ${what}`, type: 'date' },
]

/** Relief valves and gas detectors: next calibration is always one year after the last, so it is never typed. */
const ANNUAL_DATES: Field[] = [{ key: 'last_date', label: 'Last calibration', type: 'date' }]

const FIELDS: Record<AssetKind, { title: string; fields: Field[]; note?: string }> = {
  srv: {
    title: 'relief valve',
    note: 'Installed on this Unit. Which compressor, vessel or dispenser it sits on is left for mapping — never guessed. Next calibration is set to one year after the last.',
    // Manufacturer and set pressure first: they fill the rest from valves already recorded (owner request 2026-10-04).
    fields: [
      // Several serials at once (owner request 2026-10-05): one valve per serial, the other fields shared.
      { key: 'manufacturer', label: 'Manufacturer', type: 'maker' }, { key: 'pressure', label: 'Set pressure', type: 'number' },
      { key: 'pressure_unit', label: 'Unit', type: 'unit' },
      { key: 'part_number', label: 'Part number' }, { key: 'size_type', label: 'Size type', type: 'size' },
      { key: 'inlet_size', label: 'Inlet' }, { key: 'outlet_size', label: 'Outlet' },
      { key: 'warehouse_code', label: 'Warehouse code' }, ...ANNUAL_DATES, { key: 'notes', label: 'Notes' },
      { key: 'serial_number', label: 'Serials — one per line (or separated by commas)', type: 'serials' },
    ],
  },
  storage_vessel: { title: 'storage vessel', note: 'Storage belongs to the Station: the vessel is recorded at Station level and shown under every Unit of this Station.', fields: [
    { key: 'serial_number', label: 'Serial' }, { key: 'manufacturer', label: 'Manufacturer' }, { key: 'model', label: 'Model' },
    ...COMMON_DATES('inspection'), { key: 'notes', label: 'Notes' }] },
  recovery_tank: { title: 'recovery tank', fields: [
    { key: 'serial_number', label: 'Serial' }, { key: 'manufacturer', label: 'Manufacturer' }, { key: 'model', label: 'Model' },
    ...COMMON_DATES('inspection'), { key: 'notes', label: 'Notes' }] },
  gas_detector: { title: 'gas detector', note: 'Next calibration is set to one year after the last.', fields: [
    { key: 'serial_number', label: 'Serial' }, { key: 'manufacturer', label: 'Manufacturer' }, { key: 'model', label: 'Model' },
    ...ANNUAL_DATES, { key: 'notes', label: 'Notes' }] },
  dispenser: { title: 'dispenser', fields: [
    { key: 'dispenser_name', label: 'Dispenser name' }, { key: 'manufacturer', label: 'Manufacturer' }, { key: 'model', label: 'Model' },
    { key: 'serial_number', label: 'Serial' }, { key: 'number_of_hoses', label: 'Number of hoses', type: 'number' }, { key: 'notes', label: 'Notes' }] },
  hose: { title: 'hose', fields: [
    { key: 'description', label: 'Description' }, { key: 'serial_number', label: 'Serial' },
    { key: 'working_pressure_value', label: 'Working pressure', type: 'number' }, { key: 'working_pressure_unit', label: 'Unit', type: 'unit' },
    { key: 'test_pressure_value', label: 'Test pressure', type: 'number' }, { key: 'test_pressure_unit', label: 'Unit', type: 'unit' },
    ...COMMON_DATES('test'), { key: 'notes', label: 'Notes' }] },
  compressor: { title: 'compressor', fields: [
    { key: 'manufacturer', label: 'Manufacturer' }, { key: 'model', label: 'Model' }, { key: 'serial_number', label: 'Serial' },
    { key: 'job_number', label: 'Job number' }, { key: 'part_number', label: 'Part number' },
    { key: 'total_running_hours', label: 'Running hours', type: 'number' }, { key: 'notes', label: 'Notes' }] },
}

const input = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

/** Serials typed one per line or separated by commas, trimmed, blanks dropped. */
function splitSerials(text: string): string[] {
  return text.split(/[\n,]+/).map((x) => x.trim()).filter(Boolean)
}

export function AddUnitAssetButton({ kind, unitId, unitName, onAdded }: { kind: AssetKind; unitId: string; unitName: string; onAdded: () => void }) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(false)
  if (!isAdmin) return null
  return (
    <>
      <Button size="sm" variant="outline" className="h-7" onClick={() => setOpen(true)}>
        <Plus className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Add {FIELDS[kind].title}
      </Button>
      {open ? <AddDialog kind={kind} unitId={unitId} unitName={unitName} onClose={() => setOpen(false)} onAdded={onAdded} /> : null}
    </>
  )
}

function AddDialog({ kind, unitId, unitName, onClose, onAdded }: {
  kind: AssetKind; unitId: string; unitName: string; onClose: () => void; onAdded: () => void
}) {
  const spec = FIELDS[kind]
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(spec.fields.map((f) => [f.key, f.type === 'unit' ? 'BAR' : f.type === 'size' ? 'Male' : ''])))
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  const set = (k: string, v: string) => setValues((p) => ({ ...p, [k]: v }))

  // A relief valve fills part number, size and code from valves of the same manufacturer and set pressure; fields the
  // user typed are never overwritten by the automatic fill, a chosen version fills everything it carries.
  const touched = useRef(new Set<string>())
  const [filled, setFilled] = useState<ValveTemplate | null>(null)
  function fill(t: ValveTemplate, force: boolean) {
    const size = t.size_type && ['male', 'female', 'flange'].includes(t.size_type.toLowerCase())
      ? t.size_type[0].toUpperCase() + t.size_type.slice(1).toLowerCase() : null
    const next: Record<string, string | null> = {
      part_number: t.part_number, size_type: size, inlet_size: t.inlet_size, outlet_size: t.outlet_size,
      // An installed valve is a calibrated one, so its code carries the C (owner code rule).
      warehouse_code: calibratedCode(t.base_code),
    }
    setValues((p) => {
      const out = { ...p }
      for (const [k, v] of Object.entries(next)) if (v !== null && (force || !touched.current.has(k))) out[k] = v
      return out
    })
    setFilled(t)
  }
  const templates = useValveTemplates(kind === 'srv' ? values.manufacturer ?? '' : '', parsePressure(values.pressure ?? ''),
    values.pressure_unit ?? 'BAR', (list) => {
      setFilled(null)
      if (list.length === 1) fill(list[0], false)
    })

  // A relief valve's serial already somewhere in the system is shown, and refused (owner request 2026-10-04).
  const serialList = kind === 'srv' ? splitSerials(values.serial_number ?? '') : []
  const where = useSerialWhereabouts(serialList)
  const twice = serialList.filter((x, i) => serialList.findIndex((y) => serialKey(y) === serialKey(x)) !== i)
  const label = kind === 'srv' && serialList.length > 1 ? `${serialList.length} relief valves` : spec.title

  async function save() {
    setError(null)
    if (where.blocked.length) { setError(`Already recorded in the system: ${where.blocked.join(', ')}.`); return }
    if (twice.length) { setError(`The same serial is typed more than once: ${twice.join(', ')}.`); return }
    const p: Record<string, unknown> = { ...values }
    if ('pressure' in values) {
      // One set pressure, no range (owner ruling 2026-09-29).
      const value = parsePressure(values.pressure)
      if (value === undefined) { setError('Set pressure: write one number, e.g. 275.'); return }
      delete p.pressure
      p.pressure_min = value
      p.pressure_max = value
      if (value === null) p.pressure_unit = null
    }
    if (kind === 'srv' || kind === 'gas_detector') p.next_date = values.last_date ? oneYearAfter(values.last_date) : null
    // A unit beside an empty value would record a unit for nothing.
    if ('working_pressure_value' in values && !values.working_pressure_value.trim()) p.working_pressure_unit = null
    if ('test_pressure_value' in values && !values.test_pressure_value.trim()) p.test_pressure_unit = null
    // One or more serials: one valve each, in one all-or-nothing call. No serial: one valve without a serial.
    const err = serialList.length
      ? await run('cng_admin_add_unit_srvs', { p_unit_id: unitId, p: { ...p, serial_number: undefined }, p_serials: serialList })
      : await run('cng_admin_add_unit_asset', { p_kind: kind, p_unit_id: unitId, p })
    if (err) { setError(err); return }
    onAdded(); onClose()
  }

  return (
    <RecordDetailsDialog open title={`Add ${spec.title}`} description={`To ${unitName}. Anything left empty stays empty.`} onClose={onClose}
                         actions={<>
                           <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
                           <Button size="sm" disabled={busy || where.blocked.length > 0 || twice.length > 0} onClick={() => void save()}>{busy ? 'Saving…' : `Add ${label}`}</Button>
                         </>}>
      <div className="flex flex-col gap-3">
        {spec.note ? <p className="text-xs text-muted-foreground">{spec.note}</p> : null}
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {spec.fields.map((f) => (
            <Fragment key={f.key}>
            <label className={cn('flex flex-col gap-0.5 text-xs text-muted-foreground', f.type === 'serials' && 'sm:col-span-2 lg:col-span-3')}>
              {f.label}
              {f.type === 'serials' ? (
                <textarea dir="ltr" className="min-h-20 rounded border bg-background px-2 py-1 font-technical text-sm text-foreground"
                          value={values[f.key]} onChange={(e) => set(f.key, e.target.value)} />
              ) : f.type === 'maker' ? (
                <>
                  <input className={input} value={values[f.key]} list={`add-${kind}-makers`}
                         onChange={(e) => { touched.current.add(f.key); set(f.key, e.target.value) }} />
                  <datalist id={`add-${kind}-makers`}>{VALVE_MANUFACTURERS.map((m) => <option key={m} value={m} />)}</datalist>
                </>
              ) : f.type === 'unit' ? (
                <select className={input} value={values[f.key]} onChange={(e) => set(f.key, e.target.value)}>
                  <option value="BAR">BAR</option><option value="PSI">PSI</option>
                </select>
              ) : f.type === 'size' ? (
                <select className={input} value={values[f.key]} onChange={(e) => { touched.current.add(f.key); set(f.key, e.target.value) }}>
                  <option value="Male">Male (M)</option><option value="Female">Female (F)</option>
                  <option value="Flange">Flange</option><option value="">Not recorded</option>
                </select>
              ) : (
                <input dir="auto" className={input} value={values[f.key]}
                       type={f.type === 'date' ? 'date' : 'text'} inputMode={f.type === 'number' || f.type === 'range' ? 'decimal' : undefined}
                       onChange={(e) => { touched.current.add(f.key); set(f.key, f.type === 'number' ? e.target.value.replace(/[^\d.]/g, '')
                         : f.type === 'range' ? e.target.value.replace(/[^\d.\-– ]/g, '') : e.target.value) }} />
              )}
              {f.type === 'serials' && serialList.length ? (
                <ul aria-label="Where each serial is now" className="flex flex-col gap-0.5">
                  {serialList.map((x, i) => (
                    <li key={`${x}-${i}`} className="flex flex-wrap items-baseline gap-x-2">
                      <span className="font-technical text-foreground" dir="ltr">{x}</span>
                      {twice.includes(x) && serialList.findIndex((y) => serialKey(y) === serialKey(x)) !== i
                        ? <span className="text-destructive" role="alert">typed twice</span>
                        : <SerialWhereaboutsNote places={where.found.get(serialKey(x))} />}
                    </li>
                  ))}
                </ul>
              ) : null}
            </label>
            {kind === 'srv' && f.key === 'pressure_unit' ? (
              <div className="sm:col-span-2 lg:col-span-3">
                <ValveTemplatePicker {...templates} filled={filled} onPick={(t) => fill(t, true)} />
              </div>
            ) : null}
            </Fragment>
          ))}
        </div>
        <FormMessage error={error} done={null} />
      </div>
    </RecordDetailsDialog>
  )
}
