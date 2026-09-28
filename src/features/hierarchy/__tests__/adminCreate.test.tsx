import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const calls: { fn: string; args: Record<string, unknown> }[] = []
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return null } }),
}))
vi.mock('@/features/hierarchy/useHierarchy', () => ({
  useRegions: () => ({ state: { status: 'ready', data: [{ region_id: 'r-east', region_name: 'East' }] }, reload: () => {} }),
}))

const { AddStationButton } = await import('@/features/hierarchy/AddStationDialog')
const { AddWarehouseSrvsButton } = await import('@/features/relief-valves/AddWarehouseSrvs')

describe('Admin create forms (owner request 2026-09-28)', () => {
  beforeEach(() => { calls.length = 0 })

  it('Add Station sends the Region, the Station and its named Units; empty values stay empty; no actor is sent', async () => {
    const created = vi.fn()
    render(<AddStationButton regionId="r-east" onCreated={created} />)
    await userEvent.click(screen.getByRole('button', { name: /add station/i }))
    await userEvent.type(screen.getByLabelText(/^station name$/i), 'محطة جديدة')
    await userEvent.type(screen.getByLabelText(/^unit name$/i), 'محطة جديدة 1')
    await userEvent.type(screen.getByLabelText(/^dispensers$/i), '2')
    await userEvent.click(screen.getByRole('button', { name: /add unit/i }))
    await userEvent.click(screen.getByRole('button', { name: /create station/i }))
    expect(calls).toHaveLength(1)
    expect(calls[0].fn).toBe('cng_admin_create_station')
    expect(calls[0].args).toEqual({
      p_region_id: 'r-east', p_station_name: 'محطة جديدة', p_bay_status: null, p_notes: null,
      p_units: [{ unit_name: 'محطة جديدة 1', job_number: null, dispensers: 2, hoses: null, storage_vessels: null }],
    })
    expect(JSON.stringify(calls[0].args)).not.toMatch(/actor|user_id|created_by/)
    expect(created).toHaveBeenCalled()
  })

  it('Add relief valves: one per serial line, a pressure range, and the condition', async () => {
    render(<AddWarehouseSrvsButton onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valves/i }))
    await userEvent.selectOptions(screen.getByLabelText(/^condition$/i), 'available_calibrated')
    await userEvent.type(screen.getByLabelText(/^serials/i), 'A-1{enter}A-2')
    await userEvent.type(screen.getByLabelText(/^set pressure$/i), '270-280')
    await userEvent.click(screen.getByRole('button', { name: /add 2 valves/i }))
    const p = calls[0].args.p as Record<string, unknown>
    expect(calls[0].fn).toBe('cng_admin_add_warehouse_srvs')
    expect(p).toMatchObject({ availability: 'available_calibrated', serials: ['A-1', 'A-2'], quantity: null,
      pressure_min: 270, pressure_max: 280, pressure_unit: 'BAR', last_calibration_date: null })
    expect(await screen.findByText(/2 relief valve\(s\) added/)).toBeDefined()
  })
})
