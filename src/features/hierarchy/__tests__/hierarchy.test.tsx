import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * Hierarchy browsing: Regions, Stations, Station detail, Unit boundary.
 *
 * What these tests defend, in order of how badly it would hurt to get wrong:
 *
 * 1. **A failed query is never an empty result.** "No Stations" when the
 *    database refused is a lie an engineer will act on.
 * 2. **Region scope is a database boundary.** The view asks PostgreSQL and
 *    renders what comes back; it never filters by region in JavaScript, and
 *    the pagination total is whatever the RLS-scoped count said.
 * 3. **The three zero-row answers stay distinct** - nothing exists, nothing
 *    matches the filters, or the query failed.
 * 4. **NULL is shown as "not recorded"**, never as N/A, Unknown, - or 0.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  regions: { data: [] as unknown[], error: null } as Reply,
  stations: { data: [] as unknown[], error: null, count: 0 } as Reply,
  stationsUnfilteredCount: { data: null, error: null, count: 0 } as Reply,
  units: { data: [] as unknown[], error: null } as Reply,
  station: { data: null as unknown, error: null } as Reply,
  unit: { data: null as unknown, error: null } as Reply,
}))

/** Records what the view actually asked the database for. */
const calls = vi.hoisted(() => ({ list: [] as string[] }))

vi.mock('@/lib/supabase/client', () => {
  // One STABLE client object, like the real singleton. A fresh object per
  // render would change the effect dependency forever and spin the hook.
  const client = {
    from(table: string) {
      const chain: Record<string, unknown> = {}
      let head = false
      const settle = () => {
        if (table === 'v_dashboard_region_summary') return replies.regions
        if (table === 'v_unit_summary') return replies.units
        if (head) return replies.stationsUnfilteredCount
        return replies.stations
      }
      const record = (op: string) => calls.list.push(`${table}.${op}`)
      Object.assign(chain, {
        select: (_cols?: string, opts?: { head?: boolean }) => {
          head = Boolean(opts?.head)
          return chain
        },
        eq: (col: string) => {
          record(`eq:${col}`)
          return chain
        },
        gt: (col: string) => {
          record(`gt:${col}`)
          return chain
        },
        or: (expr: string) => {
          record(`or:${expr}`)
          return chain
        },
        order: (col: string) => {
          record(`order:${col}`)
          return chain
        },
        range: (from: number, to: number) => {
          record(`range:${from}-${to}`)
          return Promise.resolve(settle())
        },
        maybeSingle: () =>
          Promise.resolve(table === 'v_unit_summary' ? replies.unit : replies.station),
        then: (resolve: (v: unknown) => unknown) => Promise.resolve(settle()).then(resolve),
      })
      return chain
    },
  }
  return { useSupabaseClient: () => client }
})

const { RegionsView } = await import('@/features/regions/RegionsView')
const { StationsView } = await import('@/features/stations/StationsView')
const { StationOverview } = await import('@/features/stations/StationOverview')

const EAST = {
  region_id: 'r-east',
  region_code: 'east',
  region_name: 'East',
  sort_order: 1,
  stations: 42,
  units: 61,
  assets: 1180,
  overdue: 47,
  approaching_due: 133,
  unresolved_mapping: 612,
}

function station(over: Partial<Record<string, unknown>> = {}) {
  return {
    station_id: 's-1',
    station_name: 'الماظة',
    normalized_name: 'الماظه',
    region_id: 'r-east',
    region_code: 'east',
    region_name: 'East',
    region_sort_order: 1,
    bay_status: null,
    bay_status_raw: null,
    notes: null,
    needs_review: false,
    review_reason: null,
    units: 2,
    assets: 120,
    overdue: 3,
    approaching_due: 5,
    unresolved_mapping: 0,
    ...over,
  }
}

