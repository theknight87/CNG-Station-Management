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
  it('sends the Unit, the serial and only what was typed; one set pressure fills min and max; placement is never sent', async () => {
    calls.length = 0
    const added = vi.fn()
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="شبرا 3" onAdded={added} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    await userEvent.type(screen.getByLabelText(/^serials/i), 'S-9')
    await userEvent.type(screen.getByLabelText(/^set pressure/i), '275')
    await userEvent.type(screen.getByLabelText(/^last calibration/i), '2026-03-10')
    expect(screen.queryByLabelText(/^next calibration/i)).toBeNull()
    await userEvent.click(screen.getAllByRole('button', { name: /add relief valve/i }).at(-1)!)
    expect(calls[0].fn).toBe('cng_admin_add_unit_srvs')
    expect(calls[0].args.p_unit_id).toBe('u-1')
    expect(calls[0].args.p_serials).toEqual(['S-9'])
    const p = calls[0].args.p as Record<string, unknown>
    expect(p).toMatchObject({ pressure_min: 275, pressure_max: 275, pressure_unit: 'BAR', manufacturer: '',
      last_date: '2026-03-10', next_date: '2027-03-10' })
    expect(p.serial_number).toBeUndefined()
    expect(Object.keys(p)).not.toContain('station_id')
    expect(Object.keys(p)).not.toContain('region_id')
    expect(added).toHaveBeenCalled()
  })

  it('owner request 2026-10-05: several serials at once (lines or commas) add one valve each, in one call', async () => {
    calls.length = 0
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="شطا" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    await userEvent.type(screen.getByLabelText(/^serials/i), '21-07737{enter}21-05208, 21-07424{enter}')
    expect(screen.getByRole('list', { name: /where each serial is now/i }).textContent).toContain('21-05208')
    await userEvent.click(screen.getByRole('button', { name: 'Add 3 relief valves' }))
    expect(calls).toHaveLength(1)
    expect(calls[0].fn).toBe('cng_admin_add_unit_srvs')
    expect(calls[0].args.p_serials).toEqual(['21-07737', '21-05208', '21-07424'])
  })

  it('a serial typed twice is shown and refused before anything is sent; no serial adds one valve without one', async () => {
    calls.length = 0
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="U" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    await userEvent.type(screen.getByLabelText(/^serials/i), 'A-1{enter}a-1')
    expect(screen.getByText('typed twice')).toBeDefined()
    expect((screen.getByRole('button', { name: 'Add 2 relief valves' }) as HTMLButtonElement).disabled).toBe(true)
    await userEvent.clear(screen.getByLabelText(/^serials/i))
    await userEvent.click(screen.getAllByRole('button', { name: /add relief valve/i }).at(-1)!)
    expect(calls[0].fn).toBe('cng_admin_add_unit_asset')
    expect(calls[0].args.p_kind).toBe('srv')
  })

  it('owner request 2026-10-05: the manufacturer offers the list of manufacturers', async () => {
    render(<AddUnitAssetButton kind="srv" unitId="u-1" unitName="U" onAdded={() => {}} />)
    await userEvent.click(screen.getByRole('button', { name: /add relief valve/i }))
    const maker = screen.getByLabelText(/^manufacturer/i) as HTMLInputElement
    const list = document.getElementById(maker.getAttribute('list') ?? '')
    const names = Array.from(list?.querySelectorAll('option') ?? []).map((o) => o.getAttribute('value'))
    expect(names).toEqual(expect.arrayContaining(['Mercer', 'Anderson', 'DK-LOK', 'Technical', 'COI']))
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
