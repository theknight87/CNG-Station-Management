import { useState } from 'react'
import { MapPin } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { DestinationInput } from '@/features/relief-valves/DestinationInput'
import { useDestinationOptions, type Destination } from '@/features/relief-valves/destinationOptions'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'
import type { WarehouseSrvRow } from '@/features/relief-valves/useSrvManagement'

/**
 * Admin: change a store valve's destination — a Station, one of its Units, or none (owner request 2026-10-04).
 * cng_admin_set_warehouse_destination: actor server-side, audited, refused (409) if the valve changed meanwhile.
 */
export function WarehouseDestinationEditor({ row, onDone }: {
  row: Pick<WarehouseSrvRow, 'id' | 'updated_at' | 'target_station_id' | 'target_unit_id'>
  onDone: () => void
}) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(false)
  if (!isAdmin) return null
  return open ? <Editor row={row} onDone={onDone} onClose={() => setOpen(false)} /> : (
    <Button size="sm" variant="outline" className="h-7" onClick={() => setOpen(true)}>
      <MapPin className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Change destination
    </Button>
  )
}

function Editor({ row, onDone, onClose }: {
  row: Pick<WarehouseSrvRow, 'id' | 'updated_at' | 'target_station_id' | 'target_unit_id'>
  onDone: () => void
  onClose: () => void
}) {
  const options = useDestinationOptions()
  const current: Destination | null = row.target_station_id ? { station_id: row.target_station_id, unit_id: row.target_unit_id } : null
  const [value, setValue] = useState<Destination | null | undefined>(current)
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)

  async function save() {
    if (value === undefined) { setError('Choose a Station or Unit from the list, or leave it empty for no destination.'); return }
    const err = await run('cng_admin_set_warehouse_destination', {
      p_id: row.id, p_expected_updated_at: row.updated_at, p_station_id: value?.station_id ?? null, p_unit_id: value?.unit_id ?? null,
    })
    if (err) { setError(err); return }
    onClose(); onDone()
  }

  return (
    <div className="flex w-full flex-col gap-1.5 rounded border p-2" role="group" aria-label="Change destination">
      <span className="text-xs text-muted-foreground">Destination — Station or Unit; empty for none</span>
      <DestinationInput options={options} value={value ?? null} onChange={setValue} label="New destination" className="max-w-md" />
      <FormMessage error={error} done={null} />
      <div className="flex gap-2">
        <Button size="sm" className="h-7" disabled={busy} onClick={() => void save()}>{busy ? 'Saving…' : 'Save destination'}</Button>
        <Button size="sm" variant="outline" className="h-7" onClick={onClose}>Cancel</Button>
      </div>
    </div>
  )
}
