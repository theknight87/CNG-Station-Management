import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'

import type { UnitSummary } from '@/features/hierarchy/useHierarchy'

const unit: UnitSummary = {
  unit_id: 'u-1', unit_name: 'الماظة 1', normalized_name: null, station_id: 's-1', station_name: 'الماظة',
  region_id: 'r-1', region_code: 'EAST', region_name: 'East', job_number: 'J-9', job_number_raw: 'J-9',
  dispenser_count_reported: null, hose_count_reported: null, storage_count_reported: null, notes: null,
  needs_review: false, compressors: 1, dispensers: 0, storage_vessels: 2, recovery_tanks: 0, gas_detectors: 0,
  hoses: 0, installed_srvs: 1, overdue: 0,
}

vi.mock('@/features/hierarchy/useHierarchy', () => ({
  useStation: () => ({ state: { status: 'ready', data: { station: {}, units: [unit] } }, reload: () => {} }),
}))
const SRV_ROW = {
  id: 'v-1', serial_number: 'SRV-77', serial_status: 'present', pressure_min: 275, pressure_max: 275,
  pressure_unit: 'BAR', set_pressure_raw: '275', manufacturer: 'COI', last_calibration_display: '2026-01-01',
  last_calibration_precision: 'exact_date', days_left: 40, due_status: 'due_60', part_number: 'PN-1',
  mapping_status: 'resolved', region_name: 'East', station_name: 'الماظة', unit_name: 'الماظة 1',
}
// The SRV details panel is the Installed SRVs one, read by id from v_installed_srv_management (owner request 2026-10-05).
const rpcCalls = vi.hoisted(() => ({ list: [] as { fn: string; args: unknown }[], admin: false }))
vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => (rpcCalls.admin ? { status: 'active', user: { role: 'admin' } } : null),
}))
vi.mock('@/lib/supabase/client', () => {
  const chain: Record<string, unknown> = {}
  Object.assign(chain, {
    select: () => chain, eq: () => chain, is: () => chain, or: () => chain, order: () => chain,
    maybeSingle: () => Promise.resolve({ data: SRV_ROW, error: null }),
    then: (resolve: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null }).then(resolve),
  })
  const client = {
    from: () => chain,
    rpc: (fn: string, args: unknown) => { rpcCalls.list.push({ fn, args }); return Promise.resolve({ data: [], error: null }) },
  }
  return { useSupabaseClient: () => client }
})
vi.mock('@/features/record-tools/RecordAdminTools', () => ({ RecordAdminTools: () => null }))
vi.mock('@/features/units/useUnitWorkspace', () => ({
  useUnitEquipment: (tab: string) => ({
    reload: () => {},
    state: {
      status: 'ready',
      data: tab === 'srvs'
        ? [SRV_ROW]
        : [],
    },
  }),
}))

const { StationUnits } = await import('@/features/hierarchy/StationUnits')
const { UnitPopup } = await import('@/features/units/UnitPopup')

describe('Region → Station → Unit popup (owner request 2026-09-28)', () => {
  it('a Station lists its Units; a Unit opens with equipment tabs; a row opens its own detail popup', async () => {
    const opened: UnitSummary[] = []
    render(<StationUnits stationId="s-1" onOpen={(u) => opened.push(u)} />)
    await userEvent.click(screen.getByRole('button', { name: /الماظة 1/ }))
    expect(opened[0].unit_id).toBe('u-1')

    render(<UnitPopup unit={unit} onClose={() => {}} />)
    const tabs = screen.getAllByRole('tab').map((t) => t.textContent)
    expect(tabs.join(' ')).toMatch(/SRVs.*Storage vessels.*Recovery tanks.*Gas detectors.*Dispensers.*Hoses.*Compressor/)
    const table = screen.getByRole('table', { name: 'SRVs' })
    expect(within(table).getByText('SRV-77')).toBeDefined()
    expect(within(table).queryByText('PN-1')).toBeNull()

    await userEvent.click(within(table).getByText('SRV-77'))
    expect(await screen.findByText('Part number')).toBeDefined()
    expect(screen.getByText('PN-1')).toBeDefined()

    await userEvent.click(screen.getByRole('tab', { name: /Storage vessels/ }))
    expect(screen.getByText(/No storage vessels recorded for this Unit/)).toBeDefined()
  })

  it('owner request 2026-10-05: an admin deletes (archives) a valve from the Unit window, and its details are the Installed SRVs panel', async () => {
    rpcCalls.admin = true
    rpcCalls.list = []
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
    render(<UnitPopup unit={unit} onClose={() => {}} />)
    const table = screen.getByRole('table', { name: 'SRVs' })
    await userEvent.click(within(table).getByRole('button', { name: 'Delete valve SRV-77' }))
    expect(confirm).toHaveBeenCalled()
    expect(rpcCalls.list).toContainEqual({ fn: 'cng_admin_archive_srv', args: { p_table: 'installed_relief_valves', p_id: 'v-1' } })
    expect(await screen.findByText('Relief valve deleted.')).toBeDefined()

    await userEvent.click(within(screen.getByRole('table', { name: 'SRVs' })).getByText('SRV-77'))
    // The same facts and actions as Installed SRVs: warehouse code, Station, history and the delete button.
    expect(await screen.findByText('Warehouse code')).toBeDefined()
    expect(screen.getByText('Station')).toBeDefined()
    expect(screen.getByRole('button', { name: 'Delete this relief valve' })).toBeDefined()
    confirm.mockRestore()
    rpcCalls.admin = false
  })
})
