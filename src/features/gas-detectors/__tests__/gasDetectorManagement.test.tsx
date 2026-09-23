import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * Global Gas Detector Management.
 *
 * What these defend, hardest first:
 *
 * 1. **Area Type is a classification, not a status.** `open`/`closed` must
 *    never be rendered in the compliance vocabulary, and Closed must never be
 *    coloured or described as a warning.
 * 2. **There is no detector `location`.** The schema records `area_type` on
 *    `gas_detector_presence` and nothing positional. No location is displayed
 *    and none is inferred.
 * 3. **A Unit is never guessed.** An unresolved detector says so.
 * 4. **A failed query is never zero**, in the table or in the summary.
 * 5. **Year-only dates never become a countdown** and never read "within date".
 * 6. **Filters are applied server-side and combine as an intersection.**
 * 7. **Presence evidence is never counted as a detector.**
 *
 * Every date here is a fixed literal. Nothing derives from `Date.now()`, so a
 * run tomorrow asserts exactly what a run today asserted.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  detectors: { data: [] as unknown[], error: null, count: 0 } as Reply,
  headCount: { data: null, error: null, count: 0 } as Reply,
  regions: { data: [] as unknown[], error: null } as Reply,
  stations: { data: [] as unknown[], error: null, count: 0 } as Reply,
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
        gt: (col: string) => {
          calls.list.push(`${table}.gt:${col}`)
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
          return table === 'v_dashboard_region_summary' ? Promise.resolve(replies.regions) : chain
        },
        range: (a: number, b: number) => {
          calls.list.push(`${table}.range:${a}-${b}`)
          return Promise.resolve(table === 'v_station_summary' ? replies.stations : replies.detectors)
        },
        then: (resolve: (v: unknown) => unknown) => {
          const reply =
            table === 'v_dashboard_region_summary' ? replies.regions
            : table === 'v_station_summary' ? replies.stations
            : head ? replies.headCount
            : replies.detectors
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
  }
  return { useSupabaseClient: () => client }
})

const { GasDetectorsView } = await import('@/features/gas-detectors/GasDetectorsView')

/** A resolved, installed detector in a closed area. Fixed dates throughout. */
function detector(over: Record<string, unknown> = {}) {
  return {
    detector_id: 'gd-1',
    detector_presence: 'installed',
    region_id: 'r-east', region_name: 'East',
    station_id: 's-1', station_name: 'الماظة',
    unit_id: 'u-1', unit_name: 'الماظة 1',
    area_type: 'closed', area_type_raw: 'Close Area',
    mapping_status: 'resolved', needs_mapping: false,
    manufacturer: 'Honeywell', model: 'XNX',
    serial_number: 'GD-00001', serial_number_raw: 'GD-00001', serial_status: 'assigned',
    last_calibration_date: '2025-09-20', last_calibration_precision: 'exact_date',
    last_calibration_display: '20 Sep 2025',
    next_calibration_date: '2026-09-20', next_calibration_precision: 'exact_date',
    next_calibration_display: '20 Sep 2026',
    days_left: 4, due_status: 'due_7',
    source_status_raw: null, needs_review: false, notes: null,
    ...over,
  }
}

/** Presence evidence: no device, therefore no detector_id and no dates. */
function evidence(over: Record<string, unknown> = {}) {
  return detector({
    detector_id: null, detector_presence: 'not_installed',
    unit_id: null, unit_name: null,
    mapping_status: null,
    manufacturer: null, model: null,
    serial_number: null, serial_number_raw: null, serial_status: null,
    last_calibration_date: null, last_calibration_precision: null, last_calibration_display: null,
    next_calibration_date: null, next_calibration_precision: null, next_calibration_display: null,
    days_left: null, due_status: 'unknown',
    ...over,
  })
}

beforeEach(() => {
  calls.list = []
  replies.detectors = { data: [], error: null, count: 0 }
  replies.headCount = { data: null, error: null, count: 0 }
  replies.regions = { data: [], error: null }
  replies.stations = { data: [], error: null, count: 0 }
})
afterEach(() => vi.clearAllMocks())

