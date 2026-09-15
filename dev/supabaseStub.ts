/**
 * DEV-ONLY Supabase stub for the visual harness. NOT part of any build.
 *
 * Aliased in place of `@/lib/supabase/client` by vite.preview.config.ts, so the
 * harness drives the REAL hooks, the REAL queries and the REAL screens - only
 * the transport is replaced. That means what a browser renders here is the
 * actual component tree and the actual state machine, including the filtered
 * -empty and error branches that are otherwise unreachable without a database.
 *
 * The fixtures exercise exactly what is easy to get wrong: Arabic names, a
 * very long name, a mixed Arabic/Latin/numeric name, a station with many
 * units, a station with none, NULL metadata, and a station flagged for review.
 * They are display fixtures. Nothing here is production data, nothing is ever
 * written anywhere, and the production bundle is verified to exclude this file.
 *
 * `?scenario=` on the harness URL picks the branch to inspect:
 *   (default)  populated
 *   empty      no records at all
 *   error      the database refused
 *   scoped     one region only, to eyeball a narrowed RLS scope
 */

const params = new URLSearchParams(window.location.search)
const scenario = params.get('scenario') ?? 'populated'

const REGIONS = [
  { region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 42, units: 61, assets: 1180, overdue: 47, approaching_due: 133, unresolved_mapping: 612 },
  { region_id: 'r-west', region_code: 'west', region_name: 'West', sort_order: 2, stations: 40, units: 58, assets: 964, overdue: 31, approaching_due: 98, unresolved_mapping: 444 },
  { region_id: 'r-canal', region_code: 'canal', region_name: 'Canal', sort_order: 3, stations: 18, units: 0, assets: 233, overdue: 9, approaching_due: 22, unresolved_mapping: 233 },
  { region_id: 'r-delta', region_code: 'delta', region_name: 'Delta', sort_order: 4, stations: 75, units: 69, assets: 1402, overdue: 58, approaching_due: 171, unresolved_mapping: 690 },
  { region_id: 'r-alex', region_code: 'alex', region_name: 'Alex', sort_order: 5, stations: 11, units: 0, assets: 96, overdue: 0, approaching_due: 7, unresolved_mapping: 96 },
  { region_id: 'r-upper', region_code: 'upper', region_name: 'Upper', sort_order: 6, stations: 24, units: 0, assets: 318, overdue: 14, approaching_due: 41, unresolved_mapping: 318 },
]

function mkStation(i: number, over: Record<string, unknown> = {}) {
  const names = [
    'الماظة',
    'شبرا 1',
    'ابنوب اسيوط',
    'Shobra El Kheima Filling Station 3',
    'الخمائل 2',
    'ابو تيج- اسيوط',
    'طريق مصر إسكندرية الصحراوي - كيلو 62',
    'Alex Depot 7',
  ]
  const name = names[i % names.length]
  return {
    station_id: `s-${i}`,
    station_name: i < names.length ? name : `${name} ${i}`,
    normalized_name: null,
    region_id: REGIONS[i % REGIONS.length].region_id,
    region_code: REGIONS[i % REGIONS.length].region_code,
    region_name: REGIONS[i % REGIONS.length].region_name,
    region_sort_order: REGIONS[i % REGIONS.length].sort_order,
    // Deliberately mixed: some NULL, so the "not recorded" treatment shows.
    bay_status: i % 3 === 0 ? null : i % 3 === 1 ? 'Operating' : 'Under maintenance',
    bay_status_raw: i % 3 === 2 ? 'تحت الصيانة' : null,
    notes: i % 5 === 0 ? null : 'Source workbook row retained for traceability.',
    needs_review: i % 7 === 0,
    review_reason: i % 7 === 0 ? 'Station name did not match a known alias.' : null,
    units: i % 4 === 0 ? 0 : (i % 4) + 1,
    assets: 40 + i * 7,
    overdue: i % 5 === 0 ? 0 : i % 11,
    approaching_due: i % 3,
    unresolved_mapping: i % 6 === 0 ? 0 : i * 3,
    ...over,
  }
}

const STATIONS = Array.from({ length: 137 }, (_, i) =>
  // s-0 is the station the detail view opens, so its unit count must agree
  // with the two units below - an inconsistent fixture reads as a bug.
  mkStation(i, i === 0 ? { units: 2, bay_status: null, needs_review: true } : {}),
)