function unit(over: Partial<Record<string, unknown>> = {}) {
  return {
    unit_id: 'u-1',
    unit_name: 'الماظة 1',
    normalized_name: 'الماظه 1',
    station_id: 's-1',
    station_name: 'الماظة',
    region_id: 'r-east',
    region_code: 'east',
    region_name: 'East',
    job_number: null,
    job_number_raw: null,
    dispenser_count_reported: null,
    hose_count_reported: null,
    storage_count_reported: null,
    notes: null,
    needs_review: false,
    compressors: 2,
    dispensers: 3,
    storage_vessels: 4,
    recovery_tanks: 1,
    gas_detectors: 2,
    hoses: 6,
    installed_srvs: 9,
    overdue: 1,
    ...over,
  }
}

beforeEach(() => {
  calls.list = []
  replies.regions = { data: [], error: null }
  replies.stations = { data: [], error: null, count: 0 }
  replies.stationsUnfilteredCount = { data: null, error: null, count: 0 }
  replies.units = { data: [], error: null }
  replies.station = { data: null, error: null }
  replies.unit = { data: null, error: null }
})
afterEach(() => vi.clearAllMocks())

const wrap = (ui: React.ReactElement) => render(<MemoryRouter>{ui}</MemoryRouter>)

describe('Regions overview', () => {
  it('lists only the Regions the database returned', async () => {
    replies.regions = { data: [EAST], error: null }
    wrap(<RegionsView />)
    expect(await screen.findByRole('link', { name: 'East' })).toBeDefined()
    // West is authorized for nobody in this fixture, so it is absent entirely -
    // not present with zeros.
    expect(screen.queryByText('West')).toBeNull()
  })

  it('shows an error, NOT an empty list, when the query fails', async () => {
    replies.regions = { data: null, error: { message: 'permission denied for view' } }
    wrap(<RegionsView />)
    expect(await screen.findByText(/could not load/i)).toBeDefined()
    expect(screen.queryByText(/no regions are visible/i)).toBeNull()
  })

  it('states an empty result rather than leaving the page blank', async () => {
    wrap(<RegionsView />)
    expect(await screen.findByText(/no regions are visible to you/i)).toBeDefined()
  })
})

describe('Stations browser', () => {
  it('renders rows and a pagination total taken from the RLS-scoped count', async () => {
    replies.stations = { data: [station()], error: null, count: 210 }
    wrap(<StationsView />)
    expect(await screen.findByRole('link', { name: 'الماظة' })).toBeDefined()
    // The total is whatever the database counted for THIS caller.
    expect(screen.getByText(/1–1 of 210/)).toBeDefined()
  })

  it('asks the database to filter and sort, never JavaScript', async () => {
    replies.stations = { data: [station()], error: null, count: 1 }
    wrap(<StationsView />)
    await screen.findByRole('link', { name: 'الماظة' })

    await userEvent.click(screen.getByRole('button', { name: /overdue/i }))
    await waitFor(() => {
      expect(calls.list.some((c) => c.startsWith('v_station_summary.order:overdue'))).toBe(true)
    })
    // Paging is a range request, not a client-side slice.
    expect(calls.list.some((c) => c.startsWith('v_station_summary.range:'))).toBe(true)
  })

  it('searches on the folded name so Arabic spelling variants match', async () => {
    replies.stations = { data: [station()], error: null, count: 1 }
    wrap(<StationsView />)
    await screen.findByRole('link', { name: 'الماظة' })

    await userEvent.type(screen.getByRole('searchbox', { name: /search stations/i }), 'الماظه')
    await waitFor(() => {
      const or = calls.list.find((c) => c.includes('.or:'))
      expect(or).toBeDefined()
      // Both the raw term and its folded form are offered to PostgREST.
      expect(or).toContain('station_name.ilike')
      expect(or).toContain('normalized_name.ilike')
    })
  })

  it('distinguishes "no results for these filters" from "nothing exists"', async () => {
    // Stations exist for this caller, but none match.
    replies.stations = { data: [], error: null, count: 0 }
    replies.stationsUnfilteredCount = { data: null, error: null, count: 210 }
    wrap(<StationsView />)
    await userEvent.type(screen.getByRole('searchbox', { name: /search stations/i }), 'zzzz')
    expect(await screen.findByText(/no results match these filters/i)).toBeDefined()
    expect(screen.queryByText(/no stations recorded yet/i)).toBeNull()
  })

  it('reports a genuinely empty database as empty, not as a filter miss', async () => {
    replies.stations = { data: [], error: null, count: 0 }
    replies.stationsUnfilteredCount = { data: null, error: null, count: 0 }
    wrap(<StationsView />)
    expect(await screen.findByText(/no stations recorded yet/i)).toBeDefined()
  })

  it('shows an error instead of an empty table when the query fails', async () => {
    replies.stations = { data: null, error: { message: 'JWT expired' }, count: 0 }
    wrap(<StationsView />)
    expect(await screen.findByText(/could not load/i)).toBeDefined()
    expect(screen.queryByText(/no stations recorded yet/i)).toBeNull()
  })

  it('renders a NULL bay status as "not recorded", never N/A or 0', async () => {
    replies.stations = { data: [station({ bay_status: null })], error: null, count: 1 }
    wrap(<StationsView />)
    expect(await screen.findByText(/not recorded/i)).toBeDefined()
    expect(screen.queryByText('N/A')).toBeNull()
    expect(screen.queryByText('Unknown')).toBeNull()
  })
})