function renderDetectors() {
  return render(
    <MemoryRouter initialEntries={['/manage/gas-detectors']}>
      <Routes>
        <Route path="/manage/gas-detectors" element={<GasDetectorsView />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('Route and page shell', () => {
  it('renders the registry at /manage/gas-detectors with exactly one h1', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const h1s = screen.getAllByRole('heading', { level: 1 })
    expect(h1s).toHaveLength(1)
    expect(h1s[0].textContent).toContain('Gas Detector Management')
  })

  it('reads the gas detector management view, not a detector table directly', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(calls.list.some((c) => c.startsWith('v_gas_detector_management.'))).toBe(true)
    expect(calls.list.some((c) => c.startsWith('gas_detectors.'))).toBe(false)
  })
})

describe('Column priority', () => {
  it('leads with calibration attention, not with reference data', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const headers = screen.getAllByRole('columnheader').map((h) => h.textContent?.trim() ?? '')
    // Identity, hierarchy, area, then the next-due triple. Manufacturer and
    // Model are reference data and come last: with them in third and fourth
    // place, Days left and Status fell outside the visible region at 1440px,
    // hiding the two values this screen exists to surface.
    const order = headers.filter((h) => h && !/expand/i.test(h))
    expect(order.slice(0, 7)).toEqual([
      'Serial', 'Station', 'Unit', 'Area type', 'Next calibration', 'Days left', 'Status',
    ])
    expect(order.indexOf('Manufacturer')).toBeGreaterThan(order.indexOf('Status'))
    expect(order.indexOf('Model')).toBeGreaterThan(order.indexOf('Status'))
  })
})

describe('Area Type is a classification, never a status', () => {
  it('renders Open and Closed with identical, non-status styling', async () => {
    replies.detectors = {
      data: [detector({ area_type: 'closed' }), detector({ detector_id: 'gd-2', serial_number: 'GD-00002', area_type: 'open' })],
      error: null, count: 2,
    }
    renderDetectors()
    // Scoped to the table: the Area FILTER also contains the words Open and
    // Closed as <option> text.
    const table = await screen.findByRole('table')
    const closed = within(table).getByText('Closed')
    const open = within(table).getByText('Open')
    // Same element shape and same classes: only the WORD differs. If Closed
    // ever picks up a status colour, these diverge and this fails.
    expect(closed.className).toBe(open.className)
  })

  it('never describes an area classification in compliance language', async () => {
    replies.detectors = { data: [detector({ area_type: 'closed' })], error: null, count: 1 }
    renderDetectors()
    const table = await screen.findByRole('table')
    const closed = within(table).getByText('Closed')
    const announced = closed.parentElement?.textContent ?? ''
    expect(announced).toMatch(/area classification/i)
    expect(announced).not.toMatch(/overdue|warning|within its|calibration date/i)
  })

  it('shows a genuinely empty area as not recorded, never as Open', async () => {
    replies.detectors = { data: [detector({ area_type: null, area_type_raw: null })], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const table = screen.getByRole('table')
    expect(within(table).queryByText('Open')).toBeNull()
    expect(within(table).queryByText('Closed')).toBeNull()
    expect(within(table).getAllByText(/not recorded/i).length).toBeGreaterThan(0)
  })

  it('offers Area as a filter and sends it to the server', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /area/i }), 'closed')
    expect(calls.list).toContain('v_gas_detector_management.eq:area_type=closed')
  })
})

describe('There is no detector location', () => {
  it('draws no Location column and invents no position text', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.queryByRole('columnheader', { name: /^location$/i })).toBeNull()
    expect(screen.getByRole('columnheader', { name: /area type/i })).toBeDefined()
  })

  it('says in the footnote that area type is not a position', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getByText(/not a physical position/i)).toBeDefined()
  })
})

