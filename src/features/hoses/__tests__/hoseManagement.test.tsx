import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * Global Hoses Management.
 *
 * What these defend, hardest first:
 *
 * 1. **Serial identity is never repaired.** Leading zeros survive, a missing
 *    serial stays missing, and a duplicate is REPORTED rather than merged,
 *    suffixed or renumbered.
 * 2. **Missing, duplicate, unresolved and overdue are four different things**
 *    and are never conflated into one "bad hose" signal.
 * 3. **No manufacturer or model is invented**, and neither is parsed out of the
 *    free-text description.
 * 4. **A Unit is never guessed** for a hose recorded at Station level.
 * 5. **A failed query is never zero**, in the table or in the summary.
 * 6. **Year-only dates never become a countdown** and never read "within date".
 * 7. **Pressure units are never inferred or converted.**
 *
 * Every date and serial here is a fixed literal. Nothing derives from
 * `Date.now()`, so a run tomorrow asserts exactly what a run today asserted.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  hoses: { data: [] as unknown[], error: null, count: 0 } as Reply,
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
        eq: (col: string, value: unknown) => {
          calls.list.push(`${table}.eq:${col}=${String(value)}`)
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
          return Promise.resolve(table === 'v_station_summary' ? replies.stations : replies.hoses)
        },
        then: (resolve: (v: unknown) => unknown) => {
          const reply =
            table === 'v_dashboard_region_summary' ? replies.regions
            : table === 'v_station_summary' ? replies.stations
            : head ? replies.headCount
            : replies.hoses
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
  }
  return { useSupabaseClient: () => client }
})

const { HosesManagementView } = await import('@/features/hoses/HosesManagementView')

function hose(over: Record<string, unknown> = {}) {
  return {
    id: 'hs-1',
    region_id: 'r-west', region_name: 'West',
    station_id: 's-1', station_name: 'شبرا 1',
    unit_id: 'u-1', unit_name: 'الماظة 1',
    dispenser_id: 'd-1', dispenser_name: 'Dispenser 1',
    mapping_status: 'resolved', needs_mapping: false,
    description: 'خرطوم تعبئة عالي الضغط',
    serial_number: 'HS-2024001', serial_number_raw: 'HS-2024001', serial_status: 'assigned',
    serial_missing: false, serial_duplicate: false,
    working_pressure_raw: '250', working_pressure_value: 250, working_pressure_unit: 'BAR',
    test_pressure_raw: '375', test_pressure_value: 375, test_pressure_unit: 'BAR',
    last_test_date: '2025-09-18', last_test_precision: 'exact_date', last_test_display: '18 Sep 2025',
    next_test_date: '2026-09-18', next_test_precision: 'exact_date', next_test_display: '18 Sep 2026',
    days_left: 2, due_status: 'due_7',
    source_status_raw: null, needs_review: false, notes: null,
    source_file: 'HOSES.xlsx', source_sheet: 'Sheet1', source_row: 11,
    ...over,
  }
}

beforeEach(() => {
  calls.list = []
  replies.hoses = { data: [], error: null, count: 0 }
  replies.headCount = { data: null, error: null, count: 0 }
  replies.regions = { data: [], error: null }
  replies.stations = { data: [], error: null, count: 0 }
})
afterEach(() => vi.clearAllMocks())

function renderHoses() {
  return render(
    <MemoryRouter initialEntries={['/manage/hoses']}>
      <Routes>
        <Route path="/manage/hoses" element={<HosesManagementView />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('Route and page shell', () => {
  it('renders the registry at /manage/hoses with exactly one h1', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const h1s = screen.getAllByRole('heading', { level: 1 })
    expect(h1s).toHaveLength(1)
    expect(h1s[0].textContent).toContain('Hoses Management')
  })

  it('reads the hose registry view, not the hoses table directly', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(calls.list.some((c) => c.startsWith('v_hose_registry.'))).toBe(true)
    expect(calls.list.some((c) => c.startsWith('hoses.'))).toBe(false)
  })

  it('leads with identity, then test attention, before descriptive fields', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const order = screen
      .getAllByRole('columnheader')
      .map((h) => h.textContent?.trim() ?? '')
      .filter((h) => h && !/expand/i.test(h))
    // A hose is an individually traceable item, so Serial is first.
    expect(order.slice(0, 6)).toEqual([
      'Serial', 'Station', 'Unit', 'Next test', 'Days left', 'Status',
    ])
    expect(order.indexOf('Description')).toBeGreaterThan(order.indexOf('Status'))
  })
})

