import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * Global SRV Management.
 *
 * What these defend, hardest first:
 *
 * 1. **Installed and warehouse are never merged.** Warehouse stock has no
 *    Station, Unit or equipment parent, and is never given one.
 * 2. **Every filter, sort and page is a SERVER query.** Nothing fetches
 *    company-wide rows to narrow them in JavaScript, because that would put the
 *    authorization boundary in the browser.
 * 3. **A failed query is never zero.** Not in the table, not in the summary.
 * 4. **Nothing is mapped or inferred here** - no guessed hierarchy, no guessed
 *    equipment parent, and `SS-4R3A` stays a Part Number.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  installed: { data: [] as unknown[], error: null, count: 0 } as Reply,
  warehouse: { data: [] as unknown[], error: null, count: 0 } as Reply,
  /** The unfiltered head count, used to tell "no match" from "nothing exists". */
  headCount: { data: null, error: null, count: 0 } as Reply,
  /** The attention strip, now ONE row from v_installed_srv_summary (25J-B). */
  summary: { data: null as unknown, error: null } as Reply,
  regions: { data: [] as unknown[], error: null } as Reply,
}))

const calls = vi.hoisted(() => ({ list: [] as string[] }))

vi.mock('@/lib/supabase/client', () => {
  const client = {
    from(table: string) {
      let head = false
      const chain: Record<string, unknown> = {
        select: (_c?: string, opts?: { head?: boolean }) => {
          head = Boolean(opts?.head)
          return chain
        },
        eq: (col: string, value: string) => {
          calls.list.push(`${table}.eq:${col}=${value}`)
          return chain
        },
        in: (col: string, values: string[]) => {
          calls.list.push(`${table}.in:${col}=[${values.join('|')}]`)
          return chain
        },
        or: (expr: string) => {
          calls.list.push(`${table}.or:${expr}`)
          return chain
        },
        order: (col: string, opts?: { ascending?: boolean }) => {
          calls.list.push(`${table}.order:${col}:${opts?.ascending === false ? 'desc' : 'asc'}`)
          return chain
        },
        maybeSingle: () => {
          calls.list.push(`${table}.maybeSingle`)
          return Promise.resolve(replies.summary)
        },
        range: (a: number, b: number) => {
          calls.list.push(`${table}.range:${a}-${b}`)
          return Promise.resolve(table === 'v_srv_warehouse_stock' ? replies.warehouse : replies.installed)
        },
        then: (resolve: (v: unknown) => unknown) => {
          const reply =
            table === 'v_installed_srv_summary' ? replies.summary
            : table === 'v_dashboard_region_summary' ? replies.regions
            : head ? replies.headCount
            : table === 'v_srv_warehouse_stock' ? replies.warehouse
            : replies.installed
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
  }
  ;(client as Record<string, unknown>).rpc = () => Promise.resolve({ data: [], error: null })
  return { useSupabaseClient: () => client }
})

const { SrvWorkspace } = await import('@/features/relief-valves/SrvWorkspace')
const { InstalledSrvSection } = await import('@/features/relief-valves/sections/InstalledSrvSection')
const { WarehouseSrvSection } = await import('@/features/relief-valves/sections/WarehouseSrvSection')

function installed(over: Record<string, unknown> = {}) {
  return {
    id: 'i-1', region_id: 'r-east', region_name: 'East',
    station_id: 's-1', station_name: 'الماظة', source_station_name_raw: null,
    station_display: null, needs_station_mapping: false,
    unit_id: 'u-1', unit_name: 'الماظة 1',
    mapping_status: 'resolved', needs_mapping: false, mapping_label: 'Resolved',
    expected_parent_kind: 'compressor', location_raw: 'Stage',
    parent_kind: 'compressor', parent_id: 'c-1', parent_label: 'F-19822',
    tag_number: 'PSV-101', serial_number: 'RV-880124', serial_number_raw: 'RV-880124',
    serial_status: 'assigned', part_number: null, manufacturer: 'Leser',
    size_type: null, inlet_size: null, outlet_size: null,
    set_pressure_raw: '250', pressure_min: 250, pressure_max: 250, pressure_unit: 'BAR',
    last_calibration_date: '2026-01-14', last_calibration_precision: 'exact_date',
    last_calibration_display: '14 Jan 2026',
    next_calibration_date: '2026-09-10', next_calibration_precision: 'exact_date',
    next_calibration_display: '10 Sep 2026',
    days_left: -5, due_status: 'overdue',
    source_status_raw: null, needs_review: false, notes: null,
    source_file: 'Installed SRV.xlsx', source_sheet: 'Sheet1', source_row: 12,
    ...over,
  }
}

function warehouse(over: Record<string, unknown> = {}) {
  return {
    id: 'w-1', availability_status: 'available_new', warehouse_code: 'WH-10',
    serial_number: 'WRV-500001', serial_number_raw: 'WRV-500001', serial_status: 'assigned',
    part_number: null, manufacturer: 'Leser', size_type: null, inlet_size: null, outlet_size: null,
    set_pressure_raw: '206', pressure_min: 206, pressure_max: 206, pressure_unit: 'BAR',
    target_region_id: null, target_region_name: null,
    target_station_id: null, target_station_name: null, is_unassigned_stock: true,
    warehouse_issue_date: null,
    last_calibration_date: '2025-11-03', last_calibration_precision: 'exact_date',
    last_calibration_display: '3 Nov 2025',
    next_calibration_date: '2026-09-30', next_calibration_precision: 'exact_date',
    next_calibration_display: '30 Sep 2026',
    days_left: 15, due_status: 'due_15',
    calibration_location: null, source_status_raw: null, needs_review: false, notes: null,
    ...over,
  }
}

beforeEach(() => {
  calls.list = []
  replies.installed = { data: [], error: null, count: 0 }
  replies.warehouse = { data: [], error: null, count: 0 }
  replies.headCount = { data: null, error: null, count: 0 }
  replies.summary = {
    data: { total: 0, overdue: 0, attention: 0, needs_station_mapping: 0,
            needs_unit_mapping: 0, needs_equipment_mapping: 0, conflict: 0 },
    error: null,
  }
  replies.regions = { data: [], error: null }
})
afterEach(() => vi.clearAllMocks())

function renderSrv(path = '/manage/srvs/installed') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/manage/srvs" element={<SrvWorkspace />}>
          <Route path="installed" element={<InstalledSrvSection />} />
          <Route path="warehouse" element={<WarehouseSrvSection />} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('Workspace and routes', () => {
  it('separates installed from warehouse by label, not colour', async () => {
    renderSrv()
    const nav = await screen.findByRole('navigation', { name: /srv datasets/i })
    expect(within(nav).getByText('Installed SRVs')).toBeDefined()
    expect(within(nav).getByText('Warehouse SRVs')).toBeDefined()
    // The hint text states the difference in words.
    expect(within(nav).getByText(/in the store/i)).toBeDefined()
  })

  it('marks the active dataset with aria-current', async () => {
    renderSrv('/manage/srvs/warehouse')
    const current = await screen.findByRole('link', { current: 'page' })
    expect(current.textContent).toContain('Warehouse')
  })
})

describe('Installed SRVs — server-side query', () => {
  it('sends filters to the database, never filtering in JavaScript', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    await screen.findByText('RV-880124')

    await userEvent.selectOptions(screen.getByLabelText(/^mapping$/i), 'needs_unit_mapping')
    await waitFor(() =>
      expect(calls.list).toContain('v_installed_srv_management.eq:mapping_status=needs_unit_mapping'),
    )
    await userEvent.selectOptions(screen.getByLabelText(/^due$/i), 'overdue')
    await waitFor(() => expect(calls.list).toContain('v_installed_srv_management.eq:due_status=overdue'))
    await userEvent.selectOptions(screen.getByLabelText(/^parent$/i), 'storage_vessel')
    await waitFor(() => expect(calls.list).toContain('v_installed_srv_management.eq:parent_kind=storage_vessel'))
  })

  it('pages with a server range, never by slicing in the browser', async () => {
    replies.installed = { data: [installed()], error: null, count: 250 }
    renderSrv()
    await screen.findByText('RV-880124')
    expect(calls.list.some((c) => c.startsWith('v_installed_srv_management.range:'))).toBe(true)
    expect(screen.getByText(/1–1 of 250/)).toBeDefined()
  })

  it('sorts with an explicit tie-break so paging is stable', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    await screen.findByText('RV-880124')
    calls.list = []
    await userEvent.click(screen.getByRole('button', { name: /^Serial/ }))
    await waitFor(() => {
      const orders = calls.list.filter((c) => c.includes('.order:'))
      // The requested column FIRST, then a deterministic tie-break — a later
      // .order() must never replace the primary sort.
      expect(orders[0]).toContain('order:serial_number')
      expect(orders[1]).toContain('order:id')
    })
  })

  it('searches identifiers and hierarchy, offering the folded form too', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    await screen.findByText('RV-880124')
    await userEvent.type(screen.getByRole('searchbox', { name: /search installed/i }), 'الماظه')
    await waitFor(() => {
      const or = calls.list.find((c) => c.includes('.or:'))
      expect(or).toBeDefined()
      expect(or).toContain('serial_number.ilike')
      expect(or).toContain('part_number.ilike')
      expect(or).toContain('source_station_name_raw.ilike')
    })
  })
})