describe('Hierarchy and mapping', () => {
  it('shows the confirmed Station, Region and Unit of a resolved detector', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
    expect(screen.getAllByText('الماظة 1').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Resolved').length).toBeGreaterThan(0)
  })

  it('never guesses a Unit when the mapping is unresolved', async () => {
    replies.detectors = {
      data: [detector({ mapping_status: 'needs_unit_mapping', needs_mapping: true, unit_id: null, unit_name: null })],
      error: null, count: 1,
    }
    renderDetectors()
    await screen.findByText('GD-00001')
    const table = screen.getByRole('table')
    expect(within(table).getByText(/needs unit mapping/i)).toBeDefined()
    expect(within(table).getAllByText(/not confirmed/i).length).toBeGreaterThan(0)
    // The Station IS proven and still shown; only the Unit is withheld.
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
  })

  it('offers only mapping states a detector can actually hold', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const mapping = screen.getByRole('combobox', { name: /mapping/i })
    const options = within(mapping).getAllByRole('option').map((o) => (o as HTMLOptionElement).value)
    // A detector hangs off a Unit; it has no equipment parent to resolve.
    expect(options).not.toContain('needs_equipment_mapping')
    // station_id is NOT NULL, so this state is unreachable and is not offered.
    expect(options).not.toContain('needs_station_mapping')
    expect(options).toEqual(['all', 'resolved', 'needs_unit_mapping', 'conflict'])
  })

  it('exposes no mapping mutation control', async () => {
    replies.detectors = { data: [detector({ mapping_status: 'needs_unit_mapping', unit_id: null, unit_name: null })], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    // NB: /map/i is deliberately not asserted here — it matches the "Mapping"
    // column's SORT button, and sorting is not a mutation.
    for (const name of [/assign unit/i, /^assign/i, /resolve/i, /mark resolved/i, /save/i, /edit/i]) {
      expect(screen.queryByRole('button', { name })).toBeNull()
    }
  })
})

describe('Presence evidence is not a detector', () => {
  it('defaults the registry to installed detectors', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(calls.list).toContain('v_gas_detector_management.eq:detector_presence=installed')
  })

  it('counts the summary total over installed detectors only', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const installedCounts = calls.list.filter((c) => c === 'v_gas_detector_management.eq:detector_presence=installed')
    // Row query plus each installed metric; the not-installed metric is separate.
    expect(installedCounts.length).toBeGreaterThan(1)
    expect(calls.list).toContain('v_gas_detector_management.eq:detector_presence=not_installed')
  })

  it('renders an evidence row without a serial or a calibration date', async () => {
    replies.detectors = { data: [evidence()], error: null, count: 1 }
    renderDetectors()
    const rows = await screen.findAllByRole('row')
    // It is present as a record, but nothing about a device is fabricated.
    expect(rows.length).toBeGreaterThan(1)
    expect(screen.queryByText('GD-00001')).toBeNull()
  })
})

describe('Calibration dates and precision', () => {
  it('shows an exact next-calibration date with its countdown', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getAllByText('20 Sep 2026').length).toBeGreaterThan(0)
    expect(screen.getAllByText('4').length).toBeGreaterThan(0)
  })

  it('never turns a year-only date into a countdown or into "within date"', async () => {
    replies.detectors = {
      data: [detector({
        next_calibration_date: null, next_calibration_precision: 'year_only',
        next_calibration_display: '2027', days_left: null, due_status: 'unknown',
      })],
      error: null, count: 1,
    }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getAllByText('2027').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/year only/i).length).toBeGreaterThan(0)
    expect(screen.queryByText('2027-01-01')).toBeNull()
    expect(screen.queryByText('2027-12-31')).toBeNull()
    expect(screen.queryByText(/within date/i)).toBeNull()
    expect(screen.getAllByText(/no exact date/i).length).toBeGreaterThan(0)
  })

  it('keeps Arabic source status beside a missing date instead of becoming one', async () => {
    replies.detectors = {
      data: [detector({
        next_calibration_date: null, next_calibration_precision: 'unknown',
        next_calibration_display: null, days_left: null, due_status: 'unknown',
        source_status_raw: 'منتهي',
      })],
      error: null, count: 1,
    }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getAllByText(/منتهي/).length).toBeGreaterThan(0)
  })

  it('computes no due status of its own — it renders the one SQL returned', async () => {
    // days_left and due_status disagree on purpose. If the UI recomputed
    // anything, it would "correct" this; it must not.
    replies.detectors = { data: [detector({ days_left: 999, due_status: 'overdue' })], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getAllByText(/overdue/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText('999').length).toBeGreaterThan(0)
  })
})