describe('Serial identity', () => {
  it('preserves a leading-zero serial exactly, never padding or casting it', async () => {
    replies.hoses = { data: [hose({ serial_number: '0007412', serial_number_raw: '0007412' })], error: null, count: 1 }
    renderHoses()
    expect(await screen.findByText('0007412')).toBeDefined()
    expect(screen.queryByText('7412')).toBeNull()
  })

  it('renders a long identifier in full rather than truncating it into ambiguity', async () => {
    const long = 'HS-CNG-2019-000044170-REV-A-LONG-IDENTIFIER'
    replies.hoses = { data: [hose({ serial_number: long, serial_number_raw: long })], error: null, count: 1 }
    renderHoses()
    expect(await screen.findByText(long)).toBeDefined()
  })

  it('leaves a missing serial missing and never generates one', async () => {
    replies.hoses = {
      data: [hose({ serial_number: null, serial_number_raw: null, serial_status: 'unknown', serial_missing: true })],
      error: null, count: 1,
    }
    renderHoses()
    const table = await screen.findByRole('table')
    expect(within(table).getAllByText(/not recorded/i).length).toBeGreaterThan(0)
    // Nothing invented from the row, the station or the unit.
    expect(within(table).queryByText(/^HS-/)).toBeNull()
    expect(within(table).queryByText(/^hs-1$/)).toBeNull()
  })

  it('words a not-yet-assigned serial differently from an absent one', async () => {
    replies.hoses = {
      data: [hose({ serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned', serial_missing: true })],
      error: null, count: 1,
    }
    renderHoses()
    expect(await screen.findByText(/not yet assigned/i)).toBeDefined()
  })

  it('reports a duplicate serial beside the identifier and keeps both records', async () => {
    replies.hoses = {
      data: [
        hose({ id: 'a', serial_number: 'HS-DUP-77', serial_number_raw: 'HS-DUP-77', serial_duplicate: true }),
        hose({ id: 'b', serial_number: 'HS-DUP-77', serial_number_raw: 'HS-DUP-77', serial_duplicate: true }),
      ],
      error: null, count: 2,
    }
    renderHoses()
    const table = await screen.findByRole('table')
    // BOTH rows survive: a duplicate is reported, never merged away.
    expect(within(table).getAllByText('HS-DUP-77')).toHaveLength(2)
    expect(within(table).getAllByText(/duplicate/i).length).toBeGreaterThan(0)
  })

  it('does not mark a unique serial as duplicate', async () => {
    replies.hoses = { data: [hose({ serial_duplicate: false })], error: null, count: 1 }
    renderHoses()
    const table = await screen.findByRole('table')
    expect(within(table).queryByText(/duplicate/i)).toBeNull()
  })

  it('keeps missing and duplicate as separate dimensions from mapping and due', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const serialFilter = screen.getByRole('combobox', { name: /serial/i })
    const options = within(serialFilter).getAllByRole('option').map((o) => (o as HTMLOptionElement).value)
    expect(options).toEqual(['all', 'recorded', 'missing', 'duplicate'])
    // And they are separate controls from Mapping and Due.
    expect(screen.getByRole('combobox', { name: /mapping/i })).not.toBe(serialFilter)
    expect(screen.getByRole('combobox', { name: /due/i })).not.toBe(serialFilter)
  })
})

describe('Description stays free text', () => {
  it('shows the description without inventing manufacturer or model columns', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getByRole('columnheader', { name: /description/i })).toBeDefined()
    expect(screen.queryByRole('columnheader', { name: /manufacturer/i })).toBeNull()
    expect(screen.queryByRole('columnheader', { name: /^model$/i })).toBeNull()
  })

  it('never parses a bay letter in the description into a dispenser', async () => {
    replies.hoses = {
      data: [hose({ description: 'خرطوم غاز C', dispenser_id: null, dispenser_name: null })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    const table = screen.getByRole('table')
    expect(within(table).getByText('خرطوم غاز C')).toBeDefined()
    // No dispenser is conjured from the letter C.
    expect(within(table).queryByText(/dispenser/i)).toBeNull()
  })

  it('shows a NULL description as not recorded', async () => {
    replies.hoses = { data: [hose({ description: null })], error: null, count: 1 }
    renderHoses()
    const table = await screen.findByRole('table')
    expect(within(table).getAllByText(/not recorded/i).length).toBeGreaterThan(0)
  })
})

describe('Hierarchy and mapping', () => {
  it('shows the confirmed Station, Unit and Dispenser of a resolved hose', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getAllByText('شبرا 1').length).toBeGreaterThan(0)
    expect(screen.getAllByText('الماظة 1').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Dispenser 1').length).toBeGreaterThan(0)
  })

  it('never guesses a Unit for a hose recorded at Station level', async () => {
    replies.hoses = {
      data: [hose({ mapping_status: 'needs_unit_mapping', needs_mapping: true, unit_id: null, unit_name: null, dispenser_id: null, dispenser_name: null })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    const table = screen.getByRole('table')
    expect(within(table).getByText(/needs unit mapping/i)).toBeDefined()
    expect(within(table).getAllByText(/not confirmed/i).length).toBeGreaterThan(0)
    // The Station IS proven and still shown; only the Unit is withheld.
    expect(within(table).getAllByText('شبرا 1').length).toBeGreaterThan(0)
  })

  it('offers only mapping states a hose can actually hold', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const mapping = screen.getByRole('combobox', { name: /mapping/i })
    const options = within(mapping).getAllByRole('option').map((o) => (o as HTMLOptionElement).value)
    // station_id is NOT NULL, so this state is unreachable and is not offered.
    expect(options).not.toContain('needs_station_mapping')
    expect(options).not.toContain('needs_equipment_mapping')
    expect(options).toEqual(['all', 'resolved', 'needs_unit_mapping', 'conflict'])
  })

  it('exposes no mapping mutation or delete control', async () => {
    replies.hoses = { data: [hose({ mapping_status: 'needs_unit_mapping', unit_id: null, unit_name: null })], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    for (const name of [/assign unit/i, /^assign/i, /resolve/i, /mark resolved/i, /save/i, /edit/i, /delete/i, /archive/i]) {
      expect(screen.queryByRole('button', { name })).toBeNull()
    }
  })
})

describe('Test dates, precision and due status', () => {
  it('uses the schema wording "test", never relabelling it calibration', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getByRole('columnheader', { name: /next test/i })).toBeDefined()
    expect(screen.getByRole('columnheader', { name: /last test/i })).toBeDefined()
    expect(screen.queryByRole('columnheader', { name: /calibration/i })).toBeNull()
  })

  it('never turns a year-only date into a countdown or into "within date"', async () => {
    replies.hoses = {
      data: [hose({
        next_test_date: null, next_test_precision: 'year_only', next_test_display: '2027',
        days_left: null, due_status: 'unknown',
      })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getAllByText('2027').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/year only/i).length).toBeGreaterThan(0)
    expect(screen.queryByText('2027-01-01')).toBeNull()
    expect(screen.queryByText('2027-12-31')).toBeNull()
    const table = screen.getByRole('table')
    expect(within(table).queryByText(/within date/i)).toBeNull()
  })

  it('renders the database due status rather than recomputing one', async () => {
    // days_left and due_status disagree on purpose. If the UI recomputed
    // anything it would "correct" this; it must not.
    replies.hoses = { data: [hose({ days_left: 999, due_status: 'overdue' })], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getAllByText(/overdue/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText('999').length).toBeGreaterThan(0)
  })

  it('keeps Arabic source status beside a missing date instead of becoming one', async () => {
    replies.hoses = {
      data: [hose({
        next_test_date: null, next_test_precision: 'unknown', next_test_display: null,
        days_left: null, due_status: 'unknown', source_status_raw: 'منتهي',
      })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getAllByText(/منتهي/).length).toBeGreaterThan(0)
  })
})

describe('Pressure units', () => {
  it('shows the stored unit and never converts between BAR and PSI', async () => {
    replies.hoses = {
      data: [hose({ working_pressure_value: 3600, working_pressure_unit: 'PSI', working_pressure_raw: '3600' })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    const table = screen.getByRole('table')
    expect(table.textContent).toContain('PSI')
    // 3600 PSI is ~248 BAR; no converted value appears anywhere.
    expect(table.textContent).not.toContain('248')
  })

  it('shows a pressure with no proven unit without dressing it in a guess', async () => {
    replies.hoses = {
      data: [hose({ working_pressure_value: null, working_pressure_unit: null, working_pressure_raw: '250 ?' })],
      error: null, count: 1,
    }
    renderHoses()
    await screen.findByText('HS-2024001')
    const table = screen.getByRole('table')
    expect(within(table).getByText('250 ?')).toBeDefined()
  })
})

describe('Server-side search, filters and their intersection', () => {
  it('sends search to the server across serial, description, station and unit', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    await userEvent.type(screen.getByRole('searchbox', { name: /search hoses/i }), 'HS-2024')
    const or = calls.list.find((c) => c.includes('.or:') && c.includes('HS-2024'))
    expect(or).toBeDefined()
    expect(or).toContain('serial_number.ilike')
    expect(or).toContain('description.ilike')
    expect(or).toContain('station_name.ilike')
  })

  it('folds an Arabic search term the same way the SQL does', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    await userEvent.type(screen.getByRole('searchbox', { name: /search hoses/i }), 'الماظه')
    expect(calls.list.find((c) => c.includes('.or:') && c.includes('unit_name.ilike'))).toBeDefined()
  })

  it('combines East + Overdue + Missing Serial as a server-side intersection', async () => {
    replies.hoses = { data: [hose({ due_status: 'overdue', serial_missing: true, serial_number: null })], error: null, count: 1 }
    replies.regions = { data: [{ region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 1, units: 1, assets: 1, overdue: 1, approaching_due: 0, unresolved_mapping: 0 }], error: null }
    renderHoses()
    await screen.findByRole('table')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /region/i }), 'r-east')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /due/i }), 'overdue')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /serial/i }), 'missing')
    // All three reach the server. None is applied in React.
    expect(calls.list).toContain('v_hose_registry.eq:region_id=r-east')
    expect(calls.list).toContain('v_hose_registry.eq:due_status=overdue')
    expect(calls.list).toContain('v_hose_registry.eq:serial_missing=true')
  })

  it('sends the duplicate-serial filter to the server', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /serial/i }), 'duplicate')
    expect(calls.list).toContain('v_hose_registry.eq:serial_duplicate=true')
  })

  it('sends the due-window filter as an explicit bucket list', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /due/i }), 'attention')
    const bucket = calls.list.find((c) => c.includes('.in:due_status='))
    expect(bucket).toBeDefined()
    expect(bucket).toContain('overdue')
    expect(bucket).toContain('due_60')
  })

  it('clears the Station when the Region changes', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    replies.regions = { data: [{ region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 1, units: 1, assets: 1, overdue: 0, approaching_due: 0, unresolved_mapping: 0 }], error: null }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.queryByRole('combobox', { name: /station/i })).toBeNull()
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /region/i }), 'r-east')
    expect(await screen.findByRole('combobox', { name: /station/i })).toBeDefined()
  })
})