describe('Installed SRVs — mapping lifecycle presentation', () => {
  it('shows a resolved record with its proven hierarchy and parent', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    expect(await screen.findByText('RV-880124')).toBeDefined()
    expect(screen.getByText('الماظة')).toBeDefined()
    expect(screen.getByText('F-19822')).toBeDefined()
  })

  it('needs_equipment_mapping states the parent is unconfirmed, never guesses', async () => {
    replies.installed = {
      data: [installed({ mapping_status: 'needs_equipment_mapping', needs_mapping: true, parent_kind: null, parent_id: null, parent_label: null })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText(/needs equipment mapping/i)).toBeDefined()
    expect(screen.getAllByText(/not confirmed/i).length).toBeGreaterThan(0)
    expect(screen.queryByText('F-19822')).toBeNull()
  })

  it('needs_unit_mapping shows the Station but no Unit', async () => {
    replies.installed = {
      data: [installed({ mapping_status: 'needs_unit_mapping', needs_mapping: true, unit_id: null, unit_name: null, parent_kind: null, parent_id: null, parent_label: null })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText(/needs unit mapping/i)).toBeDefined()
    expect(screen.getByText('الماظة')).toBeDefined()
  })

  it('needs_station_mapping fabricates no Region or Station from raw text', async () => {
    replies.installed = {
      data: [installed({
        mapping_status: 'needs_station_mapping', needs_mapping: true, needs_station_mapping: true,
        region_id: null, region_name: null, station_id: null, station_name: null,
        unit_id: null, unit_name: null, parent_kind: null, parent_id: null, parent_label: null,
        source_station_name_raw: 'ابو تيج- اسيوط',
      })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText(/needs station mapping/i)).toBeDefined()
    expect(screen.getByText(/station not confirmed/i)).toBeDefined()
    // The raw source name is NOT promoted into the Station column.
    const row = screen.getByText(/station not confirmed/i).closest('tr')!
    expect(within(row).queryByText('ابو تيج- اسيوط')).toBeNull()
  })

  it('draws conflict distinctly from needs-mapping', async () => {
    replies.installed = {
      data: [installed({ mapping_status: 'conflict', needs_mapping: true, parent_kind: null, parent_id: null, parent_label: null })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText('Conflict')).toBeDefined()
    // Scoped to the TABLE: the Mapping filter's <option> list legitimately
    // contains every state name, so a document-wide query would always match.
    const table = screen.getByRole('table')
    expect(within(table).queryByText(/needs (unit|station|equipment) mapping/i)).toBeNull()
  })

  it('offers no control that changes a mapping', async () => {
    replies.installed = {
      data: [installed({ mapping_status: 'needs_equipment_mapping', needs_mapping: true, parent_kind: null, parent_id: null, parent_label: null })],
      error: null, count: 1,
    }
    renderSrv()
    await screen.findByText(/needs equipment mapping/i)
    // Mapping mutation is deliberately deferred; no button may imply otherwise.
    expect(screen.queryByRole('button', { name: /resolve|assign|map |confirm/i })).toBeNull()
  })
})

describe('Identifiers and technical values', () => {
  it('keeps SS-4R3A a Part Number and leaves the serial absent', async () => {
    replies.installed = {
      data: [installed({ serial_number: null, serial_number_raw: 'SS-4R3A', serial_status: 'unknown', part_number: 'SS-4R3A' })],
      error: null, count: 1,
    }
    renderSrv()
    const row = (await screen.findByText('SS-4R3A')).closest('tr')!
    expect(within(row).getAllByText(/not recorded/i).length).toBeGreaterThan(0)
    expect(within(row).getByText('SS-4R3A')).toBeDefined()
  })

  it('preserves an identifier exactly, including leading zeros', async () => {
    replies.installed = {
      data: [installed({ serial_number: '000420-A', serial_number_raw: '000420-A' })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText('000420-A')).toBeDefined()
  })

  it('never turns a year-only date into a countdown or into "within date"', async () => {
    replies.installed = {
      data: [installed({
        next_calibration_date: null, next_calibration_precision: 'year_only',
        next_calibration_display: '2027', days_left: null, due_status: 'unknown',
      })],
      error: null, count: 1,
    }
    renderSrv()
    expect(await screen.findByText('2027')).toBeDefined()
    expect(screen.getByText(/year only/i)).toBeDefined()
    // Scoped to the table: "No exact date" is also a Due filter option.
    const table = screen.getByRole('table')
    expect(within(table).getByText(/no exact date/i)).toBeDefined()
    expect(within(table).queryByText(/within date/i)).toBeNull()
  })

  it('shows a pressure with its stored unit and never invents one', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    // Scoped to the table: BAR and PSI are also options of the set-pressure unit filter.
    const table = await screen.findByRole('table')
    expect(await within(table).findByText('BAR')).toBeDefined()
    expect(within(table).queryByText('PSI')).toBeNull()
  })

  it('labels source Location as context, never as an equipment identity', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    renderSrv()
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    expect(screen.getByText(/source context, not an identity/i)).toBeDefined()
    expect(screen.getByText(/which one is unknown/i)).toBeDefined()
  })
})

describe('States', () => {
  it('a failed table query is an error, never an empty list', async () => {
    replies.installed = { data: null, error: { message: 'permission denied' }, count: 0 }
    renderSrv()
    expect(await screen.findByText(/could not load installed relief valves/i)).toBeDefined()
    expect(screen.queryByText(/no installed relief valves recorded yet/i)).toBeNull()
  })

  it('a failed summary count states the failure rather than showing zeros', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    replies.summary = { data: null, error: { message: 'boom' } }
    renderSrv()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
    expect(screen.queryByRole('heading', { name: /attention and mapping summary/i })).toBeNull()
  })

  it('distinguishes "no match" from "nothing exists"', async () => {
    replies.installed = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 900 }
    renderSrv()
    await userEvent.type(screen.getByRole('searchbox', { name: /search installed/i }), 'zzzz')
    expect(await screen.findByText(/no results match these filters/i)).toBeDefined()
    expect(screen.queryByText(/no installed relief valves recorded yet/i)).toBeNull()
  })

  it('reports a genuinely empty dataset as empty', async () => {
    replies.installed = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 0 }
    renderSrv()
    expect(await screen.findByText(/no installed relief valves recorded yet/i)).toBeDefined()
  })
})

