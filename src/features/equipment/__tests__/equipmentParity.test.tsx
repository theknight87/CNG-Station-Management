import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Hoses and Gas Detectors get what the relief valves have (owner request 2026-10-10): move an issued item to another
 * Station, the warehouse issue sheet, one search over every tab, and several serials at once with where each already is.
 */
const state = vi.hoisted(() => ({ role: 'admin', rows: [] as unknown[], where: [] as unknown[] }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]> }))

vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }),
}))

const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    if (fn === 'cng_equipment_replacement_candidates') {
      return { data: [{ id: 'old-b', serial_number: 'B-OLD', manufacturer: null, model: null, description: null, unit_name: null, last_date: null }], error: null }
    }
    if (fn === 'cng_equipment_serial_whereabouts') return { data: state.where, error: null }
    return { data: 1, error: null }
  }),
  from: (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'in', 'ilike', 'lte', 'gte', 'order', 'or', 'eq', 'not', 'limit']) q[m] = () => q
    q.range = async () => ({ data: state.rows, error: null, count: state.rows.length })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve({ data: table === 'stations' ? [{ id: 's2', station_name: 'شطا' }] : [], error: null, count: 0 }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { EquipmentLogSection, EquipmentWarehouseSection } = await import('@/features/equipment/EquipmentSections')
const { equipmentLink, rankEquipmentHits } = await import('@/features/equipment/equipmentSearch')
const { equipmentHeaders, equipmentIssueWorkbookName, equipmentSheetCells } = await import('@/features/export/equipmentIssueSheet')

const issue = { id: 'i1', kind: 'hose', issued_at: '2026-10-09T08:00:00Z', is_emergency: false, notes: null, region_name: 'East',
  station_name: 'الماظة', unit_name: null, stock_id: 'w1', issued_serial: 'H-NEW', issued_code: 'HS 1', manufacturer: null, model: null,
  description: '1/2" hose', working_pressure_value: null, working_pressure_unit: null, replaced_serial: 'A-OLD',
  status: 'replaced_at_station', replaced_returned_at: null }

beforeEach(() => {
  state.role = 'admin'; state.rows = []; state.where = []
  calls.rpc.length = 0
})

const FORBIDDEN = ['actor', 'decided_by', 'issued_by', 'user_id', 'app_user', 'sub']

describe('Move an issued item to another station', () => {
  it('EQP-1 sends the issue, the new Station and the item it replaces there — and no actor', async () => {
    state.rows = [issue]
    const user = userEvent.setup()
    render(<EquipmentLogSection kind="hose" />)
    await user.click(await screen.findByRole('button', { name: /^Issued/ }))
    const table = await screen.findByRole('table', { name: /Hoses Management issues/i })
    await user.click(within(table).getByRole('button', { name: 'Move to another station' }))
    expect(screen.getByText(/At الماظة, serial A-OLD goes back to its position/)).toBeDefined()
    const confirm = screen.getByRole('button', { name: 'Confirm move' }) as HTMLButtonElement
    expect(confirm.disabled).toBe(true)
    await waitFor(() => expect(screen.getAllByRole('option', { name: 'شطا' }).length).toBeGreaterThan(0))
    await user.selectOptions(screen.getByLabelText('Station'), 's2')
    await user.click(await screen.findByRole('radio', { name: /B-OLD/ }))
    await user.click(confirm)
    const [, args] = calls.rpc.find(([fn]) => fn === 'cng_equipment_issue_transfer')!
    expect(args).toEqual({ p_issue_id: 'i1', p_station_id: 's2', p_unit_id: null, p_replace_id: 'old-b', p_emergency: false, p_notes: null })
    for (const k of Object.keys(args)) for (const f of FORBIDDEN) expect(k.toLowerCase()).not.toContain(f)
    expect(await screen.findByText(/Moved: serial A-OLD is back in its position/)).toBeDefined()
  })

  it('EQP-2 a viewer gets neither Move nor the Issue sheet', async () => {
    state.role = 'viewer'
    state.rows = [issue]
    const user = userEvent.setup()
    render(<EquipmentLogSection kind="hose" />)
    await user.click(await screen.findByRole('button', { name: /^Issued/ }))
    await screen.findByRole('table', { name: /Hoses Management issues/i })
    expect(screen.queryByRole('button', { name: 'Move to another station' })).toBeNull()
    expect(screen.queryByRole('button', { name: /Issue sheet/ })).toBeNull()
  })
})

describe('Issue sheet', () => {
  it('EQP-3 the admin gets the Issue sheet on the Issued movement only', async () => {
    state.rows = [issue]
    const user = userEvent.setup()
    render(<EquipmentLogSection kind="gas_detector" />)
    await screen.findByRole('table')
    expect(screen.queryByRole('button', { name: /Issue sheet/ })).toBeNull()
    await user.click(screen.getByRole('button', { name: /^Issued/ }))
    expect(await screen.findByRole('button', { name: /Issue sheet/ })).toBeDefined()
  })

  it('EQP-4 rows: a hose sheet carries description and working pressure; a cancelled issue reads ملغي; serials stay text', () => {
    const row = { id: 'x', kind: 'hose' as const, issued_at: '2026-10-09T08:00:00Z', issue_day: '2026-10-09', region_id: 'r', region_name: 'East',
      sheet_id: 's', sheet_seq: 1, is_emergency: false, station_name: 'شطا', unit_name: null, place_name: 'شطا', issued_serial: '0012',
      issued_code: 'hk 7', manufacturer: null, model: null, description: '1/2" hose', working_pressure_value: 350, working_pressure_unit: 'BAR',
      replaced_serial: 'B-OLD', replaced_returned_at: null, is_cancelled: false, cancelled_returned_at: null }
    expect(equipmentHeaders('hose')).toHaveLength(8)
    expect(equipmentSheetCells('hose', row, 1)).toEqual([1, 'شطا', '1/2" hose', '350 BAR', 'B-OLD', '0012', 'hk 7', null])
    expect(equipmentSheetCells('hose', { ...row, is_cancelled: true, cancelled_returned_at: '2026-10-11T09:00:00Z' }, 2)[7]).toBe('ملغي - 11/10/2026')
    expect(equipmentHeaders('gas_detector')).toContain('الموديل')
    expect(equipmentSheetCells('gas_detector', { ...row, kind: 'gas_detector', manufacturer: 'Honeywell', model: 'XNX' }, 1).slice(2, 4)).toEqual(['Honeywell', 'XNX'])
    expect(equipmentIssueWorkbookName('hose', 'East', '2026-10')).toBe('صرف خراطيم شرق 10-2026.xlsx')
  })
})

describe('One search over every tab', () => {
  it('EQP-5 links open the right tab (the 3rd-party tab by its own route) with the serial and record', () => {
    expect(equipmentLink('hose', 'jobs', 'H 1', 'j1')).toBe('/manage/hoses/testing?q=H+1&open=j1')
    expect(equipmentLink('gas_detector', 'warehouse', 'G-1', 'w1')).toBe('/manage/gas-detectors/warehouse?q=G-1&open=w1')
    const ranked = rankEquipmentHits([
      { tab: 'log', id: 'a', serial: 'H-10', code: null, place: null },
      { tab: 'warehouse', id: 'b', serial: 'H-1', code: null, place: null },
      { tab: 'installed', id: 'c', serial: 'H-100', code: null, place: null },
    ], 'h-1')
    expect(ranked.map((h) => h.id)).toEqual(['b', 'c', 'a'])
  })
})

describe('Several serials at once', () => {
  it('EQP-6 a serial typed twice is flagged and the add is held back', async () => {
    const user = userEvent.setup()
    render(<EquipmentWarehouseSection kind="hose" />)
    await user.click(await screen.findByRole('button', { name: /add hoses/i }))
    await user.type(screen.getByLabelText(/Serial numbers/), 'H-1, h-1 , H-2')
    expect(await screen.findByText('Typed more than once')).toBeDefined()
    expect((screen.getByRole('button', { name: /add 3 hoses/i }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('EQP-7 each serial shows where it already is (this kind only); a known one holds the add back', async () => {
    state.where = [{ serial: 'G-OLD', kind: 'log', blocking: true, place: 'awaiting return from الماظة 1 · East', record_id: 'l1' }]
    const user = userEvent.setup()
    render(<EquipmentWarehouseSection kind="gas_detector" />)
    await user.click(await screen.findByRole('button', { name: /add gas detectors/i }))
    await user.type(screen.getByLabelText(/Serial numbers/), 'G-NEW\nG-OLD')
    expect(await screen.findByText(/Already recorded — awaiting return from الماظة 1/)).toBeDefined()
    expect((screen.getByRole('button', { name: /add 2 gas detectors/i }) as HTMLButtonElement).disabled).toBe(true)
    const [, args] = calls.rpc.find(([fn]) => fn === 'cng_equipment_serial_whereabouts')!
    expect(args).toEqual({ p_kind: 'gas_detector', p_serials: ['G-NEW', 'G-OLD'] })
  })
})