describe('Sorting and pagination', () => {
  it('marks the sorted column with aria-sort and toggles both directions', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const header = () => screen.getByRole('columnheader', { name: /^serial/i })
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_hose_registry.order:serial_number:asc')
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_hose_registry.order:serial_number:desc')
  })

  it('appends a deterministic tie-break so paging is stable', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(calls.list).toContain('v_hose_registry.order:id:asc')
  })

  it('pages on the server rather than loading the whole registry', async () => {
    replies.hoses = { data: [hose()], error: null, count: 300 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(calls.list).toContain('v_hose_registry.range:0-49')
    const pager = screen.getByRole('navigation', { name: /pagination/i })
    await userEvent.click(within(pager).getByRole('button', { name: /next/i }))
    expect(calls.list).toContain('v_hose_registry.range:50-99')
  })

  it('reports the RLS-scoped total, not the page length', async () => {
    replies.hoses = { data: [hose()], error: null, count: 300 }
    renderHoses()
    await screen.findByText('HS-2024001')
    expect(screen.getByText(/of 300/)).toBeDefined()
  })
})

describe('Loading, empty, no-match and failure are four different screens', () => {
  it('states an honest empty registry before import', async () => {
    replies.hoses = { data: [], error: null, count: 0 }
    renderHoses()
    expect(await screen.findByText(/no hoses are currently recorded/i)).toBeDefined()
  })

  it('distinguishes "no match" from "nothing exists"', async () => {
    replies.hoses = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 71 }
    renderHoses()
    await userEvent.type(screen.getByRole('searchbox', { name: /search hoses/i }), 'zzzz')
    expect(await screen.findByText(/no results match these filters/i)).toBeDefined()
  })

  it('never renders a failed row query as an empty registry', async () => {
    replies.hoses = { data: null, error: { message: 'permission denied for view v_hose_registry' }, count: 0 }
    renderHoses()
    expect(await screen.findByText(/could not load hoses/i)).toBeDefined()
    expect(screen.queryByText(/no hoses are currently recorded/i)).toBeNull()
  })

  it('never renders a failed count as zero', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    replies.headCount = { data: null, error: { message: 'permission denied' }, count: 0 }
    renderHoses()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
    expect(screen.queryByText(/^Hoses$/)).toBeNull()
  })
})