describe('Warehouse isolation', () => {
  it('has no Station, Unit, Region, Mapping or Equipment column', async () => {
    replies.warehouse = { data: [warehouse()], error: null, count: 1 }
    renderSrv('/manage/srvs/warehouse')
    await screen.findByText('WRV-500001')
    const headers = screen.getAllByRole('columnheader').map((h) => h.textContent?.trim() ?? '')
    for (const forbidden of ['Station', 'Unit', 'Region', 'Mapping', 'Equipment parent']) {
      expect(headers).not.toContain(forbidden)
    }
  })

  it('offers no Region filter, because stock has no Region', async () => {
    replies.warehouse = { data: [warehouse()], error: null, count: 1 }
    renderSrv('/manage/srvs/warehouse')
    await screen.findByText('WRV-500001')
    expect(screen.queryByLabelText(/^region$/i)).toBeNull()
  })

  it('reads its own view and never the installed one', async () => {
    replies.warehouse = { data: [warehouse()], error: null, count: 1 }
    renderSrv('/manage/srvs/warehouse')
    await screen.findByText('WRV-500001')
    expect(calls.list.some((c) => c.startsWith('v_srv_warehouse_stock.'))).toBe(true)
    expect(calls.list.some((c) => c.startsWith('v_installed_srv_management.'))).toBe(false)
  })

  it('calls a destination a destination, not a hierarchy position', async () => {
    replies.warehouse = {
      data: [warehouse({ is_unassigned_stock: false, target_station_name: 'الماظة', target_region_name: 'East' })],
      error: null, count: 1,
    }
    renderSrv('/manage/srvs/warehouse')
    await screen.findByText('WRV-500001')
    const headers = screen.getAllByRole('columnheader').map((h) => h.textContent?.trim() ?? '')
    expect(headers).toContain('Destination')
  })

  it('states unassigned stock explicitly rather than leaving it blank', async () => {
    replies.warehouse = { data: [warehouse()], error: null, count: 1 }
    renderSrv('/manage/srvs/warehouse')
    expect(await screen.findByText(/unassigned stock/i)).toBeDefined()
  })

  it('shows a NULL warehouse serial as "not recorded"', async () => {
    replies.warehouse = {
      data: [warehouse({ serial_number: null, serial_number_raw: null, serial_status: 'unknown' })],
      error: null, count: 1,
    }
    renderSrv('/manage/srvs/warehouse')
    expect((await screen.findAllByText(/not recorded/i)).length).toBeGreaterThan(0)
  })

  it('reports no invented stock quantity', async () => {
    replies.warehouse = { data: [warehouse()], error: null, count: 1 }
    renderSrv('/manage/srvs/warehouse')
    await screen.findByText('WRV-500001')
    // The schema models no quantity, so no stock level is claimed.
    expect(screen.queryByText(/in stock|quantity|qty/i)).toBeNull()
  })
})

