import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * The Unit workspace.
 *
 * What these tests defend, hardest first:
 *
 * 1. **SRV Unit visibility.** A valve is shown on a Unit only when its Unit is
 *    proven. The rule lives in `v_unit_srvs`, so these assert the UI reads that
 *    view and never re-derives the rule — including that it never widens it.
 * 2. **Ownership comes from the database.** Every tab queries with
 *    `unit_id = :unitId`; the URL is a lookup key, never authorization.
 * 3. **A failed query is never an empty tab**, and a failed count is never `0`.
 * 4. **Nothing technical is fabricated** — no invented serial, no guessed
 *    pressure unit, no year-only date turned into a countdown.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
}

const replies = vi.hoisted(() => ({
  unit: { data: null as unknown, error: null } as Reply,
  compressors: { data: [] as unknown[], error: null } as Reply,
  dispensers: { data: [] as unknown[], error: null } as Reply,
  vessels: { data: [] as unknown[], error: null } as Reply,
  detectors: { data: [] as unknown[], error: null } as Reply,
  hoses: { data: [] as unknown[], error: null } as Reply,
  srvs: { data: [] as unknown[], error: null } as Reply,
}))

/** Every filter the view applied, so ownership can be asserted, not assumed. */
const calls = vi.hoisted(() => ({ list: [] as string[] }))

