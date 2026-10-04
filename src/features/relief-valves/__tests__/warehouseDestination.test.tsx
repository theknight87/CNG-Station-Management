import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * A store valve's destination — a Station or a Unit, or none (owner request 2026-10-04): chosen for the whole batch
 * or per serial when adding, and changed later from the valve's details. Only names from the list are accepted.
 */

const state = vi.hoisted(() => ({ calls: [] as { fn: string; args: Record<string, unknown> }[] }))
const tables: Record<string, unknown[]> = {
  regions: [{ id: 'r-e', name: 'East' }],
  stations: [{ id: 's-1', station_name: 'شبرا', region_id: 'r-e' }, { id: 's-2', station_name: 'الخمائل', region_id: 'r-e' }],
  units: [{ id: 'u-1', unit_name: 'شبرا 1', station_id: 's-1' }],
}
function query(table: string) {
  const q: Record<string, unknown> = {}
  for (const m of ['select', 'is', 'order', 'limit', 'ilike', 'eq']) q[m] = () => q
  q.then = (ok: (v: unknown) => unknown) => Promise.resolve({ data: tables[table] ?? [], error: null }).then(ok)
  return q
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => ({ from: query }) }))
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: Record<string, unknown>) => { state.calls.push({ fn, args }); return null } }),
}))

const { AddWarehouseSrvsButton } = await import('@/features/relief-valves/AddWarehouseSrvs')
const { WarehouseDestinationEditor } = await import('@/features/relief-valves/WarehouseDestinationEditor')

beforeEach(() => { state.calls = [] })

async function openAdd() {
  render(<AddWarehouseSrvsButton onAdded={() => {}} />)
  await userEvent.click(screen.getByRole('button', { name: /add relief valves/i }))
}

describe('warehouse destination', () => {
  it('WDF-1 each serial can carry its own Station or Unit; one left empty takes the batch destination', async () => {
    await openAdd()
    await userEvent.type(screen.getByLabelText(/^serials/i), 'A-1{enter}A-2')
    await userEvent.type(screen.getByLabelText('Destination for all'), 'الخمائل · East')
    await userEvent.type(await screen.findByLabelText('Destination for A-1'), 'شبرا 1 — شبرا · East')
    await userEvent.click(screen.getByRole('button', { name: /add 2 valves/i }))
    await waitFor(() => expect(state.calls).toHaveLength(1))
    expect(state.calls[0].args.p).toMatchObject({
      serials: ['A-1', 'A-2'], station_id: 's-2', unit_id: null,
      items: [{ serial: 'A-1', station_id: 's-1', unit_id: 'u-1' }, { serial: 'A-2', station_id: null, unit_id: null }],
    })
  })

  it('WDF-2 no destination chosen: nothing per serial is sent and the batch destination is empty', async () => {
    await openAdd()
    await userEvent.type(screen.getByLabelText(/^serials/i), 'B-1')
    await userEvent.click(screen.getByRole('button', { name: /add 1 valve/i }))
    await waitFor(() => expect(state.calls).toHaveLength(1))
    const p = state.calls[0].args.p as Record<string, unknown>
    expect(p).toMatchObject({ station_id: null, unit_id: null })
    expect(p).not.toHaveProperty('items')
  })

  it('WDF-3 a name that is not in the list is refused with a message and nothing is saved', async () => {
    await openAdd()
    await userEvent.type(screen.getByLabelText(/^serials/i), 'C-1')
    await userEvent.type(await screen.findByLabelText('Destination for C-1'), 'محطة غير موجودة')
    expect(screen.getAllByText(/choose a station or unit from the list/i).length).toBeGreaterThan(0)
    await userEvent.click(screen.getByRole('button', { name: /add 1 valve/i }))
    expect(state.calls).toEqual([])
  })

  it('WDF-4 changing an existing valve\'s destination sends the valve, its version and the chosen Unit; clearing sends none', async () => {
    const done = vi.fn()
    const row = { id: 'w-1', updated_at: '2026-10-04T08:00:00Z', target_station_id: 's-1', target_unit_id: null }
    render(<WarehouseDestinationEditor row={row} onDone={done} />)
    await userEvent.click(screen.getByRole('button', { name: /change destination/i }))
    const field = screen.getByLabelText('New destination') as HTMLInputElement
    await waitFor(() => expect(field.value).toBe('شبرا · East'))
    await userEvent.clear(field)
    await userEvent.type(field, 'شبرا 1 — شبرا · East')
    await userEvent.click(screen.getByRole('button', { name: /save destination/i }))
    await waitFor(() => expect(done).toHaveBeenCalled())
    expect(state.calls[0]).toEqual({ fn: 'cng_admin_set_warehouse_destination',
      args: { p_id: 'w-1', p_expected_updated_at: '2026-10-04T08:00:00Z', p_station_id: 's-1', p_unit_id: 'u-1' } })

    await userEvent.click(screen.getByRole('button', { name: /change destination/i }))
    await userEvent.clear(screen.getByLabelText('New destination'))
    await userEvent.click(screen.getByRole('button', { name: /save destination/i }))
    await waitFor(() => expect(state.calls).toHaveLength(2))
    expect(state.calls[1].args).toMatchObject({ p_station_id: null, p_unit_id: null })
  })
})
