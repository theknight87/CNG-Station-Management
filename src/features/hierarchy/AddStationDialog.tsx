import { useState } from 'react'
import { Plus, Trash2 } from 'lucide-react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Button } from '@/components/ui/button'
import { useRegions } from '@/features/hierarchy/useHierarchy'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'

/**
 * Admin: add a Station from scratch, in a Region, with its Units (owner request 2026-09-28).
 * It calls cng_admin_create_station, which derives the actor server-side, audits the creation and refuses a
 * duplicate name. Every field left empty is stored empty — nothing is filled in on the owner's behalf.
 */

interface UnitDraft { unit_name: string; job_number: string; dispensers: string; hoses: string; storage_vessels: string }
const EMPTY_UNIT: UnitDraft = { unit_name: '', job_number: '', dispensers: '', hoses: '', storage_vessels: '' }

const field = 'flex flex-col gap-0.5 text-xs text-muted-foreground'
const input = 'h-8 rounded border bg-background px-2 text-sm text-foreground'

export function AddStationButton({ regionId, onCreated }: { regionId?: string; onCreated: () => void }) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(false)
  if (!isAdmin) return null
  return (
    <>
      <Button size="sm" className="h-7" onClick={() => setOpen(true)}>
        <Plus className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Add Station
      </Button>
      {open ? <AddStationDialog regionId={regionId} onClose={() => setOpen(false)} onCreated={onCreated} /> : null}
    </>
  )
}

function AddStationDialog({ regionId, onClose, onCreated }: { regionId?: string; onClose: () => void; onCreated: () => void }) {
  const regions = useRegions()
  const [region, setRegion] = useState(regionId ?? '')
  const [name, setName] = useState('')
  const [bay, setBay] = useState('')
  const [notes, setNotes] = useState('')
  const [units, setUnits] = useState<UnitDraft[]>([{ ...EMPTY_UNIT }])
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)

  const setUnit = (i: number, patch: Partial<UnitDraft>) => setUnits((prev) => prev.map((u, j) => (j === i ? { ...u, ...patch } : u)))
  const num = (v: string) => (v.trim() === '' ? null : Number(v))

  async function save() {
    setError(null)
    const payload = units
      .filter((u) => u.unit_name.trim())
      .map((u) => ({
        unit_name: u.unit_name.trim(), job_number: u.job_number.trim() || null,
        dispensers: num(u.dispensers), hoses: num(u.hoses), storage_vessels: num(u.storage_vessels),
      }))
    const err = await run('cng_admin_create_station', {
      p_region_id: region, p_station_name: name, p_bay_status: bay || null, p_notes: notes || null, p_units: payload,
    })
    if (err) { setError(err); return }
    onCreated(); onClose()
  }

  const regionName = regions.state.status === 'ready' ? regions.state.data.find((r) => r.region_id === regionId)?.region_name : undefined
  return (
    <RecordDetailsDialog open title="Add Station" size="wide"
                         description="A new Station with its Units. Anything left empty stays empty." onClose={onClose}
                         actions={<>
                           <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
                           <Button size="sm" disabled={busy || !name.trim() || !region} onClick={() => void save()}>
                             {busy ? 'Saving…' : 'Create Station'}
                           </Button>
                         </>}>
      <div className="flex flex-col gap-4">
        <section aria-label="Station" className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <label className={field}>Region
            {regionId ? (
              <input className={input} value={regionName ?? ''} readOnly aria-readonly="true" />
            ) : (
              <select className={input} value={region} onChange={(e) => setRegion(e.target.value)}>
                <option value="">Choose…</option>
                {regions.state.status === 'ready'
                  ? regions.state.data.map((r) => <option key={r.region_id} value={r.region_id}>{r.region_name}</option>)
                  : null}
              </select>
            )}
          </label>
          <label className={field}>Station name
            <input dir="auto" className={input} value={name} onChange={(e) => setName(e.target.value)} />
          </label>
          <label className={field}>Bay status
            <select className={input} value={bay} onChange={(e) => setBay(e.target.value)}>
              <option value="">Not recorded</option>
              <option value="open">Open</option>
              <option value="closed">Closed</option>
            </select>
          </label>
          <label className={field}>Notes
            <input dir="auto" className={input} value={notes} onChange={(e) => setNotes(e.target.value)} />
          </label>
        </section>

        <section aria-label="Units" className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold">Units</h3>
            <Button size="sm" variant="outline" className="h-7" onClick={() => setUnits((p) => [...p, { ...EMPTY_UNIT }])}>
              <Plus className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Add Unit
            </Button>
          </div>
          <p className="text-xs text-muted-foreground">
            A Station may have no Unit; leave the name empty to skip a row. No Unit is ever created for you.
          </p>
          {units.map((u, i) => (
            <div key={i} className="grid items-end gap-2 rounded border p-2 sm:grid-cols-[2fr_1fr_1fr_1fr_1fr_auto]">
              <label className={field}>Unit name
                <input dir="auto" className={input} value={u.unit_name} placeholder={name ? `${name.trim()} ${i + 1}` : ''}
                       onChange={(e) => setUnit(i, { unit_name: e.target.value })} />
              </label>
              <label className={field}>Job number
                <input className={input} value={u.job_number} onChange={(e) => setUnit(i, { job_number: e.target.value })} />
              </label>
              <label className={field}>Dispensers
                <input inputMode="numeric" className={input} value={u.dispensers}
                       onChange={(e) => setUnit(i, { dispensers: e.target.value.replace(/\D/g, '') })} />
              </label>
              <label className={field}>Hoses
                <input inputMode="numeric" className={input} value={u.hoses}
                       onChange={(e) => setUnit(i, { hoses: e.target.value.replace(/\D/g, '') })} />
              </label>
              <label className={field}>Storage vessels
                <input inputMode="numeric" className={input} value={u.storage_vessels}
                       onChange={(e) => setUnit(i, { storage_vessels: e.target.value.replace(/\D/g, '') })} />
              </label>
              <Button size="icon" variant="ghost" aria-label={`Remove Unit row ${i + 1}`}
                      onClick={() => setUnits((p) => p.filter((_, j) => j !== i))}>
                <Trash2 className="h-4 w-4" aria-hidden="true" />
              </Button>
            </div>
          ))}
        </section>
        <FormMessage error={error} done={null} />
      </div>
    </RecordDetailsDialog>
  )
}