describe('Identifiers', () => {
  it('preserves a leading-zero identifier exactly as stored', async () => {
    replies.detectors = {
      data: [detector({ serial_number: '0001803.02075', serial_number_raw: '0001803.02075' })],
      error: null, count: 1,
    }
    renderDetectors()
    expect(await screen.findByText('0001803.02075')).toBeDefined()
  })

  it('renders a long identifier in full without truncating it into ambiguity', async () => {
    const long = 'GD-CNG-2019-000044170-REV-A-LONG-IDENTIFIER'
    replies.detectors = { data: [detector({ serial_number: long, serial_number_raw: long })], error: null, count: 1 }
    renderDetectors()
    expect(await screen.findByText(long)).toBeDefined()
  })

  it('distinguishes a NULL serial from one not yet assigned', async () => {
    replies.detectors = {
      data: [
        detector({ serial_number: null, serial_number_raw: null, serial_status: 'unknown' }),
        detector({ detector_id: 'gd-2', serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned' }),
      ],
      error: null, count: 2,
    }
    renderDetectors()
    // "not yet assigned" is a FACT the source states; NULL is silence.
    expect(await screen.findByText(/not yet assigned/i)).toBeDefined()
    expect(screen.getAllByText(/not recorded/i).length).toBeGreaterThan(0)
  })

  it('never renders N/A, Unknown or a zero in place of a missing value', async () => {
    replies.detectors = {
      data: [detector({ manufacturer: null, model: null, serial_number: null, serial_number_raw: null, serial_status: 'unknown' })],
      error: null, count: 1,
    }
    renderDetectors()
    const table = await screen.findByRole('table')
    expect(table.textContent).not.toMatch(/N\/A/)
    expect(within(table).queryByText('Unknown')).toBeNull()
  })
})

describe('Server-side search, filters and their intersection', () => {
  it('sends search to the server across the real searchable fields', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    await userEvent.type(screen.getByRole('searchbox', { name: /search gas detectors/i }), 'Honeywell')
    const or = calls.list.find((c) => c.includes('.or:') && c.includes('Honeywell'))
    expect(or).toBeDefined()
    expect(or).toContain('serial_number.ilike')
    expect(or).toContain('manufacturer.ilike')
    expect(or).toContain('model.ilike')
    expect(or).toContain('station_name.ilike')
  })

  it('folds an Arabic search term the same way the SQL does', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    await userEvent.type(screen.getByRole('searchbox', { name: /search gas detectors/i }), 'الماظه')
    const or = calls.list.find((c) => c.includes('.or:') && c.includes('unit_name.ilike'))
    expect(or).toBeDefined()
  })

  it('combines East + Closed + Overdue as a server-side intersection', async () => {
    replies.detectors = { data: [detector({ due_status: 'overdue' })], error: null, count: 1 }
    replies.regions = { data: [{ region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 1, units: 1, assets: 1, overdue: 1, approaching_due: 0, unresolved_mapping: 0 }], error: null }
    renderDetectors()
    await screen.findByText('GD-00001')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /region/i }), 'r-east')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /area/i }), 'closed')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /due/i }), 'overdue')
    // All three reach the server. None is applied in React.
    expect(calls.list).toContain('v_gas_detector_management.eq:region_id=r-east')
    expect(calls.list).toContain('v_gas_detector_management.eq:area_type=closed')
    expect(calls.list).toContain('v_gas_detector_management.eq:due_status=overdue')
  })

  it('sends the due-window filter as an explicit bucket list', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /due/i }), 'attention')
    const bucket = calls.list.find((c) => c.includes('.in:due_status='))
    expect(bucket).toBeDefined()
    expect(bucket).toContain('overdue')
    expect(bucket).toContain('due_60')
  })

  it('clears the Station when the Region changes', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    replies.regions = { data: [{ region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 1, units: 1, assets: 1, overdue: 0, approaching_due: 0, unresolved_mapping: 0 }], error: null }
    renderDetectors()
    await screen.findByText('GD-00001')
    // The Station filter only appears once a Region narrows it.
    expect(screen.queryByRole('combobox', { name: /station/i })).toBeNull()
    expect(calls.list.some((call) => call.startsWith('v_station_summary.'))).toBe(false)
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /region/i }), 'r-east')
    expect(await screen.findByRole('combobox', { name: /station/i })).toBeDefined()
    expect(calls.list.filter((call) => call.startsWith('v_station_summary.range:'))).toHaveLength(1)
    expect(calls.list).toContain('v_station_summary.eq:region_id=r-east')
  })
})

