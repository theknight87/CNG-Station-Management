import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { baseCode, calibratedCode, groupTemplates, templateLabel } from '@/features/relief-valves/valveTemplates'

/**
 * Adding a relief valve fills part number, size and code from valves already recorded with the same manufacturer and
 * set pressure (owner request 2026-10-04): one version fills untouched fields by itself, several are offered.
 */

type Row = { part_number: string | null; size_type: string | null; inlet_size: string | null; outlet_size: string | null; warehouse_code: string | null }
const state = vi.hoisted(() => ({ warehouse: [] as Row[], installed: [] as Row[], asked: [] as string[][], calls: [] as unknown[] }))

const client = {
  from: (view: string) => {
    const asked: string[] = [view]
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'ilike', 'eq']) q[m] = (...a: unknown[]) => { asked.push(`${m}:${a.join(',')}`); return q }
    q.limit = async () => {
      state.asked.push(asked)
      return { data: view === 'v_warehouse_srv_management' ? state.warehouse : state.installed, error: null }
    }
    return q
  },
  rpc: async () => ({ data: [], error: null }),
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: unknown) => { state.calls.push({ fn, args }); return null } }),
}))

const { AddWarehouseSrvsButton } = await import('@/features/relief-valves/AddWarehouseSrvs')
const { AddUnitAssetButton } = await import('@/features/units/AddUnitAsset')

const row = (part: string | null, size: string | null, inlet: string | null, outlet: string | null, code: string | null): Row =>
  ({ part_number: part, size_type: size, inlet_size: inlet, outlet_size: outlet, warehouse_code: code })

beforeEach(() => { state.warehouse = []; state.installed = []; state.asked = []; state.calls = [] })

async function openWarehouse() {
  render(<AddWarehouseSrvsButton onAdded={() => {}} />)
  await userEvent.click(screen.getByRole('button', { name: /add relief valves/i }))
}

