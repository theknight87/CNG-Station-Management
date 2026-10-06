import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import type { IssueSheetRow } from '@/features/export/issueSheet'

/**
 * The Issue sheet dialog (owner request 2026-10-03): it says what is already sent and what a new export adds, places
 * only the unsent valves (one RPC, never when nothing is new), and downloads the month's workbook.
 */

const base = {
  region_id: 'r-east', region_name: 'East', sheet_exported_at: null, is_emergency: false, station_name: 'S', unit_name: 'S 1',
  place_name: 'S 1', location: 'Stage', warehouse_valve_id: 'w', issued_serial: null, issued_code: null, manufacturer: null,
  size_type: null, inlet_size: null, outlet_size: null, set_pressure_raw: null, pressure_min: null, pressure_max: null,
  pressure_unit: null, replaced_installed_valve_id: null, replaced_serial: null, replaced_returned_at: null,
  is_cancelled: false, cancelled_at: null, cancelled_returned_at: null, transferred_to: null, transferred_at: null,
}
const state = vi.hoisted(() => ({ rows: [] as IssueSheetRow[], rpc: [] as unknown[], downloads: [] as string[], query: [] as string[] }))

const client = {
  from: (view: string) => {
    state.query.push(view)
    const q: Record<string, unknown> = {}
    for (const m of ['select', 'eq', 'gte', 'lt', 'order']) q[m] = (...a: unknown[]) => { state.query.push(`${m}:${a.join(',')}`); return q }
    q.limit = async () => ({ data: state.rows, error: null })
    return q
  },
  rpc: async (fn: string, args: unknown) => {
    state.rpc.push({ fn, args })
    state.rows = state.rows.map((r) => (r.sheet_id ? r : { ...r, sheet_id: 's-new', sheet_seq: 2 }))
    return { data: 2, error: null }
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))
vi.mock('@/features/reports/useHierarchyOptions', () => ({
  useRegionOptions: () => [{ id: 'r-east', label: 'East' }, { id: 'r-west', label: 'West' }],
}))
vi.mock('@/features/reports/csv', () => ({ cairoBusinessDate: () => '2026-10-05' }))
vi.mock('@/features/export/exportData', () => ({ downloadBlob: (name: string) => { state.downloads.push(name) } }))
vi.mock('@/features/export/issueSheet', async (orig) => ({
  ...(await orig<typeof import('@/features/export/issueSheet')>()),
  buildIssueWorkbook: async () => new Blob(['x']),
}))

const { IssueSheetDialog } = await import('@/features/relief-valves/IssueSheetDialog')

beforeEach(() => {
  state.rpc = []; state.downloads = []; state.query = []
  state.rows = [
    { ...base, id: 'a', issued_at: '2026-10-05T07:00:00Z', issue_day: '2026-10-05', sheet_id: 's1', sheet_seq: 1 },
    { ...base, id: 'b', issued_at: '2026-10-05T10:00:00Z', issue_day: '2026-10-05', sheet_id: null, sheet_seq: null },
    { ...base, id: 'c', issued_at: '2026-10-05T10:05:00Z', issue_day: '2026-10-05', sheet_id: null, sheet_seq: null },
  ]
})

describe('Issue sheet dialog', () => {
  it('ISD-1 the Region filter is the default; it shows what is already sent and the new sheet "(2)"', async () => {
    render(<IssueSheetDialog open regionFilter="r-east" onClose={() => {}} onDone={() => {}} />)
    expect(await screen.findByText(/1 sheet\(s\), 1 valve\(s\)/)).toBeDefined()
    expect(screen.getByText('East 5-10-2026 (2)')).toBeDefined()
    expect(screen.getByText(/— 2 valve\(s\)/)).toBeDefined()
    expect(state.query).toContain('v_srv_issue_sheet')
    expect(state.query).toContain('gte:issue_day,2026-10-01')
    expect(state.query).toContain('lt:issue_day,2026-11-01')
  })

  it('ISD-2 export places the unsent valves once, then downloads the month workbook', async () => {
    const onDone = vi.fn()
    render(<IssueSheetDialog open regionFilter="r-east" onClose={() => {}} onDone={onDone} />)
    await screen.findByText('East 5-10-2026 (2)')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Export workbook' }))
    await waitFor(() => expect(state.downloads).toEqual(['صرف شرق 10-2026.xlsx']))
    expect(state.rpc).toEqual([{ fn: 'cng_srv_issue_sheet_assign', args: { p_region_id: 'r-east', p_month: '2026-10-01' } }])
    expect(onDone).toHaveBeenCalledWith('Workbook downloaded: 2 sheet(s); 2 valve(s) placed in new sheet(s).')
  })

  it('ISD-3 with nothing new the sheets already sent are downloaded again and nothing is placed', async () => {
    state.rows = state.rows.slice(0, 1)
    render(<IssueSheetDialog open regionFilter="r-east" onClose={() => {}} onDone={() => {}} />)
    expect(await screen.findByText(/nothing since the last export/)).toBeDefined()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Export workbook' }))
    await waitFor(() => expect(state.downloads).toHaveLength(1))
    expect(state.rpc).toEqual([])
  })

  it('ISD-5 valves undone after leaving the warehouse are said to stay on their sheet, marked cancelled', async () => {
    state.rows = [...state.rows, { ...state.rows[0], id: 'z', is_cancelled: true, cancelled_at: '2026-10-06T08:00:00Z' }]
    render(<IssueSheetDialog open regionFilter="r-east" onClose={() => {}} onDone={() => {}} />)
    expect(await screen.findByText(/1 valve\(s\) — kept on their sheet, marked ملغي/)).toBeDefined()
  })

  it('ISD-4 with several Regions in the filter nothing is chosen for the user', async () => {
    render(<IssueSheetDialog open regionFilter="r-east|r-west" onClose={() => {}} onDone={() => {}} />)
    expect(screen.getByText('Choose the Region to export.')).toBeDefined()
    expect((screen.getByRole('button', { name: 'Export workbook' }) as HTMLButtonElement).disabled).toBe(true)
  })
})