vi.mock('@/lib/supabase/client', () => {
  const client = {
    from(table: string) {
      const filters: Record<string, string> = {}
      const chain: Record<string, unknown> = {
        select: () => chain,
        eq: (col: string, value: string) => {
          filters[col] = value
          calls.list.push(`${table}.eq:${col}=${value}`)
          return chain
        },
        order: () => chain,
        maybeSingle: () => Promise.resolve(replies.unit),
        then: (resolve: (v: unknown) => unknown) => {
          const key =
            table === 'compressors' ? 'compressors'
            : table === 'dispensers' ? 'dispensers'
            : table === 'v_vessel_management' ? 'vessels'
            : table === 'v_gas_detector_management' ? 'detectors'
            : table === 'v_hose_management' ? 'hoses'
            : 'srvs'
          const reply = replies[key as keyof typeof replies]
          // The vessel view is shared by two tabs and discriminated by
          // asset_type, exactly as the real view is.
          if (table === 'v_vessel_management' && filters.asset_type && Array.isArray(reply.data)) {
            return Promise.resolve({
              data: (reply.data as { asset_type: string }[]).filter((r) => r.asset_type === filters.asset_type),
              error: reply.error,
            }).then(resolve)
          }
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
  }
  return { useSupabaseClient: () => client }
})

const { UnitWorkspace } = await import('@/features/units/UnitWorkspace')
const { OverviewSection } = await import('@/features/units/sections/OverviewSection')
const { CompressorSection } = await import('@/features/units/sections/CompressorSection')
const { DispenserSection } = await import('@/features/units/sections/DispenserSection')
const { VesselSection } = await import('@/features/units/sections/VesselSection')
const { DetectorSection } = await import('@/features/units/sections/DetectorSection')
const { HoseSection } = await import('@/features/units/sections/HoseSection')
const { SrvSection } = await import('@/features/units/sections/SrvSection')

const UNIT = {
  unit_id: 'u-1',
  unit_name: 'الماظة 1',
  normalized_name: null,
  station_id: 's-1',
  station_name: 'الماظة',
  region_id: 'r-east',
  region_code: 'east',
  region_name: 'East',
  job_number: '0042-A',
  job_number_raw: '0042-A',
  dispenser_count_reported: 4,
  hose_count_reported: 8,
  storage_count_reported: 3,
  notes: null,
  needs_review: false,
  archived_at: null,
  compressors: 2,
  dispensers: 1,
  storage_vessels: 3,
  recovery_tanks: 1,
  gas_detectors: 2,
  hoses: 1,
  installed_srvs: 2,
  overdue: 1,
}

function srv(over: Record<string, unknown> = {}) {
  return {
    id: 'v-1', unit_id: 'u-1', station_id: 's-1',
    mapping_status: 'resolved', mapping_label: 'Resolved', needs_mapping: false,
    expected_parent_kind: 'compressor', location_raw: 'Stage',
    parent_kind: 'compressor', parent_id: 'c-1', parent_label: 'F-19822',
    tag_number: 'PSV-101', serial_number: 'RV-880124', serial_number_raw: 'RV-880124',
    serial_status: 'assigned', part_number: null, manufacturer: 'Leser',
    size_type: null, inlet_size: null, outlet_size: null,
    set_pressure_raw: '250', pressure_min: 250, pressure_max: 250, pressure_unit: 'BAR',
    last_calibration_date: '2026-01-14', last_calibration_precision: 'exact_date', last_calibration_display: '14 Jan 2026',
    next_calibration_date: '2026-09-10', next_calibration_precision: 'exact_date', next_calibration_display: '10 Sep 2026',
    days_left: -5, due_status: 'overdue',
    source_status_raw: null, needs_review: false, notes: null,
    ...over,
  }
}

function vessel(over: Record<string, unknown> = {}) {
  return {
    asset_type: 'storage_vessel', id: 'sv-1', unit_id: 'u-1', station_id: 's-1',
    mapping_status: 'resolved', needs_mapping: false,
    manufacturer: 'CIMC', model: 'CNG-80',
    serial_number: 'SV-00001', serial_number_raw: 'SV-00001', serial_status: 'assigned',
    compressor_type_raw: null,
    last_inspection_date: '2024-03-11', last_inspection_precision: 'exact_date', last_inspection_display: '11 Mar 2024',
    next_inspection_date: '2026-10-02', next_inspection_precision: 'exact_date', next_inspection_display: '2 Oct 2026',
    days_left: 17, due_status: 'due_30',
    source_status_raw: null, needs_review: false, notes: null,
    ...over,
  }
}

const EMPTY: Reply = { data: [], error: null }

beforeEach(() => {
  calls.list = []
  replies.unit = { data: UNIT, error: null }
  replies.compressors = { ...EMPTY }
  replies.dispensers = { ...EMPTY }
  replies.vessels = { ...EMPTY }
  replies.detectors = { ...EMPTY }
  replies.hoses = { ...EMPTY }
  replies.srvs = { ...EMPTY }
})
afterEach(() => vi.clearAllMocks())

/** Mounts the workspace with the same nested routes the application uses. */
function renderUnit(path = '/units/u-1') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/units/:unitId" element={<UnitWorkspace />}>
          <Route index element={<OverviewSection />} />
          <Route path="compressor" element={<CompressorSection />} />
          <Route path="recovery-tank" element={<VesselSection kind="recovery_tank" />} />
          <Route path="dispensers" element={<DispenserSection />} />
          <Route path="storage" element={<VesselSection kind="storage_vessel" />} />
          <Route path="gas-detectors" element={<DetectorSection />} />
          <Route path="hoses" element={<HoseSection />} />
          <Route path="srvs" element={<SrvSection />} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('Unit route and header', () => {
  it('shows the Unit, its Station and its Region', async () => {
    renderUnit()
    expect(await screen.findByRole('heading', { level: 1 })).toHaveProperty('textContent', 'الماظة 1')
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
    expect(screen.getByText(/East Region/)).toBeDefined()
  })

  it('does not reveal whether an unreadable Unit exists', async () => {
    replies.unit = { data: null, error: null }
    renderUnit()
    expect(await screen.findByText(/unit not found/i)).toBeDefined()
    expect(screen.getByText(/does not exist, or it is outside/i)).toBeDefined()
  })

  it('shows an error rather than an empty workspace when the Unit query fails', async () => {
    replies.unit = { data: null, error: { message: 'JWT expired' } }
    renderUnit()
    expect(await screen.findByText(/could not load/i)).toBeDefined()
    expect(screen.queryByText(/unit not found/i)).toBeNull()
  })
})

describe('Tab navigation and counts', () => {
  it('deep-links straight to a section', async () => {
    replies.srvs = { data: [srv()], error: null }
    renderUnit('/units/u-1/srvs')
    const current = await screen.findByRole('link', { current: 'page' })
    expect(current.textContent).toContain('SRVs')
  })

  it('shows real counts from the Unit summary', async () => {
    renderUnit()
    // Scoped to the tab strip: "Storage" also appears in the Overview grid.
    const tabs = await screen.findByRole('navigation', { name: /unit sections/i })
    const storage = within(tabs).getByRole('link', { name: /Storage/ })
    expect(storage.textContent).toContain('3')
  })

  it('omits counts entirely when the summary could not be loaded — never [0]', async () => {
    replies.unit = { data: null, error: { message: 'boom' } }
    renderUnit()
    await screen.findByText(/could not load/i)
    // No tab strip at all rather than a strip full of misleading zeros.
    expect(screen.queryByRole('navigation', { name: /unit sections/i })).toBeNull()
  })
})

describe('Equipment ownership', () => {
  // Each tab must narrow by unit_id in the QUERY. A tab that fetched by asset
  // id and trusted the URL would show another Unit's equipment.
  it.each([
    ['/units/u-1/compressor', 'compressors'],
    ['/units/u-1/dispensers', 'dispensers'],
    ['/units/u-1/storage', 'v_vessel_management'],
    ['/units/u-1/recovery-tank', 'v_vessel_management'],
    ['/units/u-1/gas-detectors', 'v_gas_detector_management'],
    ['/units/u-1/hoses', 'v_hose_management'],
    ['/units/u-1/srvs', 'v_unit_srvs'],
  ])('%s filters %s by unit_id', async (path, table) => {
    renderUnit(path)
    await waitFor(() => {
      expect(calls.list).toContain(`${table}.eq:unit_id=u-1`)
    })
  })

  it('discriminates storage vessels from recovery tanks on the shared view', async () => {
    replies.vessels = {
      data: [vessel(), vessel({ id: 'rt-1', asset_type: 'recovery_tank', serial_number: 'RT-9' })],
      error: null,
    }
    renderUnit('/units/u-1/storage')
    expect(await screen.findByText('SV-00001')).toBeDefined()
    expect(screen.queryByText('RT-9')).toBeNull()
  })
})

describe('Unit SRV visibility rules', () => {
  it('shows a resolved SRV with its named equipment parent', async () => {
    replies.srvs = { data: [srv()], error: null }
    renderUnit('/units/u-1/srvs')
    expect(await screen.findByText('RV-880124')).toBeDefined()
    expect(screen.getByText('F-19822')).toBeDefined()
    // Scoped to the row: "Compressor" is also a tab label.
    const row = screen.getByText('F-19822').closest('tr')!
    expect(within(row).getByText('Compressor')).toBeDefined()
  })

  it('shows a needs_equipment_mapping SRV and states the parent is unresolved', async () => {
    replies.srvs = {
      data: [srv({ id: 'v-2', mapping_status: 'needs_equipment_mapping', needs_mapping: true, parent_kind: null, parent_id: null, parent_label: null })],
      error: null,
    }
    renderUnit('/units/u-1/srvs')
    expect(await screen.findAllByText(/needs equipment mapping/i)).not.toHaveLength(0)
  })

  // The rule is enforced in v_unit_srvs. These prove the UI reads that view and
  // does not widen it: whatever the view withholds never reaches a Unit.
  it('never shows a valve the Unit view withholds', async () => {
    // v_unit_srvs returns nothing for valves that are needs_unit_mapping,
    // needs_station_mapping, conflict, or warehouse stock.
    replies.srvs = { data: [], error: null }
    renderUnit('/units/u-1/srvs')
    expect(await screen.findByText(/no unit-confirmed relief valves/i)).toBeDefined()
    expect(screen.getByText(/awaiting Station or Unit confirmation/i)).toBeDefined()
  })

  it('reads v_unit_srvs, never installed_relief_valves directly', async () => {
    renderUnit('/units/u-1/srvs')
    await waitFor(() => expect(calls.list).toContain('v_unit_srvs.eq:unit_id=u-1'))
    // Querying the base table would bypass the visibility predicate entirely.
    expect(calls.list.some((c) => c.startsWith('installed_relief_valves.'))).toBe(false)
    expect(calls.list.some((c) => c.startsWith('warehouse_relief_valves.'))).toBe(false)
  })

  it('classifies SS-4R3A as a Part Number and leaves the serial absent', async () => {
    replies.srvs = {
      data: [srv({ serial_number: null, serial_number_raw: 'SS-4R3A', serial_status: 'unknown', part_number: 'SS-4R3A' })],
      error: null,
    }
    renderUnit('/units/u-1/srvs')
    const row = (await screen.findByText('SS-4R3A')).closest('tr')
    expect(row).not.toBeNull()
    const cells = [...row!.querySelectorAll('th,td')].map((c) => c.textContent ?? '')
    // The serial cell reads "not recorded", NOT SS-4R3A.
    expect(cells[1]).toMatch(/not recorded/i)
    expect(cells[2]).toContain('SS-4R3A')
  })

  it('labels the source Location as a hint, never as an equipment identity', async () => {
    replies.srvs = {
      data: [srv({ mapping_status: 'needs_equipment_mapping', needs_mapping: true, parent_kind: null, parent_label: null })],
      error: null,
    }
    renderUnit('/units/u-1/srvs')
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    expect(screen.getByText(/source context, not an identity/i)).toBeDefined()
    expect(screen.getByText(/which one is unknown/i)).toBeDefined()
  })

  it('filters by mapping status within the Unit-confirmed set', async () => {
    replies.srvs = {
      data: [srv(), srv({ id: 'v-2', mapping_status: 'needs_equipment_mapping', needs_mapping: true, serial_number: 'RV-2', parent_kind: null, parent_label: null })],
      error: null,
    }
    renderUnit('/units/u-1/srvs')
    expect(await screen.findByText('RV-880124')).toBeDefined()
    await userEvent.selectOptions(screen.getByLabelText(/mapping/i), 'needs_equipment_mapping')
    await waitFor(() => expect(screen.queryByText('RV-880124')).toBeNull())
    expect(screen.getByText('RV-2')).toBeDefined()
  })
})

describe('Technical data presentation', () => {
  it('never turns a year-only date into a countdown or into "within date"', async () => {
    replies.vessels = {
      data: [vessel({
        next_inspection_date: null, next_inspection_precision: 'year_only',
        next_inspection_display: '2027', days_left: null, due_status: 'unknown',
      })],
      error: null,
    }
    renderUnit('/units/u-1/storage')
    expect(await screen.findByText('2027')).toBeDefined()
    expect(screen.getByText(/year only/i)).toBeDefined()
    expect(screen.getByText(/no exact date/i)).toBeDefined()
    expect(screen.queryByText(/within date/i)).toBeNull()
  })

  it('shows a pressure with the stored unit and never invents one', async () => {
    replies.hoses = {
      data: [{
        id: 'h-1', unit_id: 'u-1', station_id: 's-1', dispenser_id: null, dispenser_name: null,
        mapping_status: 'resolved', needs_mapping: false, description: null,
        serial_number: 'HS-1', serial_number_raw: 'HS-1', serial_status: 'assigned',
        working_pressure_raw: '250', working_pressure_value: 250, working_pressure_unit: 'BAR',
        // No unit proven for the test pressure: the number stands alone.
        test_pressure_raw: '375', test_pressure_value: 375, test_pressure_unit: null,
        last_test_date: null, last_test_precision: 'unknown', last_test_display: null,
        next_test_date: null, next_test_precision: 'unknown', next_test_display: null,
        days_left: null, due_status: 'unknown', source_status_raw: null, needs_review: false, notes: null,
      }],
      error: null,
    }
    renderUnit('/units/u-1/hoses')
    expect(await screen.findByText('BAR')).toBeDefined()
    expect(screen.queryByText('PSI')).toBeNull()
    expect(screen.getByText('375')).toBeDefined()
  })

  it('distinguishes a not-yet-assigned serial from an absent one', async () => {
    replies.compressors = {
      data: [{
        id: 'c-1', unit_id: 'u-1', station_id: 's-1', mapping_status: 'resolved',
        needs_review: false, notes: null, source_status_raw: null,
        manufacturer: null, manufacturer_raw: null, model: null, model_raw: null, job_number: null,
        serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned',
        part_number: null, total_running_hours: null, average_hours_per_day: null,
        average_gas_sales_per_day: null, average_gas_sales_raw: null,
      }],
      error: null,
    }
    renderUnit('/units/u-1/compressor')
    // A stated fact, not a gap (principle #20).
    expect(await screen.findByText(/not yet assigned/i)).toBeDefined()
  })

  it('keeps source status text beside a missing date instead of converting it', async () => {
    replies.vessels = {
      data: [vessel({
        next_inspection_date: null, next_inspection_precision: 'unknown', next_inspection_display: null,
        days_left: null, due_status: 'unknown', source_status_raw: 'منتهية',
      })],
      error: null,
    }
    renderUnit('/units/u-1/storage')
    expect(await screen.findByText('منتهية')).toBeDefined()
  })
})

describe('Tab states', () => {
  it('an empty tab and a failed tab never look the same', async () => {
    replies.detectors = { data: [], error: null }
    const empty = renderUnit('/units/u-1/gas-detectors')
    expect(await screen.findByText(/no gas detectors are recorded/i)).toBeDefined()
    empty.unmount()

    replies.detectors = { data: null, error: { message: 'permission denied' } }
    renderUnit('/units/u-1/gas-detectors')
    expect(await screen.findByText(/could not load gas detectors/i)).toBeDefined()
    expect(screen.queryByText(/no gas detectors are recorded/i)).toBeNull()
  })

  it('expands a row to the full technical record without leaving the Unit', async () => {
    replies.vessels = { data: [vessel()], error: null }
    renderUnit('/units/u-1/storage')
    const toggle = (await screen.findAllByRole('button', { name: /show the full technical record/i }))[0]
    expect(toggle.getAttribute('aria-expanded')).toBe('false')
    await userEvent.click(toggle)
    expect(toggle.getAttribute('aria-expanded')).toBe('true')
    // Still on the Unit: the header is untouched.
    expect(screen.getByRole('heading', { level: 1 }).textContent).toBe('الماظة 1')
  })
})