describe('valve templates', () => {
  it('VT-1 the code rule: calibrated / under-calibration codes share one base; other shapes stay as they are', () => {
    expect(baseCode('sbc 20')).toBe('sb 20')
    expect(baseCode('SBU 20')).toBe('SB 20')
    expect(baseCode('sb 20')).toBe('sb 20')
    expect(baseCode('kcc 17')).toBe('kc 17')
    expect(baseCode('ABCD 1')).toBe('ABCD 1')
    expect(baseCode('  ')).toBeNull()
    expect(calibratedCode('sb 20')).toBe('sbc 20')
    expect(calibratedCode('MB 9')).toBe('MBC 9')
  })

  it('VT-2 combinations are counted across condition codes, most common first; an empty record is no combination', () => {
    const t = groupTemplates([
      row('P1', 'Male', '1/2"', '1"', 'sbc 20'), row('P1', 'male', '1/2"', '1"', 'sbu 20'), row('P1', 'Male', '1/2"', '1"', 'sb 20'),
      row('P2', 'Flange', '1"', '1-1/4"', 'sbc 94'), row(null, null, null, null, null),
    ])
    // The single P2 record is a one-off beside three P1s, so it is not offered (owner 2026-10-05).
    expect(t.map((x) => [x.part_number, x.base_code, x.count])).toEqual([['P1', 'sb 20', 3]])
    expect(templateLabel(t[0])).toBe('P/N P1 · Male 1/2" X 1" · sb 20')
  })

  it('VT-8 majority wins: a blank field folds into the fuller version, and one or two odd records are not offered', () => {
    const t = groupTemplates([
      ...Array(44).fill(row('v64-mf-16n-4-c', 'Male', '1"', '1"', 'qbc 49')),
      ...Array(66).fill(row(null, 'Male', '1"', '1"', null)),
      ...Array(27).fill(row(null, 'Male', '1"', '1"', 'qbu 49')),
      row('v64-mf-16n-8-c', 'Male', '1"', '1"', 'qb 49'), row('v64-mf-16n-8-c', 'Male', '1"', '1"', 'qb 49'),
      row(null, 'Male', '1/2"', '1"', 'qb 49'),
    ])
    expect(t.map((x) => [x.part_number, x.inlet_size, x.base_code, x.count])).toEqual([['v64-mf-16n-4-c', '1"', 'qb 49', 137]])
    // Two real versions with three or more records each are both still offered.
    const two = groupTemplates([...Array(5).fill(row('A', 'Male', '1"', '1"', 'x 1')), ...Array(3).fill(row('B', 'Male', '1/2"', '1"', 'x 1'))])
    expect(two.map((x) => [x.part_number, x.count])).toEqual([['A', 5], ['B', 3]])
    // With only a couple of records each, nothing is called a mistake: all are shown.
    expect(groupTemplates([row('A', null, null, null, null), row('B', null, null, null, null)])).toHaveLength(2)
  })

  it('VT-3 one version: typing manufacturer and set pressure fills part number, size and base code by itself', async () => {
    state.warehouse = [row('SS-4R3A', 'Female', '1/4"', '1/4"', 'qbc 51'), row('SS-4R3A', 'Female', '1/4"', '1/4"', 'qbu 51')]
    state.installed = [row('SS-4R3A', 'Female', '1/4"', '1/4"', 'qbc 51')]
    await openWarehouse()
    await userEvent.type(screen.getByLabelText(/^manufacturer/i), 'dk-lok')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '65.7')
    expect(await screen.findByText(/filled from 3 recorded valves/i)).toBeDefined()
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('SS-4R3A')
    expect((screen.getByLabelText(/^size type/i) as HTMLSelectElement).value).toBe('Female')
    expect((screen.getByLabelText(/^inlet/i) as HTMLInputElement).value).toBe('1/4"')
    expect((screen.getByLabelText(/^warehouse code/i) as HTMLInputElement).value).toBe('qb 51')
    // Asked for this manufacturer (any case), this exact set pressure and unit, from both registries.
    const last = state.asked.slice(-2)
    expect(last.map((a) => a[0]).sort()).toEqual(['v_installed_srv_management', 'v_warehouse_srv_management'])
    expect(last[0]).toEqual(expect.arrayContaining(['ilike:manufacturer,dk-lok', 'eq:pressure_min,65.7', 'eq:pressure_max,65.7', 'eq:pressure_unit,BAR']))
  })

  it('VT-4 a field the user typed is never overwritten by the automatic fill', async () => {
    state.warehouse = [row('P1', 'Male', '1/2"', '1"', 'sbc 20')]
    await openWarehouse()
    await userEvent.type(screen.getByLabelText(/^part number/i), 'MINE')
    await userEvent.type(screen.getByLabelText(/^manufacturer/i), 'Technical')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '275')
    await screen.findByText(/filled from 1 recorded valve /i)
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('MINE')
    expect((screen.getByLabelText(/^outlet/i) as HTMLInputElement).value).toBe('1"')
  })

  it('VT-5 several versions are offered, nothing is filled until one is chosen, and the choice fills every field it carries', async () => {
    state.warehouse = [row('P1', 'Male', '1/2"', '1"', 'sbc 20'), row('P1', 'Male', '1/2"', '1"', 'sbc 20'), row('P2', 'Flange', '1"', '1-1/4"', 'sbc 94')]
    await openWarehouse()
    await userEvent.type(screen.getByLabelText(/^manufacturer/i), 'Technical')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '275')
    expect(await screen.findByText(/come in 2 versions/i)).toBeDefined()
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('')
    const choices = screen.getAllByRole('button', { pressed: false })
    expect(choices.map((b) => b.textContent)).toEqual(['P/N P1 · Male 1/2" X 1" · sb 20— 2 valves', 'P/N P2 · Flange 1" X 1-1/4" · sb 94— 1 valve'])
    await userEvent.type(screen.getByLabelText(/^part number/i), 'X')
    await userEvent.click(choices[1])
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('P2')
    expect((screen.getByLabelText(/^size type/i) as HTMLSelectElement).value).toBe('Flange')
    expect((screen.getByLabelText(/^warehouse code/i) as HTMLInputElement).value).toBe('sb 94')
    expect(screen.getByRole('button', { pressed: true }).textContent).toContain('P2')
  })

  it('VT-6 no recorded valve: the form says so and fills nothing; nothing is asked before both are typed', async () => {
    await openWarehouse()
    expect(screen.getByText(/type the manufacturer and set pressure/i)).toBeDefined()
    await userEvent.type(screen.getByLabelText(/^manufacturer/i), 'Taylor')
    expect(state.asked).toEqual([])
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '9')
    expect(await screen.findByText(/no valve of this manufacturer and pressure/i)).toBeDefined()
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('')
  })

  it('VT-7 the Unit window fills the same way, with the calibrated code an installed valve carries', async () => {
    state.installed = [row('P9', 'Male', '3/4"', '1"', 'fcc 13')]
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="شبرا 3" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    await userEvent.type(screen.getByLabelText(/^manufacturer/i), 'COI')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '300')
    await screen.findByText(/filled from 1 recorded valve /i)
    expect((screen.getByLabelText(/^part number/i) as HTMLInputElement).value).toBe('P9')
    expect((screen.getByLabelText(/^warehouse code/i) as HTMLInputElement).value).toBe('fcc 13')
    await userEvent.click(screen.getAllByRole('button', { name: /add relief valve/i }).at(-1)!)
    await waitFor(() => expect(state.calls).toHaveLength(1))
    expect((state.calls[0] as { args: { p: Record<string, unknown> } }).args.p).toMatchObject({
      manufacturer: 'COI', part_number: 'P9', size_type: 'Male', inlet_size: '3/4"', outlet_size: '1"', warehouse_code: 'fcc 13', pressure_min: 300,
    })
  })
})