/**
 * Prompt 25J-B. The attention strip failed in production AFTER the 1,054-row
 * Station-only batch, because it fired SEVEN parallel count queries and those
 * statements reached 7.9s against the `authenticated` 8s statement_timeout.
 * These assert the shape that fixed it: ONE round trip, and the real mixed
 * state rendering correctly.
 */
describe('Installed SRV attention summary (25J-B)', () => {
  const mixed = {
    total: 2662,
    overdue: 302,
    attention: 598,
    needs_station_mapping: 1608,
    needs_unit_mapping: 1054,
    needs_equipment_mapping: 0,
    conflict: 0,
  }

  it('loads the whole strip from ONE query, not a seven-way count fan-out', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    replies.summary = { data: mixed, error: null }
    renderSrv()
    expect(await screen.findByRole('heading', { name: /attention and mapping summary/i })).toBeDefined()

    // Exactly one summary round trip...
    const summaryCalls = calls.list.filter((c) => c.startsWith('v_installed_srv_summary.'))
    expect(summaryCalls.filter((c) => c.endsWith('.maybeSingle'))).toHaveLength(1)
    // ...and NOT a single count query against the row view for the strip.
    expect(calls.list).not.toContain('v_installed_srv_management.eq:mapping_status=conflict')
    expect(calls.list).not.toContain('v_installed_srv_management.eq:mapping_status=needs_equipment_mapping')
  })

  it('renders the real post-batch mixed state, both statuses at once', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    replies.summary = { data: mixed, error: null }
    renderSrv()
    const strip = await screen.findByRole('region', { name: /attention and mapping summary/i })
    // The two coexisting mapping states are the whole point of the regression.
    expect(within(strip).getByText('1,608')).toBeDefined()
    expect(within(strip).getByText('1,054')).toBeDefined()
    expect(within(strip).getByText('2,662')).toBeDefined()
    expect(within(strip).getByText('302')).toBeDefined()
    expect(within(strip).getByText('598')).toBeDefined()
  })

  it('a summary row that never arrives is stated, never rendered as zeros', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    replies.summary = { data: null, error: null }
    renderSrv()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
    expect(screen.queryByRole('heading', { name: /attention and mapping summary/i })).toBeNull()
  })

  it('a failed summary never blanks the table', async () => {
    replies.installed = { data: [installed()], error: null, count: 1 }
    replies.summary = { data: null, error: { message: 'canceling statement due to statement timeout' } }
    renderSrv()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
    expect(calls.list.some((c) => c.startsWith('v_installed_srv_management.range:'))).toBe(true)
  })
})

