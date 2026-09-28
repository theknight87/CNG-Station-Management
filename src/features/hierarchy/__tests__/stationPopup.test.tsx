import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it, vi } from 'vitest'

const calls: { fn: string; args: Record<string, unknown> }[] = []
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return null } }),
}))
vi.mock('@/features/units/UnitPopup', () => ({ UnitPopup: () => null }))
vi.mock('@/features/hierarchy/useHierarchy', () => ({
  useStation: () => ({
    reload: () => {},
    state: { status: 'ready', data: {
      station: { station_id: 's-1', station_name: 'TEST', region_name: 'East', units: 1, assets: 0, overdue: 0, approaching_due: 0, bay_status: null },
      units: [{ unit_id: 'u-1', unit_name: 'TEST 1', job_number: null, installed_srvs: 0, storage_vessels: 0, recovery_tanks: 0,
                gas_detectors: 0, dispensers: 0, hoses: 0, overdue: 0 }],
    } },
  }),
}))

const { StationPopupProvider, StationName } = await import('@/features/hierarchy/StationPopup')

describe('Station popup (owner request 2026-09-28)', () => {
  it('a Station name opens its hierarchy in place; an admin can delete (archive) it', async () => {
    const changed = vi.fn()
    window.addEventListener('cng:stations-changed', changed)
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    render(<MemoryRouter><StationPopupProvider><StationName id="s-1" name="TEST" /></StationPopupProvider></MemoryRouter>)
    await userEvent.click(screen.getByRole('button', { name: 'TEST' }))
    expect(await screen.findByRole('dialog')).toBeDefined()
    expect(screen.getByRole('button', { name: /TEST 1/ })).toBeDefined()
    await userEvent.click(screen.getByRole('button', { name: /delete this station/i }))
    expect(calls).toEqual([{ fn: 'cng_admin_archive_station', args: { p_station_id: 's-1' } }])
    expect(changed).toHaveBeenCalled()
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('without the provider a Station name is plain text', () => {
    render(<StationName id="s-1" name="TEST" />)
    expect(screen.queryByRole('button')).toBeNull()
    expect(screen.getByText('TEST')).toBeDefined()
  })
})