describe('Station detail', () => {
  const renderStation = () =>
    render(
      <MemoryRouter initialEntries={['/stations/s-1']}>
        <Routes>
          <Route path="/stations/:stationId" element={<StationOverview />} />
        </Routes>
      </MemoryRouter>,
    )

  it('lists the Units the Station owns', async () => {
    replies.station = { data: station(), error: null }
    replies.units = { data: [unit()], error: null }
    renderStation()
    expect(await screen.findByRole('link', { name: 'الماظة 1' })).toBeDefined()
  })

  it('treats a Station with no Units as complete, not incomplete', async () => {
    replies.station = { data: station({ units: 0 }), error: null }
    replies.units = { data: [], error: null }
    renderStation()
    expect(await screen.findByText(/no units recorded for this station/i)).toBeDefined()
    // Principle #19: never BADGED incomplete. The copy may use the word while
    // explaining the opposite ("a complete record with an unknown Unit
    // structure"), so match a badge-shaped label exactly rather than the
    // substring, which would also catch the reassurance.
    expect(screen.queryByText(/^\s*incomplete\s*$/i)).toBeNull()
    // And no invented default Unit offered as the fix (decision D7).
    expect(screen.queryByRole('button', { name: /add.*unit/i })).toBeNull()
  })

  it('does not invent a Station-level job number', async () => {
    replies.station = { data: station(), error: null }
    replies.units = { data: [], error: null }
    renderStation()
    await screen.findByText(/no units recorded/i)
    // Job Number lives on the Unit. The Station panel must not carry one.
    const panel = screen.getByRole('region', { name: /station/i, hidden: true })
    expect(panel).toBeDefined()
    expect(screen.queryByText(/^job number$/i)).toBeNull()
  })

  it('does not reveal whether an unreadable Station exists', async () => {
    replies.station = { data: null, error: null }
    replies.units = { data: [], error: null }
    renderStation()
    expect(await screen.findByText(/station not found/i)).toBeDefined()
    // "does not exist, OR outside your access" - deliberately ambiguous.
    expect(screen.getByText(/does not exist, or it is outside/i)).toBeDefined()
  })
})

// The Unit boundary block that used to live here was superseded by Prompt 10:
// `UnitOverview` became the real Unit workspace, and it is covered in full by
// src/features/units/__tests__/unitWorkspace.test.tsx.
