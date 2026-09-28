import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'

const calls: { fn: string; args: Record<string, unknown> }[] = []
vi.mock('@/features/relief-valves/useSrvWorkflow', () => ({
  useIsAdmin: () => true,
  useWorkflowAction: () => ({ busy: false, run: async (fn: string, args: Record<string, unknown>) => { calls.push({ fn, args }); return null } }),
}))
vi.mock('@/features/hierarchy/useHierarchy', () => ({
  useStation: () => ({ reload: () => {}, state: { status: 'ready', data: { station: {}, units: [] } } }),
}))
const { StationUnits } = await import('@/features/hierarchy/StationUnits')

describe('Station row expanded in place (owner request 2026-09-28)', () => {
  it('an admin deletes (archives) the Station from its expanded row; the list reloads', async () => {
    vi.spyOn(window, 'confirm').mockReturnValue(true)
    const removed = vi.fn()
    render(<StationUnits stationId="s-1" stationName="TEST" onOpen={() => {}} onRemoved={removed} />)
    expect(screen.getByText(/No Unit is recorded/)).toBeDefined()
    await userEvent.click(screen.getByRole('button', { name: /delete this station/i }))
    expect(calls).toEqual([{ fn: 'cng_admin_archive_station', args: { p_station_id: 's-1' } }])
    expect(removed).toHaveBeenCalled()
  })
})