describe('smart filters and warehouse code', () => {
  it('FILTER-1 serial, station, size and set pressure narrow the server query, one column each', async () => {
    const { applySmartFilters } = await import('@/features/relief-valves/useSrvManagement')
    const calls: Array<[string, string, unknown]> = []
    const b = {
      ilike(c: string, v: unknown) { calls.push(['ilike', c, v]); return b },
      lte(c: string, v: unknown) { calls.push(['lte', c, v]); return b },
      gte(c: string, v: unknown) { calls.push(['gte', c, v]); return b },
      eq(c: string, v: unknown) { calls.push(['eq', c, v]); return b },
    }
    applySmartFilters(b, { serial: ' 0003,262 ', region: 'r-1', station: 'الهرم', size: 'M 3/4" X 1"', pressure: '316', pressureUnit: 'BAR' }, 'station_display')
    expect(calls).toEqual([
      ['ilike', 'serial_number', '%0003 262%'],
      ['eq', 'region_id', 'r-1'],
      ['ilike', 'station_display', '%الهرم%'],
      ['ilike', 'size_type', 'male'],
      ['ilike', 'inlet_size', '3/4"%'],
      ['ilike', 'outlet_size', '1"%'],
      ['lte', 'pressure_min', 316],
      ['gte', 'pressure_max', 316],
      ['eq', 'pressure_unit', 'BAR'],
    ])
  })

  it('FILTER-3 the full size is read as the table writes it; a bare inlet still works', async () => {
    const { parseSize } = await import('@/features/relief-valves/useSrvManagement')
    expect(parseSize('M 3/4" X 1"')).toEqual({ type: 'male', inlet: '3/4"', outlet: '1"' })
    expect(parseSize('F 1/2"x3/4"')).toEqual({ type: 'female', inlet: '1/2"', outlet: '3/4"' })
    expect(parseSize('flange 1" X 1 1/2"')).toEqual({ type: 'flange', inlet: '1"', outlet: '1 1/2"' })
    expect(parseSize('1/2"')).toEqual({ type: null, inlet: '1/2"', outlet: '' })
  })

  it('FILTER-2 empty filters add nothing', async () => {
    const { applySmartFilters, EMPTY_SMART_FILTERS, hasSmartFilters } = await import('@/features/relief-valves/useSrvManagement')
    const b = { ilike: vi.fn(), lte: vi.fn(), gte: vi.fn(), eq: vi.fn() }
    applySmartFilters(b, EMPTY_SMART_FILTERS, 'station_display')
    expect(b.ilike).not.toHaveBeenCalled()
    expect(b.eq).not.toHaveBeenCalled()
    expect(hasSmartFilters(EMPTY_SMART_FILTERS)).toBe(false)
  })

  it('WHCODE-1 a serial-matched warehouse code is shown and labelled as a lookup', async () => {
    replies.installed = { data: [installed({ warehouse_code: 'acc 794', warehouse_code_source: 'serial_match' })], error: null, count: 1 }
    renderSrv()
    const table = await screen.findByRole('table')
    expect(await within(table).findByText('acc 794')).toBeDefined()
    expect(within(table).getByText('by serial')).toBeDefined()
  })
})