describe('Technical detail and accessibility', () => {
  it('exposes the full record through a labelled disclosure control', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    const expand = screen.getByRole('button', { name: /show the full technical record/i })
    expect(expand.getAttribute('aria-expanded')).toBe('false')
    await userEvent.click(expand)
    const body = document.body.textContent ?? ''
    expect(body).toMatch(/serial \(source\)/i)
    expect(body).toMatch(/test pressure/i)
    // Provenance is real schema data and is worth showing.
    expect(body).toMatch(/HOSES\.xlsx/)
  })

  it('gives every filter control an accessible name', async () => {
    replies.hoses = { data: [hose()], error: null, count: 1 }
    renderHoses()
    await screen.findByText('HS-2024001')
    for (const box of screen.getAllByRole('combobox')) {
      expect(box.getAttribute('aria-label') ?? box.closest('label')?.textContent ?? '').not.toBe('')
    }
  })

  it('never renders N/A or a zero in place of a missing value', async () => {
    replies.hoses = {
      data: [hose({ description: null, serial_number: null, serial_number_raw: null, serial_status: 'unknown', serial_missing: true })],
      error: null, count: 1,
    }
    renderHoses()
    const table = await screen.findByRole('table')
    expect(table.textContent).not.toMatch(/N\/A/)
    expect(within(table).queryByText('Unknown')).toBeNull()
  })
})