const UNITS = [
  { unit_id: 'u-1', unit_name: 'الماظة 1', normalized_name: null, station_id: 's-0', station_name: 'الماظة', region_id: 'r-east', region_code: 'east', region_name: 'East', job_number: '0042-A', job_number_raw: '0042-A', dispenser_count_reported: 4, hose_count_reported: 8, storage_count_reported: 3, notes: null, needs_review: false, compressors: 2, dispensers: 2, storage_vessels: 4, recovery_tanks: 1, gas_detectors: 2, hoses: 2, installed_srvs: 3, overdue: 2 },
  { unit_id: 'u-2', unit_name: 'الماظة 2', normalized_name: null, station_id: 's-0', station_name: 'الماظة', region_id: 'r-east', region_code: 'east', region_name: 'East', job_number: null, job_number_raw: null, dispenser_count_reported: null, hose_count_reported: null, storage_count_reported: null, notes: null, needs_review: false, compressors: 1, dispensers: 2, storage_vessels: 2, recovery_tanks: 1, gas_detectors: 1, hoses: 4, installed_srvs: 6, overdue: 0 },
]


/* ------------------------------------------------------------------ *
 * Prompt 10 — Unit workspace equipment fixtures.
 *
 * Chosen to exercise what is easy to get wrong: NULL serials, a
 * `not_yet_assigned` serial (a fact, not a gap), a year-only date that must
 * never become a countdown, an Arabic description, a very long part number,
 * every due bucket, a resolved SRV with a real equipment parent, and a
 * `needs_equipment_mapping` SRV whose parent is genuinely unknown.
 * ------------------------------------------------------------------ */

