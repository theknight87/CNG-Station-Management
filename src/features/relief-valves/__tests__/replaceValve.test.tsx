import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Replace an installed valve from its details (owner request 2026-09-29): the store valves offered match the set
 * pressure exactly and the size (and, by default, the manufacturer); confirming calls cng_srv_issue with this valve as
 * the one replaced.
 */

const state = vi.hoisted(() => ({ role: 'admin', stock: [] as unknown[] }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]>, query: [] as string[] }))

vi.mock('@/hooks/useAppUser', () => ({ useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }) }))
const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => { calls.rpc.push([fn, args]); return { data: 'issue-1', error: null } }),
  from: (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'in', 'eq', 'is', 'order']) q[m] = (...a: unknown[]) => { calls.query.push(`${table}.${m}:${a.map((x) => JSON.stringify(x)).join('|')}`); return q }
    q.limit = async () => ({ data: table === 'v_srv_warehouse_stock' ? state.stock : [], error: null })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve({ data: table === 'units' ? [{ id: 'unit-9', unit_name: 'الماظة 2' }] : table === 'stations' ? [{ id: 'st-1', station_name: 'الماظة' }] : [], error: null }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { ReplaceValvePanel } = await import('@/features/relief-valves/ReplaceValvePanel')
const { matchesSpec, sizeKey } = await import('@/features/relief-valves/replaceMatch')

const valve = {
  id: 'inst-1', serial_number: 'OLD-1', station_id: 'st-1', unit_id: 'unit-1', manufacturer: 'Mercer',
  size_type: 'Male', inlet_size: '1/2"', outlet_size: '1"', pressure_min: 30, pressure_max: 30, pressure_unit: 'PSI' as const, set_pressure_raw: '30',
}
const stock = (id: string, over: Record<string, unknown> = {}) => ({
  id, serial_number: `S-${id}`, warehouse_code: `acc ${id}`, manufacturer: 'Mercer', part_number: null, size_type: 'male', inlet_size: '1/2 "',
  outlet_size: '1"', pressure_min: 30, pressure_max: 30, pressure_unit: 'PSI', set_pressure_raw: '30', availability_status: 'available_calibrated',
  last_calibration_display: '2026-02-03', next_calibration_display: '2027-02-03', updated_at: `2026-09-29T0${id}:00:00Z`, ...over,
})

beforeEach(() => {
  state.role = 'admin'
  state.stock = [stock('1'), stock('2', { outlet_size: '3/4"' }), stock('3', { manufacturer: 'Technical' })]
  calls.rpc.length = 0; calls.query.length = 0
})

describe('replace from the valve details', () => {
  it('REPL-1 matching: size compared ignoring spaces/quotes/case; an unrecorded part does not narrow; maker optional', () => {
    expect(sizeKey('1/2 "')).toBe(sizeKey('1/2"'))
    expect(matchesSpec(valve, stock('1') as never, true)).toBe(true)
    expect(matchesSpec(valve, stock('2', { outlet_size: '3/4"' }) as never, true)).toBe(false)
    expect(matchesSpec(valve, stock('3', { manufacturer: 'Technical' }) as never, true)).toBe(false)
    expect(matchesSpec(valve, stock('3', { manufacturer: 'Technical' }) as never, false)).toBe(true)
    expect(matchesSpec({ ...valve, outlet_size: null }, stock('2', { outlet_size: '3/4"' }) as never, true)).toBe(true)
  })

  it('REPL-2 lists only calibrated store valves with the exact set pressure and same size and maker; confirm issues in place of this valve', async () => {
    const onDone = vi.fn()
    const user = userEvent.setup()
    render(<ReplaceValvePanel valve={valve} onDone={onDone} />)
    await user.click(screen.getByRole('button', { name: /replace this valve/i }))
    const list = await screen.findByRole('group', { name: /1 matching in the store/i })
    expect(within(list).getAllByRole('radio')).toHaveLength(1)
    expect(calls.query).toEqual(expect.arrayContaining([
      'v_srv_warehouse_stock.in:"availability_status"|["available_calibrated"]',
      'v_srv_warehouse_stock.eq:"pressure_min"|30', 'v_srv_warehouse_stock.eq:"pressure_max"|30', 'v_srv_warehouse_stock.eq:"pressure_unit"|"PSI"',
    ]))
    await user.click(within(list).getByRole('radio'))
    await user.click(screen.getByRole('button', { name: /confirm replacement/i }))
    const issue = calls.rpc.find(([fn]) => fn === 'cng_srv_issue')![1]
    expect(issue).toEqual({
      p_warehouse_valve_id: '1', p_expected_updated_at: '2026-09-29T01:00:00Z', p_unit_id: 'unit-1',
      p_replace_installed_valve_id: 'inst-1', p_emergency: false, p_notes: null,
    })
    for (const k of ['actor', 'issued_by', 'app_user']) expect(JSON.stringify(issue)).not.toContain(k)
    await waitFor(() => expect(onDone).toHaveBeenCalled())
  })

  it('REPL-3 other manufacturers and new valves only when asked', async () => {
    const user = userEvent.setup()
    render(<ReplaceValvePanel valve={valve} onDone={() => {}} />)
    await user.click(screen.getByRole('button', { name: /replace this valve/i }))
    await screen.findByRole('group', { name: /1 matching/i })
    await user.click(screen.getByRole('checkbox', { name: /same manufacturer only/i }))
    expect(await screen.findByRole('group', { name: /2 matching/i })).toBeDefined()
    await user.click(screen.getByRole('checkbox', { name: /include new valves/i }))
    await waitFor(() => expect(calls.query).toContain('v_srv_warehouse_stock.in:"availability_status"|["available_calibrated","available_new"]'))
  })

  it('REPL-4 a valve with no recorded Unit asks for one before it can be replaced; nothing matching is stated', async () => {
    state.stock = []
    const user = userEvent.setup()
    render(<ReplaceValvePanel valve={{ ...valve, unit_id: null }} onDone={() => {}} />)
    await user.click(screen.getByRole('button', { name: /replace this valve/i }))
    expect(await screen.findByText(/no calibrated valve in the store matches/i)).toBeDefined()
    expect(screen.getByLabelText(/unit \(this valve has none recorded\)/i)).toBeDefined()
    expect((screen.getByRole('button', { name: /confirm replacement/i }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('REPL-5 a viewer gets no replace control', () => {
    state.role = 'viewer'
    render(<ReplaceValvePanel valve={valve} onDone={() => {}} />)
    expect(screen.queryByRole('button', { name: /replace this valve/i })).toBeNull()
  })
})
