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
    for (const m of ['ilike', 'lte', 'gte', 'lt', 'order', 'in', 'or']) {
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

  it('COUNT-3 the counts follow the filters, including the date range picked in the calendar', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await screen.findByRole('region', { name: 'Calibration counts' })
    // One button opens the calendar; From and To live inside it (owner request 2026-09-29).
    expect(screen.queryByLabelText('From')).toBeNull()
    await user.click(screen.getByRole('button', { name: /sent:\s*any date/i }))
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

  it('COUNT-4 two clicks in the calendar make the range; no date chooser and no status box repeat other controls', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await screen.findByRole('region', { name: 'Calibration counts' })
    expect(screen.queryByLabelText('Date')).toBeNull()
    expect(screen.queryByLabelText('Status')).toBeNull()
    await user.click(screen.getByRole('button', { name: /sent:/i }))
    const days = screen.getAllByRole('button').filter((b) => /^\d{4}-\d{2}-\d{2}$/.test(b.getAttribute('aria-label') ?? ''))
    const first = days[10].getAttribute('aria-label')!, last = days[14].getAttribute('aria-label')!
    await user.click(days[14]); await user.click(days[10]) // picked backwards: read the right way round
    await waitFor(() => expect(lastRows()).toContain(`gte:sent_at=${first}`))
    const next = new Date(`${last}T00:00:00Z`); next.setUTCDate(next.getUTCDate() + 1)
    expect(lastRows()).toContain(`lt:sent_at=${next.toISOString().slice(0, 10)}`)
  })

  it('COUNT-6 the search box searches serial, code, part number and certificate together', async () => {
    const user = userEvent.setup()
    render(<SrvCalibrationSection />)
    await screen.findByRole('region', { name: 'Calibration counts' })
    await user.type(screen.getByRole('searchbox'), 'acu')
    await waitFor(() => expect(lastRows()).toContain(
      'or:serial_number.ilike.*acu*,warehouse_code.ilike.*acu*,part_number.ilike.*acu*,certificate_number.ilike.*acu*'))
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
    // The counts choose the statuses; no separate "include returned" box repeats them.
    expect(screen.queryByRole('checkbox', { name: /include valves already returned/i })).toBeNull()
  })

  it('COUNT-7 the Movement filter (out / returned) is back and agrees with the counts', async () => {
    const user = userEvent.setup()
    render(<SrvLogSection />)
    await screen.findByRole('region', { name: 'SRV Log counts' })
    const movement = screen.getByLabelText('Movement') as HTMLSelectElement
    // Only two movements to choose (owner request 2026-09-29).
    expect([...movement.options].filter((o) => !o.disabled).map((o) => o.textContent)).toEqual(['Issue', 'Return'])
    expect(movement.value).toBe('open')
    await user.selectOptions(movement, 'returned')
    await waitFor(() => expect(lastRows()).toContain('in:status=returned'))
    expect(screen.getByRole('button', { name: /^returned/i }).getAttribute('aria-pressed')).toBe('true')
    await user.selectOptions(movement, 'open')
    await waitFor(() => expect(lastRows()).toContain('in:status=at_station,location_unconfirmed'))
  })

  it('INFO-1 the explanation is hidden behind an (i) and opens on click', async () => {
    const user = userEvent.setup()
    render(<SrvLogSection />)
    await screen.findByRole('region', { name: 'SRV Log counts' })
    expect(screen.queryByText(/expected back at the warehouse/i)).toBeNull()
    await user.click(screen.getByRole('button', { name: 'About the SRV Log' }))
    expect(screen.getByRole('note').textContent).toMatch(/expected back at the warehouse/i)
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('note')).toBeNull()
  })
})
