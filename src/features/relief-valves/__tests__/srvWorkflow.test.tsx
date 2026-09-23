import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({ role: 'admin', rows: [] as unknown[], rpcError: null as null | { code: string; message: string } }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]>, from: [] as string[] }))

vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }),
}))

const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    if (fn === 'cng_srv_replacement_candidates') {
      return { data: [{ id: 'old-1', serial_number: 'OLD-9', pressure_min: 90, pressure_max: 90, pressure_unit: 'BAR',
        set_pressure_raw: '90', size_type: 'Male', inlet_size: '1/2"', outlet_size: '3/4"', warehouse_code: null,
        location_raw: 'Stage', unit_name: null, station_confirmed: true, next_calibration_date: null }], error: null }
    }
    if (fn === 'cng_srv_valve_history') return { data: [], error: null }
    return state.rpcError ? { data: null, error: state.rpcError } : { data: 1, error: null }
  }),
  from: (table: string) => {
    calls.from.push(table)
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'in', 'ilike', 'lte', 'gte', 'order']) q[m] = () => q
    q.range = async () => ({ data: state.rows, error: null, count: state.rows.length })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve({
        data: table === 'stations' ? [{ id: 's1', station_name: 'الماظة' }]
          : table === 'units' ? [{ id: 'unit-1', unit_name: 'الماظة' }] : [],
        error: null,
      }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { SrvLogSection, SrvCalibrationSection } = await import('@/features/relief-valves/sections/SrvWorkflowSections')
const { IssuePanel } = await import('@/features/relief-valves/SrvWorkflowPieces')

const valve = { serial_number: 'S-1', manufacturer: null, part_number: null, warehouse_code: 'sbc 2', size_type: 'Male',
  inlet_size: '1/2"', outlet_size: '3/4"', set_pressure_raw: '90', pressure_min: 90, pressure_max: 90, pressure_unit: 'BAR' }

beforeEach(() => {
  state.role = 'admin'; state.rows = []; state.rpcError = null
  calls.rpc.length = 0; calls.from.length = 0
})

describe('SRV Log', () => {
  it('WF-1 lists only valves not yet returned by default, and receiving sends only the ticked ids', async () => {
    state.rows = [
      { ...valve, id: 'l1', reason: 'reconcile_other_serial', status: 'location_unconfirmed', is_emergency: false, station_display: 'الماظة', logged_at: '2026-09-23T00:00:00Z' },
      { ...valve, id: 'l2', serial_number: 'S-2', reason: 'replaced_on_issue', status: 'at_station', is_emergency: true, station_display: 'الماظة', logged_at: '2026-09-23T00:00:00Z' },
    ]
    const user = userEvent.setup()
    render(<SrvLogSection />)
    const table = await screen.findByRole('table', { name: 'SRV Log' })
    expect(within(table).getByText(/At station — awaiting return · Emergency/)).toBeDefined()
    await user.click(within(table).getAllByRole('checkbox', { name: 'Select row' })[1])
    await user.click(screen.getByRole('button', { name: /arrived at warehouse \(1\)/i }))
    expect(calls.rpc.find(([fn]) => fn === 'cng_srv_log_receive')![1]).toEqual({ p_log_ids: ['l2'] })
  })

  it('WF-2 a viewer sees the log but no tick boxes and no receive button', async () => {
    state.role = 'viewer'
    state.rows = [{ ...valve, id: 'l1', reason: 'reconcile_station_not_found', status: 'location_unconfirmed', is_emergency: false, station_display: 'X', logged_at: '2026-09-23T00:00:00Z' }]
    render(<SrvLogSection />)
    await screen.findByRole('table', { name: 'SRV Log' })
    expect(screen.queryByRole('checkbox', { name: 'Select row' })).toBeNull()
    expect(screen.queryByRole('button', { name: /arrived at warehouse/i })).toBeNull()
  })
})

describe('Calibration (3rd party)', () => {
  it('WF-3 select all, then certify with the certificate date', async () => {
    state.rows = [
      { ...valve, id: 'j1', status: 'sent', warehouse_valve_id: 'w1', sent_at: '2026-09-01T00:00:00Z' },
      { ...valve, id: 'j2', status: 'returned_awaiting_certificate', warehouse_valve_id: 'w2', sent_at: '2026-09-01T00:00:00Z', returned_at: '2026-09-10T00:00:00Z' },
    ]
    const user = userEvent.setup()
    const { container } = render(<SrvCalibrationSection />)
    await user.click(await screen.findByRole('checkbox', { name: 'Select all' }))
    // "Returned — certificate awaited" only applies when every ticked valve is still at the company.
    expect((screen.getByRole('button', { name: /returned — certificate awaited \(2\)/i }) as HTMLButtonElement).disabled).toBe(true)
    const certify = screen.getByRole('button', { name: /returned with certificate \(2\)/i }) as HTMLButtonElement
    expect(certify.disabled).toBe(true)
    await user.type(container.querySelector('input[type=date]') as HTMLInputElement, '2026-09-15')
    await user.click(certify)
    expect(calls.rpc.find(([fn]) => fn === 'cng_srv_calibration_certify')![1]).toEqual({
      p_job_ids: ['j1', 'j2'], p_certificate_date: '2026-09-15', p_certificate_number: null, p_next_calibration_date: null,
    })
  })
})

describe('Issue from warehouse', () => {
  const row = { ...valve, id: 'w9', availability_status: 'available_calibrated', updated_at: '2026-09-23T10:00:00Z' } as never

  it('WF-4 choosing the Unit offers same-pressure valves; the payload carries the version read and no actor', async () => {
    const user = userEvent.setup()
    const onDone = vi.fn()
    render(<IssuePanel row={row} onDone={onDone} />)
    await user.click(screen.getByRole('button', { name: /issue from warehouse/i }))
    await waitFor(() => expect(screen.getAllByRole('option', { name: 'الماظة' }).length).toBeGreaterThan(0))
    await user.selectOptions(screen.getByLabelText('Station'), 's1')
    await waitFor(() => expect(screen.getByLabelText('Unit').querySelectorAll('option').length).toBe(2))
    await user.selectOptions(screen.getByLabelText('Unit'), 'unit-1')
    await user.click(await screen.findByRole('radio', { name: /OLD-9/ }))
    await user.click(screen.getByRole('checkbox', { name: 'Emergency' }))
    await user.click(screen.getByRole('button', { name: /confirm issue/i }))
    const issue = calls.rpc.find(([fn]) => fn === 'cng_srv_issue')![1]
    expect(issue).toEqual({
      p_warehouse_valve_id: 'w9', p_expected_updated_at: '2026-09-23T10:00:00Z', p_unit_id: 'unit-1',
      p_replace_installed_valve_id: 'old-1', p_emergency: true, p_notes: null,
    })
    for (const k of ['actor', 'issued_by', 'app_user', 'service_role']) expect(JSON.stringify(issue)).not.toContain(k)
    await waitFor(() => expect(onDone).toHaveBeenCalled())
  })

  it('WF-5 an under-calibration valve cannot be issued, and a 409 is explained without retrying', async () => {
    const { rerender } = render(<IssuePanel row={{ ...(row as object), availability_status: 'available_in_store_uc' } as never} onDone={() => {}} />)
    expect(screen.getByText(/only a new or calibrated valve can be issued/i)).toBeDefined()
    state.rpcError = { code: 'PT409', message: 'stale_write: this record changed since you loaded it' }
    rerender(<IssuePanel row={row} onDone={() => {}} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /issue from warehouse/i }))
    await user.selectOptions(await screen.findByLabelText('Station'), 's1')
    await waitFor(() => expect(screen.getByLabelText('Unit').querySelectorAll('option').length).toBe(2))
    await user.selectOptions(screen.getByLabelText('Unit'), 'unit-1')
    await user.click(screen.getByRole('button', { name: /confirm issue/i }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/Nothing was changed/)
    expect(calls.rpc.filter(([fn]) => fn === 'cng_srv_issue')).toHaveLength(1)
  })
})
