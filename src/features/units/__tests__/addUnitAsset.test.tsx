import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'

const calls: { fn: string; args: Record<string, unknown> }[] = []
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return null } }),
}))
const { AddUnitAssetButton } = await import('@/features/units/AddUnitAsset')

describe('Add equipment to a Unit (owner request 2026-09-28)', () => {
  it('sends the kind, the Unit and only what was typed; one set pressure fills min and max; placement is never sent', async () => {
    const added = vi.fn()
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="شبرا 3" onAdded={added} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    await userEvent.type(screen.getByLabelText(/^serial$/i), 'S-9')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '275')
    await userEvent.type(screen.getByLabelText(/^last calibration/i), '2026-03-10')
    expect(screen.queryByLabelText(/^next calibration/i)).toBeNull()
    await userEvent.click(screen.getAllByRole('button', { name: /add relief valve/i }).at(-1)!)
    expect(calls[0].fn).toBe('cng_admin_add_unit_asset')
    expect(calls[0].args.p_kind).toBe('srv')
    expect(calls[0].args.p_unit_id).toBe('u-1')
    const p = calls[0].args.p as Record<string, unknown>
    expect(p).toMatchObject({ serial_number: 'S-9', pressure_min: 275, pressure_max: 275, pressure_unit: 'BAR', manufacturer: '',
      last_date: '2026-03-10', next_date: '2027-03-10' })
    expect(Object.keys(p)).not.toContain('station_id')
    expect(Object.keys(p)).not.toContain('region_id')
    expect(added).toHaveBeenCalled()
  })

  it('a gas detector takes only the last calibration; the next is one year later', async () => {
    calls.length = 0
    render(<AddUnitAssetButton kind="gas_detector" unitId="u-1" unitName="U" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add gas detector/i }))
    expect(screen.queryByLabelText(/^next calibration/i)).toBeNull()
    await userEvent.type(screen.getByLabelText(/^last calibration/i), '2026-01-15')
    await userEvent.click(screen.getAllByRole('button', { name: /add gas detector/i }).at(-1)!)
    expect(calls[0].args.p).toMatchObject({ last_date: '2026-01-15', next_date: '2027-01-15' })
  })

  it('a hose with no working pressure sends no unit for it', async () => {
    calls.length = 0
    render(<AddUnitAssetButton kind="hose" unitId="u-1" unitName="U" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add hose/i }))
    await userEvent.click(screen.getAllByRole('button', { name: /add hose/i }).at(-1)!)
    expect((calls[0].args.p as Record<string, unknown>).working_pressure_unit).toBeNull()
  })
})