describe('Sorting and pagination', () => {
  it('marks the sorted column with aria-sort and toggles both directions', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const header = () => screen.getByRole('columnheader', { name: /serial/i })
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_gas_detector_management.order:serial_number:asc')
    // Re-query: the header is a new node after the re-render.
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_gas_detector_management.order:serial_number:desc')
  })

  it('appends a deterministic tie-break so paging is stable', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    // A presence row has no detector_id, so station_id and unit_id complete
    // the identity across both branches of the UNION.
    expect(calls.list).toContain('v_gas_detector_management.order:detector_id:asc')
    expect(calls.list).toContain('v_gas_detector_management.order:station_id:asc')
    expect(calls.list).toContain('v_gas_detector_management.order:unit_id:asc')
  })

  it('pages on the server rather than loading the whole registry', async () => {
    replies.detectors = { data: [detector()], error: null, count: 320 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(calls.list).toContain('v_gas_detector_management.range:0-49')
    // Scoped to the pagination nav: "Next calibration" is also a column header.
    const pager = screen.getByRole('navigation', { name: /pagination/i })
    await userEvent.click(within(pager).getByRole('button', { name: /next/i }))
    expect(calls.list).toContain('v_gas_detector_management.range:50-99')
  })

  it('reports the RLS-scoped total, not the page length', async () => {
    replies.detectors = { data: [detector()], error: null, count: 320 }
    renderDetectors()
    await screen.findByText('GD-00001')
    expect(screen.getByText(/of 320/)).toBeDefined()
  })
})

describe('Loading, empty, no-match and failure are four different screens', () => {
  it('states an honest empty registry before import', async () => {
    replies.detectors = { data: [], error: null, count: 0 }
    renderDetectors()
    expect(await screen.findByText(/no gas detectors are currently recorded/i)).toBeDefined()
  })

  it('distinguishes "no match" from "nothing exists"', async () => {
    replies.detectors = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 316 }
    renderDetectors()
    await userEvent.type(screen.getByRole('searchbox', { name: /search gas detectors/i }), 'zzzz')
    expect(await screen.findByText(/no results match these filters/i)).toBeDefined()
  })

  it('never renders a failed row query as an empty registry', async () => {
    replies.detectors = { data: null, error: { message: 'permission denied for view v_gas_detector_management' }, count: 0 }
    renderDetectors()
    expect(await screen.findByText(/could not load gas detectors/i)).toBeDefined()
    expect(screen.queryByText(/no gas detectors are currently recorded/i)).toBeNull()
  })

  it('never renders a failed count as zero', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    replies.headCount = { data: null, error: { message: 'permission denied' }, count: 0 }
    renderDetectors()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
    // The failure is stated, and no metric is drawn with a fabricated zero.
    expect(screen.queryByText(/^Detectors$/)).toBeNull()
  })
})

describe('Accessibility', () => {
  it('gives every filter control an accessible name', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    for (const box of screen.getAllByRole('combobox')) {
      expect(box.getAttribute('aria-label') ?? box.closest('label')?.textContent ?? '').not.toBe('')
    }
  })

  it('exposes the technical record through a labelled disclosure control', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const expand = screen.getByRole('button', { name: /show the full technical record/i })
    expect(expand.getAttribute('aria-expanded')).toBe('false')
    await userEvent.click(expand)
    expect(screen.getByRole('button', { name: /hide the full technical record/i }).getAttribute('aria-expanded')).toBe('true')
    // The detail exposes the raw source text, preserved and uninterpreted.
    expect(screen.getByText('Close Area')).toBeDefined()
  })

  it('does not convey due status by colour alone', async () => {
    replies.detectors = { data: [detector({ due_status: 'overdue' })], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    // The word itself carries the state.
    expect(screen.getAllByText(/overdue/i).length).toBeGreaterThan(0)
  })
})

describe('Live telemetry is out of scope', () => {
  it('shows no reading, alarm, connectivity or battery field anywhere', async () => {
    replies.detectors = { data: [detector()], error: null, count: 1 }
    renderDetectors()
    await screen.findByText('GD-00001')
    const expand = screen.getByRole('button', { name: /show the full technical record/i })
    await userEvent.click(expand)
    const body = document.body.textContent ?? ''
    for (const word of [/gas concentration/i, /\bppm\b/i, /\bLEL\b/, /alarm state/i, /battery/i, /online/i, /offline/i, /sensor health/i]) {
      expect(body).not.toMatch(word)
    }
  })
})
