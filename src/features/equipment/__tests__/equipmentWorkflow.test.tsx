import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Hoses and Gas Detectors carry the relief-valve tabs (owner request 2026-10-02). These drive the real sections
 * with a stubbed client and assert what reaches the database: the right function, the ticked ids, the version read,
 * and never an actor.
 */
const state = vi.hoisted(() => ({ role: 'admin', rows: [] as unknown[] }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]>, ops: [] as string[] }))

vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }),
}))

const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    if (fn === 'cng_equipment_replacement_candidates') {
      return { data: [{ id: 'old-1', serial_number: 'OLD-H', manufacturer: null, model: null, description: '1/2" hose', unit_name: null, last_date: null }], error: null }
    }
    if (fn === 'cng_equipment_history') return { data: [], error: null }
    return { data: 1, error: null }
  }),
  from: (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'in', 'ilike', 'lte', 'gte', 'order', 'or']) q[m] = () => q
    q.eq = (c: string, v: unknown) => { calls.ops.push(`${table}.eq:${c}=${String(v)}`); return q }
    q.range = async () => ({ data: state.rows, error: null, count: state.rows.length })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve({
        data: table === 'stations' ? [{ id: 's1', station_name: 'الماظة' }] : table === 'units' ? [{ id: 'unit-1', unit_name: 'الماظة 1' }] : [],
        error: null, count: 3,
      }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const {
  EquipmentWorkspace, EquipmentWarehouseSection, EquipmentLogSection, EquipmentJobsSection, EquipmentEmergencySection,
} = await import('@/features/equipment/EquipmentSections')

const stock = (over: Record<string, unknown> = {}) => ({
  id: 'w1', kind: 'hose', availability_status: 'available_new', serial_number: 'H-NEW', serial_status: 'assigned',
  manufacturer: null, model: null, description: '1/2" hose', working_pressure_value: 350, working_pressure_unit: 'BAR',
  test_pressure_value: null, test_pressure_unit: null, last_date: null, last_precision: 'unknown', next_date: null,
  next_precision: 'unknown', days_left: null, due_status: 'unknown', warehouse_code: 'HS 1', notes: null,
  updated_at: '2026-10-02T10:00:00Z', ...over,
})

beforeEach(() => {
  state.role = 'admin'; state.rows = []
  calls.rpc.length = 0; calls.ops.length = 0
  vi.spyOn(window, 'confirm').mockReturnValue(true)
})

const FORBIDDEN = ['actor', 'decided_by', 'issued_by', 'user_id', 'app_user', 'sub']
function noActor(args: Record<string, unknown>) {
  for (const k of Object.keys(args)) for (const f of FORBIDDEN) expect(k.toLowerCase()).not.toContain(f)
}

describe('the workspace', () => {
  it('EQW-1 hoses get five tabs, with the 3rd-party step named Hydrotest, never Calibration', () => {
    render(
      <MemoryRouter initialEntries={['/manage/hoses/warehouse']}>
        <Routes><Route path="/manage/hoses" element={<EquipmentWorkspace kind="hose" />}><Route path="warehouse" element={<p>w</p>} /></Route></Routes>
      </MemoryRouter>,
    )
    const nav = screen.getByRole('navigation', { name: /Hoses Management sections/i })
    const links = within(nav).getAllByRole('link').map((a) => a.getAttribute('href'))
    expect(links).toEqual(['/manage/hoses/installed', '/manage/hoses/warehouse', '/manage/hoses/log', '/manage/hoses/testing', '/manage/hoses/emergency'])
    expect(within(nav).getByText('Hydrotest (3rd party)')).toBeDefined()
    expect(within(nav).queryByText(/calibration/i)).toBeNull()
  })

  it('EQW-2 gas detectors get the same five tabs with Calibration (3rd party)', () => {
    render(
      <MemoryRouter initialEntries={['/manage/gas-detectors/log']}>
        <Routes><Route path="/manage/gas-detectors" element={<EquipmentWorkspace kind="gas_detector" />}><Route path="log" element={<p>l</p>} /></Route></Routes>
      </MemoryRouter>,
    )
    const nav = screen.getByRole('navigation', { name: /Gas Detector Management sections/i })
    expect(within(nav).getByText('Calibration (3rd party)').closest('a')!.getAttribute('href')).toBe('/manage/gas-detectors/calibration')
    expect(within(nav).getAllByRole('link')).toHaveLength(5)
  })
})

describe('Warehouse', () => {
  it('EQW-3 reads only this kind, and labels a tested hose TESTED, not CALIBRATED', async () => {
    state.rows = [stock({ id: 'w2', availability_status: 'available_calibrated', serial_number: 'H-CAL' })]
    render(<EquipmentWarehouseSection kind="hose" />)
    const table = await screen.findByRole('table', { name: /Hoses Management warehouse/i })
    expect(within(table).getByText('TESTED')).toBeDefined()
    expect(screen.queryByText('CALIBRATED')).toBeNull()
    expect(calls.ops).toContain('v_equipment_stock.eq:kind=hose')
  })

  it('EQW-4 sending ticked under-test hoses for hydrotest sends exactly those ids and no actor', async () => {
    state.rows = [stock({ id: 'w3', availability_status: 'available_in_store_uc', serial_number: 'H-UC' }), stock()]
    const user = userEvent.setup()
    render(<EquipmentWarehouseSection kind="hose" />)
    const table = await screen.findByRole('table', { name: /Hoses Management warehouse/i })
    // Only the under-test hose can be ticked.
    expect(within(table).getAllByRole('checkbox', { name: 'Select row' })).toHaveLength(1)
    await user.click(within(table).getByRole('checkbox', { name: 'Select row' }))
    await user.click(screen.getByRole('button', { name: /send for hydrotest \(1\)/i }))
    const [, args] = calls.rpc.find(([fn]) => fn === 'cng_equipment_calibration_send')!
    expect(args).toEqual({ p_stock_ids: ['w3'] })
    noActor(args)
  })

  it('EQW-5 issuing a new hose sends the version read, the Station, and the hose it replaces', async () => {
    state.rows = [stock()]
    const user = userEvent.setup()
    render(<EquipmentWarehouseSection kind="hose" />)
    await user.click(await screen.findByRole('button', { name: 'Issue' }))
    await waitFor(() => expect(screen.getAllByRole('option', { name: 'الماظة' }).length).toBeGreaterThan(0))
    await user.selectOptions(screen.getByLabelText('Station'), 's1')
    await user.click(await screen.findByRole('radio', { name: /OLD-H/ }))
    await user.click(screen.getByRole('checkbox', { name: 'Emergency' }))
    await user.click(screen.getByRole('button', { name: 'Confirm issue' }))
    const [, args] = calls.rpc.find(([fn]) => fn === 'cng_equipment_issue')!
    expect(args).toEqual({
      p_stock_id: 'w1', p_expected_updated_at: '2026-10-02T10:00:00Z', p_station_id: 's1', p_unit_id: null,
      p_replace_id: 'old-1', p_emergency: true, p_notes: null,
    })
    noActor(args)
  })

  it('EQW-6 a viewer sees the stock but no Issue, Add or send controls and no tick boxes', async () => {
    state.role = 'viewer'
    state.rows = [stock(), stock({ id: 'w3', availability_status: 'available_in_store_uc' })]
    render(<EquipmentWarehouseSection kind="hose" />)
    await screen.findByRole('table', { name: /Hoses Management warehouse/i })
    expect(screen.queryByRole('button', { name: 'Issue' })).toBeNull()
    expect(screen.queryByRole('button', { name: /add hoses/i })).toBeNull()
    expect(screen.queryByRole('button', { name: /send for hydrotest/i })).toBeNull()
    expect(screen.queryByRole('checkbox', { name: 'Select row' })).toBeNull()
  })

  it('EQW-7 adding detectors with no serial yet sends a quantity; model and manufacturer, never hose pressures', async () => {
    const user = userEvent.setup()
    render(<EquipmentWarehouseSection kind="gas_detector" />)
    await user.click(await screen.findByRole('button', { name: /add gas detectors/i }))
    await user.type(screen.getByLabelText(/quantity with no serial yet/i), '3')
    await user.type(screen.getByLabelText('Manufacturer'), 'Honeywell')
    await user.type(screen.getByLabelText('Model'), 'XNX')
    await user.click(screen.getByRole('button', { name: /add 3 gas detectors/i }))
    const [, args] = calls.rpc.find(([fn]) => fn === 'cng_equipment_stock_add')!
    expect(args).toMatchObject({ p_kind: 'gas_detector', p_serials: null, p_quantity: 3, p_manufacturer: 'Honeywell', p_model: 'XNX',
      p_working_pressure: null, p_next_date: null })
    noActor(args)
  })
})

describe('Log, 3rd party, Emergency', () => {
  it('EQW-8 receiving sends only the ticked entries still at the station', async () => {
    state.rows = [
      { id: 'l1', kind: 'gas_detector', status: 'at_station', is_emergency: false, region_name: 'Delta', station_name: 'الماظة', unit_name: null,
        serial_number: 'G-OLD', manufacturer: 'Honeywell', model: 'XNX', description: null, logged_at: '2026-10-01T00:00:00Z', returned_at: null },
    ]
    const user = userEvent.setup()
    render(<EquipmentLogSection kind="gas_detector" />)
    const table = await screen.findByRole('table', { name: /Gas Detector Management Log/i })
    await user.click(within(table).getByRole('checkbox', { name: 'Select row' }))
    await user.click(screen.getByRole('button', { name: /receive at warehouse \(1\)/i }))
    expect(calls.rpc.find(([fn]) => fn === 'cng_equipment_log_receive')![1]).toEqual({ p_log_ids: ['l1'] })
  })

  it('EQW-9 a certificate needs its date; the next date is sent only when entered', async () => {
    state.rows = [{ id: 'j1', kind: 'hose', status: 'returned_awaiting_certificate', stock_id: 'w1', warehouse_code: null, serial_number: 'H-1',
      manufacturer: null, model: null, description: null, sent_at: '2026-09-01T00:00:00Z', returned_at: '2026-09-10T00:00:00Z',
      certified_at: null, certificate_date: null, certificate_number: null, next_date: null }]
    const user = userEvent.setup()
    render(<EquipmentJobsSection kind="hose" />)
    await user.click(await screen.findByRole('checkbox', { name: 'Select row' }))
    await user.click(screen.getByRole('button', { name: /certificate received \(1\)/i }))
    const save = screen.getByRole('button', { name: 'Save certificate' }) as HTMLButtonElement
    expect(save.disabled).toBe(true)
    await user.type(screen.getByLabelText('Certificate date'), '2026-09-15')
    await user.click(save)
    expect(calls.rpc.find(([fn]) => fn === 'cng_equipment_calibration_certify')![1]).toEqual({
      p_job_ids: ['j1'], p_certificate_date: '2026-09-15', p_certificate_number: null, p_next_date: null,
    })
  })

  it('EQW-10 the Emergency tab lists emergency issues with the replaced item and its state', async () => {
    state.rows = [{ id: 'e1', kind: 'hose', issued_at: '2026-10-02T08:00:00Z', notes: 'burst', region_name: 'West', station_name: 'الماظة',
      unit_name: null, stock_id: 'w1', issued_serial: 'H-NEW', issued_code: 'HS 1', manufacturer: null, model: null, description: null,
      replaced_serial: 'H-OLD', replaced_status: 'at_station' }]
    render(<EquipmentEmergencySection kind="hose" />)
    const table = await screen.findByRole('table', { name: /Hoses Management emergency issues/i })
    expect(within(table).getByText('H-OLD')).toBeDefined()
    expect(within(table).getByText('At station')).toBeDefined()
    expect(within(table).getByText('burst')).toBeDefined()
  })
})
