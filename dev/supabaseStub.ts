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
  { unit_id: 'u-1', unit_name: 'الماظة 1', normalized_name: null, station_id: 's-0', station_name: 'الماظة', region_id: 'r-east', region_code: 'east', region_name: 'East', job_number: '0042-A', job_number_raw: '0042-A', dispenser_count_reported: 4, hose_count_reported: 8, storage_count_reported: 3, notes: null, needs_review: false, compressors: 2, dispensers: 4, storage_vessels: 3, recovery_tanks: 1, gas_detectors: 2, hoses: 8, installed_srvs: 11, overdue: 2 },
  { unit_id: 'u-2', unit_name: 'الماظة 2', normalized_name: null, station_id: 's-0', station_name: 'الماظة', region_id: 'r-east', region_code: 'east', region_name: 'East', job_number: null, job_number_raw: null, dispenser_count_reported: null, hose_count_reported: null, storage_count_reported: null, notes: null, needs_review: false, compressors: 1, dispensers: 2, storage_vessels: 2, recovery_tanks: 1, gas_detectors: 1, hoses: 4, installed_srvs: 6, overdue: 0 },
]

type Reply = { data: unknown; error: { message: string } | null; count?: number }

const FAILURE = { message: 'permission denied for view v_station_summary' }

/** A chainable stand-in for the PostgREST builder, resolving from fixtures. */
function builder(table: string) {
  let head = false
  const filters: { region?: string; overdue?: boolean; unresolved?: boolean; search?: string; stationId?: string; unitId?: string } = {}
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
      const list = UNITS.filter((u) => (filters.stationId ? u.station_id === filters.stationId : true))
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
