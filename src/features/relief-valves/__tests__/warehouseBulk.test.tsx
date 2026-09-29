import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Warehouse SRVs — the "+" to send a valve to 3rd party calibration, and bulk actions (owner request 2026-09-29).
 *
 * The + must be reachable from the TABLE on a desktop, not only in the mobile card layout or the details
 * dialog; ticked rows can be sent to calibration or removed together. Only valves under calibration (UC)
 * are ever sent, and removal goes through the same audited archive function as the single delete.
 */

const state = vi.hoisted(() => ({ role: 'admin', rows: [] as unknown[] }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]> }))

vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }),
}))

const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    return { data: 1, error: null }
  }),
  from: () => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'in', 'ilike', 'lte', 'gte', 'or', 'order']) q[m] = () => q
    q.range = async () => ({ data: state.rows, error: null, count: state.rows.length })
    q.then = (resolve: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null, count: 0 }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { WarehouseSrvSection } = await import('@/features/relief-valves/sections/WarehouseSrvSection')

function stock(id: string, availability: string, serial: string) {
  return {
    id, availability_status: availability, warehouse_code: `acu ${id}`, serial_number: serial, serial_number_raw: serial,
    serial_status: 'present', part_number: null, manufacturer: 'Mercer', size_type: 'Male', inlet_size: '1"', outlet_size: '1"',
    set_pressure_raw: '30', pressure_min: 30, pressure_max: 30, pressure_unit: 'PSI', target_region_id: null, target_region_name: null,
    target_station_id: null, target_station_name: null, is_unassigned_stock: true, updated_at: '2026-09-01T00:00:00Z',
    warehouse_issue_date: null, last_calibration_date: null, last_calibration_precision: 'unknown', last_calibration_display: null,
    next_calibration_date: null, next_calibration_precision: null, next_calibration_display: null, days_left: null,
    due_status: 'unknown', calibration_location: null, source_status_raw: null, needs_review: false, notes: null,
  }
}

beforeEach(() => {
  state.role = 'admin'
  state.rows = [stock('w1', 'available_in_store_uc', 'UC-1'), stock('w2', 'available_calibrated', 'CAL-2'), stock('w3', 'available_in_store_uc', 'UC-3')]
  calls.rpc.length = 0
})

describe('Warehouse SRVs — send to calibration and bulk actions', () => {
  it('WHB-1 the + sits in a VISIBLE table cell beside each under-calibration valve, and only there', async () => {
    render(<WarehouseSrvSection />)
    const table = await screen.findByRole('table')
    const plus = within(table).getAllByRole('button', { name: /send serial .* to calibration/i })
    expect(plus).toHaveLength(2)
    // Never in a column the desktop layout hides.
    for (const b of plus) expect(b.closest('td')!.className).not.toMatch(/\bhidden\b/)
    const user = userEvent.setup()
    await user.click(plus[0])
    expect(calls.rpc.find(([fn]) => fn === 'cng_srv_calibration_send')![1]).toEqual({ p_warehouse_valve_ids: ['w1'] })
    // Clicking the + never opens the record dialog.
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('WHB-2 bulk send carries only the ticked valves that are under calibration', async () => {
    const user = userEvent.setup()
    render(<WarehouseSrvSection />)
    await user.click(await screen.findByRole('checkbox', { name: 'Select all on this page' }))
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(screen.getByText('3 selected')).toBeDefined()
    await user.click(screen.getByRole('button', { name: /send to calibration \(2\)/i }))
    expect(calls.rpc.find(([fn]) => fn === 'cng_srv_calibration_send')![1]).toEqual({ p_warehouse_valve_ids: ['w1', 'w3'] })
    for (const k of ['actor', 'sent_by', 'app_user']) expect(JSON.stringify(calls.rpc)).not.toContain(k)
  })

  it('WHB-3 bulk delete asks once, then archives each ticked valve through the audited function', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
    const user = userEvent.setup()
    render(<WarehouseSrvSection />)
    const boxes = await screen.findAllByRole('checkbox', { name: 'Select row' })
    await user.click(boxes[1]); await user.click(boxes[2])
    await user.click(screen.getByRole('button', { name: /delete \(2\)/i }))
    expect(confirm).toHaveBeenCalledTimes(1)
    await waitFor(() => expect(calls.rpc.filter(([fn]) => fn === 'cng_admin_archive_srv')).toHaveLength(2))
    expect(calls.rpc.filter(([fn]) => fn === 'cng_admin_archive_srv').map(([, a]) => a)).toEqual([
      { p_table: 'warehouse_relief_valves', p_id: 'w2' }, { p_table: 'warehouse_relief_valves', p_id: 'w3' },
    ])
    confirm.mockRestore()
  })

  it('WHB-4 a cancelled bulk delete sends nothing; a calibrated-only selection cannot be sent', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    const user = userEvent.setup()
    render(<WarehouseSrvSection />)
    await user.click((await screen.findAllByRole('checkbox', { name: 'Select row' }))[1])
    expect((screen.getByRole('button', { name: /send to calibration \(0\)/i }) as HTMLButtonElement).disabled).toBe(true)
    await user.click(screen.getByRole('button', { name: /delete \(1\)/i }))
    expect(calls.rpc).toHaveLength(0)
    confirm.mockRestore()
  })

  it('WHB-5 a viewer gets no tick boxes, no + and no bulk actions', async () => {
    state.role = 'viewer'
    render(<WarehouseSrvSection />)
    const table = await screen.findByRole('table')
    expect(within(table).queryByRole('checkbox')).toBeNull()
    expect(within(table).queryByRole('button', { name: /send serial/i })).toBeNull()
    expect(screen.queryByRole('button', { name: /send to calibration/i })).toBeNull()
  })
})
