import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Owner request 2026-09-29: the Calibration (3rd party) and SRV Log tabs show a count per status that follows the
 * filters, and each count is a button that shows its rows. Also: the date filter reaches the database query.
 */

const COUNTS: Record<string, number> = { sent: 7, returned_awaiting_certificate: 3, certified: 12, at_station: 4, location_unconfirmed: 1, returned: 9 }
const queries = vi.hoisted(() => ({ list: [] as string[][] }))

vi.mock('@/hooks/useAppUser', () => ({ useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: 'viewer' } }) }))

const client = {
  rpc: vi.fn(async () => ({ data: [], error: null })),
  from: (table: string) => {
    const log: string[] = [table]
    queries.list.push(log)
    let head = false
    let status: string | null = null
    const q: Record<string, unknown> = {}
    for (const m of ['ilike', 'lte', 'gte', 'lt', 'order', 'in']) {
      q[m] = (...a: unknown[]) => { log.push(`${m}:${a.map(String).join('=')}`); return q }
    }
    q.select = (_c: string, opts?: { head?: boolean }) => { head = Boolean(opts?.head); log.push(head ? 'head' : 'rows'); return q }
    q.eq = (c: string, v: string) => { log.push(`eq:${c}=${v}`); if (c === 'status') status = v; return q }
    q.range = async () => ({ data: [], error: null, count: 0 })
    q.then = (resolve: (v: unknown) => unknown) =>
      Promise.resolve(head ? { data: null, error: null, count: status ? COUNTS[status] ?? 0 : 0 } : { data: [], error: null }).then(resolve)
    return q
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { SrvCalibrationSection, SrvLogSection } = await import('@/features/relief-valves/sections/SrvWorkflowSections')

beforeEach(() => { queries.list.length = 0 })

const rowQueries = () => queries.list.filter((q) => q.includes('rows'))
const lastRows = () => rowQueries().at(-1)!

describe('Calibration count strip', () => {
  it('COUNT-1 shows one count per status, the open total and the grand total', async () => {
    render(<SrvCalibrationSection />)
    const strip = await screen.findByRole('region', { name: 'Calibration counts' })
    await waitFor(() => expect(strip.textContent).toContain('10'))
    expect(strip.textContent).toMatch(/Not yet certified\s*10/)
    expect(strip.textContent).toMatch(/At the company\s*7/)
    expect(strip.textContent).toMatch(/Certificate awaited\s*3/)
    expect(strip.textContent).toMatch(/Certified\s*12/)
    expect(strip.textContent).toMatch(/All entries\s*22/)
    // The open view is the default and is marked pressed.
    expect(screen.getByRole('button', { name: /not yet certified/i }).getAttribute('aria-pressed')).toBe('true')
  })

  it('COUNT-2 clicking a count shows that status in the table', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await user.click(await screen.findByRole('button', { name: /^certified/i }))
    await waitFor(() => expect(lastRows()).toContain('in:status=certified'))
    expect(screen.getByRole('button', { name: /^certified/i }).getAttribute('aria-pressed')).toBe('true')
    await user.click(screen.getByRole('button', { name: /all entries/i }))
    await waitFor(() => expect(lastRows().some((c) => c.startsWith('in:status'))).toBe(false))
  })

  it('COUNT-3 the counts follow the filters, including the date range', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await screen.findByRole('region', { name: 'Calibration counts' })
    await user.type(screen.getByLabelText('From'), '2026-09-01')
    await user.type(screen.getByLabelText('To'), '2026-09-30')
    await waitFor(() => {
      const counts = queries.list.filter((q) => q.includes('head') && q.includes('lt:sent_at=2026-10-01'))
      expect(counts.length).toBe(3)
      expect(counts.every((q) => q.includes('gte:sent_at=2026-09-01'))).toBe(true)
    })
    expect(lastRows()).toContain('lt:sent_at=2026-10-01')
    expect(screen.getByText('Counts follow the filters below.')).toBeDefined()
  })

  it('COUNT-4 the date filter can use another date: the certificate date', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await screen.findByRole('region', { name: 'Calibration counts' })
    await user.selectOptions(screen.getByLabelText('Date'), 'certificate_date')
    await user.type(screen.getByLabelText('From'), '2026-01-01')
    await waitFor(() => expect(lastRows()).toContain('gte:certificate_date=2026-01-01'))
    expect(lastRows().some((c) => c.includes('sent_at=2026'))).toBe(false)
  })
})

describe('SRV Log count strip', () => {
  it('COUNT-5 shows awaiting-return and per-status counts; Returned shows returned rows', async () => {
    const user = userEvent.setup()
    render(<SrvLogSection />)
    const strip = await screen.findByRole('region', { name: 'SRV Log counts' })
    await waitFor(() => expect(strip.textContent).toMatch(/Awaiting return\s*5/))
    expect(strip.textContent).toMatch(/All entries\s*14/)
    await user.click(screen.getByRole('button', { name: /^returned/i }))
    await waitFor(() => expect(lastRows()).toContain('in:status=returned'))
    // The "Include valves already returned" box agrees with the view chosen.
    expect((screen.getByRole('checkbox', { name: /include valves already returned/i }) as HTMLInputElement).checked).toBe(true)
  })
})