const COMPRESSORS = [
  { id: 'c-1', unit_id: 'u-1', station_id: 's-0', mapping_status: 'resolved', needs_review: false, notes: null, source_status_raw: null, manufacturer: 'Ariel', manufacturer_raw: 'ARIEL', model: 'JGJ/4', model_raw: 'JGJ/4', job_number: '0042-A', serial_number: 'F-19822', serial_number_raw: 'F-19822', serial_status: 'assigned', part_number: null, total_running_hours: 41207.5, average_hours_per_day: 18.2, average_gas_sales_per_day: 9400, average_gas_sales_raw: '9400' },
  { id: 'c-2', unit_id: 'u-1', station_id: 's-0', mapping_status: 'resolved', needs_review: true, notes: 'Second compressor on the same Unit.', source_status_raw: null, manufacturer: null, manufacturer_raw: null, model: null, model_raw: null, job_number: null, serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned', part_number: null, total_running_hours: null, average_hours_per_day: null, average_gas_sales_per_day: null, average_gas_sales_raw: null },
]

const DISPENSERS = [
  { id: 'd-1', unit_id: 'u-1', station_id: 's-0', mapping_status: 'resolved', needs_review: false, notes: null, source_status_raw: null, dispenser_name: 'Dispenser 1', manufacturer: 'Kraus', model: 'CNG-2H', serial_number: '0012845', serial_number_raw: '0012845', serial_status: 'assigned', number_of_hoses: 2, number_of_hoses_raw: '2' },
  { id: 'd-2', unit_id: 'u-1', station_id: 's-0', mapping_status: 'resolved', needs_review: false, notes: null, source_status_raw: null, dispenser_name: 'موزع 2', manufacturer: null, model: null, serial_number: null, serial_number_raw: null, serial_status: 'unknown', number_of_hoses: null, number_of_hoses_raw: null },
]

function vessel(i, kind, over = {}) {
  return {
    asset_type: kind, id: `${kind}-${i}`, unit_id: 'u-1', station_id: 's-0',
    mapping_status: 'resolved', needs_mapping: false,
    manufacturer: i % 2 ? 'CIMC' : null, model: i % 2 ? 'CNG-80' : null,
    serial_number: i % 3 === 0 ? null : `SV-${String(i).padStart(5, '0')}`,
    serial_number_raw: i % 3 === 0 ? null : `SV-${String(i).padStart(5, '0')}`,
    serial_status: i % 3 === 0 ? 'unknown' : 'assigned',
    compressor_type_raw: null,
    last_inspection_date: '2024-03-11', last_inspection_precision: 'exact_date', last_inspection_display: '11 Mar 2024',
    next_inspection_date: '2026-10-02', next_inspection_precision: 'exact_date', next_inspection_display: '2 Oct 2026',
    days_left: 17, due_status: 'due_30',
    source_status_raw: null, needs_review: false, notes: null, ...over,
  }
}

const VESSELS = [
  vessel(1, 'storage_vessel', { due_status: 'overdue', days_left: -42, next_inspection_display: '4 Aug 2026' }),
  vessel(2, 'storage_vessel'),
  // A year-only next date: no countdown, and never "within date".
  vessel(3, 'storage_vessel', {
    next_inspection_date: null, next_inspection_precision: 'year_only', next_inspection_display: '2027',
    days_left: null, due_status: 'unknown',
  }),
  // No date at all, but the source said "expired" in the date column.
  vessel(4, 'storage_vessel', {
    next_inspection_date: null, next_inspection_precision: 'unknown', next_inspection_display: null,
    days_left: null, due_status: 'unknown', source_status_raw: 'منتهية',
  }),
  vessel(5, 'recovery_tank', { due_status: 'valid', days_left: 240, next_inspection_display: '12 May 2027' }),
]

const DETECTORS = [
  { detector_id: 'g-1', detector_presence: 'installed', unit_id: 'u-1', station_id: 's-0', area_type: 'closed', area_type_raw: 'مغلق', mapping_status: 'resolved', needs_mapping: false, manufacturer: 'Honeywell', model: 'XNX', serial_number: 'GD-77410', serial_number_raw: 'GD-77410', serial_status: 'assigned', last_calibration_date: '2026-06-01', last_calibration_precision: 'exact_date', last_calibration_display: '1 Jun 2026', next_calibration_date: '2026-09-17', next_calibration_precision: 'exact_date', next_calibration_display: '17 Sep 2026', days_left: 2, due_status: 'due_7', source_status_raw: null, needs_review: false, notes: null },
  { detector_id: 'g-2', detector_presence: 'unknown', unit_id: 'u-1', station_id: 's-0', area_type: null, area_type_raw: null, mapping_status: 'resolved', needs_mapping: false, manufacturer: null, model: null, serial_number: null, serial_number_raw: null, serial_status: 'unknown', last_calibration_date: null, last_calibration_precision: 'unknown', last_calibration_display: null, next_calibration_date: null, next_calibration_precision: 'unknown', next_calibration_display: null, days_left: null, due_status: 'unknown', source_status_raw: null, needs_review: false, notes: null },
]

const HOSES = [
  { id: 'h-1', unit_id: 'u-1', station_id: 's-0', dispenser_id: 'd-1', dispenser_name: 'Dispenser 1', mapping_status: 'resolved', needs_mapping: false, description: 'خرطوم تعبئة عالي الضغط', serial_number: 'HS-2024-000813', serial_number_raw: 'HS-2024-000813', serial_status: 'assigned', working_pressure_raw: '250', working_pressure_value: 250, working_pressure_unit: 'BAR', test_pressure_raw: '375', test_pressure_value: 375, test_pressure_unit: 'BAR', last_test_date: '2026-02-20', last_test_precision: 'exact_date', last_test_display: '20 Feb 2026', next_test_date: '2026-09-15', next_test_precision: 'exact_date', next_test_display: '15 Sep 2026', days_left: 0, due_status: 'due_today', source_status_raw: null, needs_review: false, notes: null },
  { id: 'h-2', unit_id: 'u-1', station_id: 's-0', dispenser_id: null, dispenser_name: null, mapping_status: 'resolved', needs_mapping: false, description: null, serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned', working_pressure_raw: null, working_pressure_value: null, working_pressure_unit: null, test_pressure_raw: null, test_pressure_value: null, test_pressure_unit: null, last_test_date: null, last_test_precision: 'unknown', last_test_display: null, next_test_date: null, next_test_precision: 'unknown', next_test_display: null, days_left: null, due_status: 'unknown', source_status_raw: null, needs_review: false, notes: null },
]

const UNIT_SRVS = [
  // Resolved: a real equipment parent, named.
  { id: 'v-1', unit_id: 'u-1', station_id: 's-0', mapping_status: 'resolved', mapping_label: 'Resolved', needs_mapping: false, expected_parent_kind: 'compressor', location_raw: 'Stage', parent_kind: 'compressor', parent_id: 'c-1', parent_label: 'F-19822', tag_number: 'PSV-101', serial_number: 'RV-880124', serial_number_raw: 'RV-880124', serial_status: 'assigned', part_number: null, manufacturer: 'Leser', size_type: 'Flanged', inlet_size: '1"', outlet_size: '2"', set_pressure_raw: '250-260', pressure_min: 250, pressure_max: 260, pressure_unit: 'BAR', last_calibration_date: '2026-01-14', last_calibration_precision: 'exact_date', last_calibration_display: '14 Jan 2026', next_calibration_date: '2026-09-10', next_calibration_precision: 'exact_date', next_calibration_display: '10 Sep 2026', days_left: -5, due_status: 'overdue', source_status_raw: null, needs_review: false, notes: null },
  // The owner-confirmed part number. NOT a serial: serial stays NULL.
  { id: 'v-2', unit_id: 'u-1', station_id: 's-0', mapping_status: 'needs_equipment_mapping', mapping_label: 'Needs Equipment Mapping', needs_mapping: true, expected_parent_kind: 'storage_vessel', location_raw: 'Storage', parent_kind: null, parent_id: null, parent_label: null, tag_number: null, serial_number: null, serial_number_raw: 'SS-4R3A', serial_status: 'unknown', part_number: 'SS-4R3A', manufacturer: 'Swagelok', size_type: null, inlet_size: '1/4"', outlet_size: '1/4"', set_pressure_raw: '206', pressure_min: 206, pressure_max: 206, pressure_unit: 'BAR', last_calibration_date: null, last_calibration_precision: 'unknown', last_calibration_display: null, next_calibration_date: null, next_calibration_precision: 'year_only', next_calibration_display: '2027', days_left: null, due_status: 'unknown', source_status_raw: null, needs_review: true, notes: null },
  { id: 'v-3', unit_id: 'u-1', station_id: 's-0', mapping_status: 'needs_equipment_mapping', mapping_label: 'Needs Equipment Mapping', needs_mapping: true, expected_parent_kind: 'compressor', location_raw: 'Stage', parent_kind: null, parent_id: null, parent_label: null, tag_number: 'PSV-204', serial_number: 'RV-CNG-2019-00004417-A', serial_number_raw: 'RV-CNG-2019-00004417-A', serial_status: 'assigned', part_number: null, manufacturer: null, size_type: null, inlet_size: null, outlet_size: null, set_pressure_raw: null, pressure_min: null, pressure_max: null, pressure_unit: null, last_calibration_date: '2026-05-05', last_calibration_precision: 'exact_date', last_calibration_display: '5 May 2026', next_calibration_date: '2026-11-20', next_calibration_precision: 'exact_date', next_calibration_display: '20 Nov 2026', days_left: 66, due_status: 'valid', source_status_raw: null, needs_review: false, notes: null },
]

type Reply = { data: unknown; error: { message: string } | null; count?: number }

const FAILURE = { message: 'permission denied for view v_station_summary' }

const EQUIPMENT_TABLES = new Set([
  'compressors', 'dispensers', 'v_vessel_management',
  'v_gas_detector_management', 'v_hose_management', 'v_unit_srvs',
])

/** A chainable stand-in for the PostgREST builder, resolving from fixtures. */
function builder(table: string) {
  let head = false
  const filters: { region?: string; overdue?: boolean; unresolved?: boolean; search?: string; stationId?: string; unitId?: string; assetType?: string } = {}
  // PostgREST applies .order() calls IN SEQUENCE - the first is the primary
  // key, later ones are tie-breaks. An earlier version of this stub overwrote
  // a single column instead, so a sort by Assets silently became a sort by
  // name and looked like an application bug. Accumulate them.
  const orders: { col: string; asc: boolean }[] = []
  let from = 0
  let to = 49

  function rows() {
    if (scenario === 'empty') return []
    let list = STATIONS.slice()
    if (scenario === 'scoped') list = list.filter((s) => s.region_id === 'r-east')
    if (filters.region) list = list.filter((s) => s.region_id === filters.region)
    if (filters.overdue) list = list.filter((s) => s.overdue > 0)
    if (filters.unresolved) list = list.filter((s) => s.unresolved_mapping > 0)
    if (filters.search) {
      const q = filters.search.toLowerCase()
      list = list.filter((s) => s.station_name.toLowerCase().includes(q))
    }
    list.sort((a, b) => {
      for (const { col, asc } of orders) {
        const x = a[col as keyof typeof a] as string | number
        const y = b[col as keyof typeof b] as string | number
        const cmp =
          typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), 'ar')
        if (cmp !== 0) return asc ? cmp : -cmp
      }
      return 0
    })
    return list
  }

  function settle(): Reply {
    if (scenario === 'error') return { data: null, error: FAILURE, count: 0 }
    if (table === 'v_dashboard_region_summary') {
      return { data: scenario === 'empty' ? [] : scenario === 'scoped' ? REGIONS.slice(0, 1) : REGIONS, error: null }
    }
    if (table === 'v_unit_summary') {
      if (scenario === 'empty') return { data: [], error: null }
      let list = UNITS.filter((u) => (filters.stationId ? u.station_id === filters.stationId : true))
      // Keep the scenario coherent: if every tab is empty, the counts in the
      // tab strip must say so too, or the fixture reads as a bug.
      if (scenario === 'emptytab') {
        list = list.map((u) => ({
          ...u, compressors: 0, dispensers: 0, storage_vessels: 0, recovery_tanks: 0,
          gas_detectors: 0, hoses: 0, installed_srvs: 0,
        }))
      }
      return { data: list, error: null }
    }
    // Unit workspace equipment. `emptytab` proves an empty tab is distinct
    // from a failed one; `error` proves a failure never renders as empty.
    if (EQUIPMENT_TABLES.has(table)) {
      if (scenario === 'emptytab') return { data: [], error: null }
      let list: Record<string, unknown>[] =
        table === 'compressors' ? COMPRESSORS
        : table === 'dispensers' ? DISPENSERS
        : table === 'v_vessel_management' ? VESSELS
        : table === 'v_gas_detector_management' ? DETECTORS
        : table === 'v_hose_management' ? HOSES
        : UNIT_SRVS
      if (filters.unitId) list = list.filter((r) => r.unit_id === filters.unitId)
      if (filters.assetType) list = list.filter((r) => r.asset_type === filters.assetType)
      return { data: list, error: null }
    }
    const list = rows()
    if (head) return { data: null, error: null, count: scenario === 'empty' ? 0 : STATIONS.length }
    return { data: list.slice(from, to + 1), error: null, count: list.length }
  }

  const chain: Record<string, unknown> = {
    select: (_cols?: string, opts?: { head?: boolean }) => {
      head = Boolean(opts?.head)
      return chain
    },
    eq: (col: string, value: string) => {
      if (col === 'region_id') filters.region = value
      if (col === 'station_id') filters.stationId = value
      if (col === 'unit_id') filters.unitId = value
      if (col === 'asset_type') filters.assetType = value
      return chain
    },
    gt: (col: string) => {
      if (col === 'overdue') filters.overdue = true
      if (col === 'unresolved_mapping') filters.unresolved = true
      return chain
    },
    or: (expr: string) => {
      const m = /station_name\.ilike\.\*(.*?)\*/.exec(expr)
      filters.search = m ? m[1] : ''
      return chain
    },
    order: (col: string, opts?: { ascending?: boolean }) => {
      orders.push({ col, asc: opts?.ascending !== false })
      return chain
    },
    range: (a: number, b: number) => {
      from = a
      to = b
      return Promise.resolve(settle())
    },
    maybeSingle: () => {
      if (scenario === 'error') return Promise.resolve({ data: null, error: FAILURE })
      if (table === 'v_unit_summary') {
        return Promise.resolve({ data: UNITS.find((u) => u.unit_id === filters.unitId) ?? null, error: null })
      }
      return Promise.resolve({ data: STATIONS.find((s) => s.station_id === filters.stationId) ?? null, error: null })
    },
    then: (resolve: (v: unknown) => unknown) => Promise.resolve(settle()).then(resolve),
  }
  return chain
}

const stubClient = { from: (table: string) => builder(table) }

export function useSupabaseClient() {
  return stubClient as never
}

export function setSupabaseSession() {
  /* no-op in the harness */
}
