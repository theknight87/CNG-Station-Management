import { render, renderHook, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { UnitSummary } from '@/features/hierarchy/useHierarchy'

/**
 * Owner requests 2026-10-03: a Replace button beside every relief valve in the Unit window (no need to open the valve
 * first), valves listed lowest set pressure first, and the Station's shared storage counted once on the Station row.
 */
const state = vi.hoisted(() => ({ admin: true, sharedCount: 4 as number | null }))

vi.mock('@/features/relief-valves/useSrvWorkflow', async (orig) => ({
  ...(await orig<Record<string, unknown>>()),
  useIsAdmin: () => state.admin,
}))
vi.mock('@/features/relief-valves/ReplaceValvePanel', () => ({
  ReplaceValvePanel: ({ valve, startOpen }: { valve: { serial_number: string }; startOpen?: boolean }) =>
    <p>replace form for {valve.serial_number}{startOpen ? ' (open)' : ''}</p>,
}))
vi.mock('@/features/record-tools/RecordAdminTools', () => ({ RecordAdminTools: () => null }))

const full = { serial_status: 'present', pressure_min: null, set_pressure_raw: null, manufacturer: null, last_calibration_display: null,
  last_calibration_precision: 'unknown', days_left: null, due_status: 'unknown' }
const rows = [
  { id: 'a', serial_number: 'HIGH', pressure_max: 300, pressure_unit: 'BAR' },
  { id: 'b', serial_number: 'PSI-LOW', pressure_max: 100, pressure_unit: 'PSI' },
  { id: 'c', serial_number: 'NONE', pressure_max: null, pressure_unit: null },
  { id: 'd', serial_number: 'MID', pressure_max: 35, pressure_unit: 'BAR' },
]
const client = {
  from: (table: string) => {
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'is', 'or']) q[m] = () => q
    q.order = async () => ({ data: table === 'v_unit_srvs' ? rows.map((r) => ({ ...full, ...r })) : [], error: null })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve({ data: [], error: state.sharedCount === null ? { message: 'x' } : null, count: state.sharedCount }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const unit: UnitSummary = {
  unit_id: 'u-1', unit_name: 'الماظة 1', normalized_name: null, station_id: 's-1', station_name: 'الماظة',
  region_id: 'r-1', region_code: 'EAST', region_name: 'East', job_number: null, job_number_raw: null,
  dispenser_count_reported: null, hose_count_reported: null, storage_count_reported: null, notes: null,
  needs_review: false, compressors: 1, dispensers: 0, storage_vessels: 1, recovery_tanks: 0, gas_detectors: 0,
  hoses: 0, installed_srvs: 4, overdue: 7,
}
vi.mock('@/features/hierarchy/useHierarchy', () => ({
  useStation: () => ({ state: { status: 'ready', data: { station: {}, units: [unit, { ...unit, unit_id: 'u-2', unit_name: 'الماظة 2' }] } }, reload: () => {} }),
}))

const { UnitPopup } = await import('@/features/units/UnitPopup')
const { StationUnits } = await import('@/features/hierarchy/StationUnits')
const { useUnitEquipment } = await import('@/features/units/useUnitWorkspace')

beforeEach(() => { state.admin = true; state.sharedCount = 4 })

describe('Unit window relief valves', () => {
  it('UPR-1 valves read lowest set pressure first (PSI on the BAR scale), unrecorded pressure last', async () => {
    const { result } = renderHook(() => useUnitEquipment<{ serial_number: string }>('srvs', 'u-1'))
    await waitFor(() => expect(result.current.state.status).toBe('ready'))
    const s = result.current.state
    expect(s.status === 'ready' && s.data.map((r) => r.serial_number)).toEqual(['PSI-LOW', 'MID', 'HIGH', 'NONE'])
  })

  it('UPR-2 an admin replaces a valve straight from its row, without opening the valve', async () => {
    const user = userEvent.setup()
    render(<UnitPopup unit={unit} onClose={() => {}} />)
    const table = await screen.findByRole('table', { name: 'SRVs' })
    await user.click(within(table).getByRole('button', { name: 'Replace valve MID' }))
    expect(await screen.findByText('replace form for MID (open)')).toBeDefined()
    // The valve's own detail window did not open.
    expect(screen.queryByText('Part number')).toBeNull()
  })

  it('UPR-3 a viewer gets no Replace column', async () => {
    state.admin = false
    render(<UnitPopup unit={unit} onClose={() => {}} />)
    const table = await screen.findByRole('table', { name: 'SRVs' })
    expect(within(table).queryByRole('button', { name: /^Replace/ })).toBeNull()
    expect(within(table).queryByText('Replace')).toBeNull()
  })
})

describe('Station row: shared storage counted once', () => {
  it('UPR-4 each Unit shows its own overdue; the shared storage is one line', async () => {
    render(<StationUnits stationId="s-1" onOpen={() => {}} />)
    expect(await screen.findByText('Station storage')).toBeDefined()
    expect(screen.getAllByText('3 overdue')).toHaveLength(2)
    expect(screen.getByText('4 overdue')).toBeDefined()
    expect(screen.queryByText('7 overdue')).toBeNull()
  })

  it('UPR-5 when the shared count cannot be read, each Unit keeps its full figure and no shared line is shown', async () => {
    state.sharedCount = null
    render(<StationUnits stationId="s-1" onOpen={() => {}} />)
    await waitFor(() => expect(screen.getAllByText('7 overdue')).toHaveLength(2))
    expect(screen.queryByText('Station storage')).toBeNull()
  })
})
