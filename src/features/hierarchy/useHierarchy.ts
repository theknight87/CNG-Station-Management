import { useCallback, useEffect, useMemo, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { foldName } from './foldName'

/**
 * Hierarchy browsing data: Regions, Stations, and the Units inside a Station.
 *
 * Two rules this file exists to enforce.
 *
 * 1. **A database error is never an empty result.** Every hook returns a
 *    discriminated union in which `error` and `ready` cannot be confused. A
 *    Stations list that renders "no stations" because the query failed is a
 *    worse lie than one that renders nothing.
 *
 * 2. **Region scope is enforced in PostgreSQL, never here.** Every read goes
 *    through `v_station_summary` / `v_unit_summary`, which are
 *    `security_invoker` views over RLS-protected tables. A station outside the
 *    caller's regions produces NO ROW — so it is absent from the list, absent
 *    from search results, and absent from the `count` that drives pagination.
 *    Nothing in this file filters by region in JavaScript, because a filter in
 *    JavaScript is decoration, not a boundary.
 *
 * Filtering, sorting and paging are all done SERVER-SIDE. With ~300 stations
 * and thousands of assets, fetching everything to sort it in the browser would
 * both be slow and put the region boundary in the wrong place.
 */

const STATION_COLUMNS =
  'station_id, station_name, normalized_name, region_id, region_code, region_name, region_sort_order, ' +
  'bay_status, bay_status_raw, notes, needs_review, review_reason, units, assets, overdue, ' +
  'approaching_due, unresolved_mapping'

const UNIT_COLUMNS =
  'unit_id, unit_name, normalized_name, station_id, station_name, region_id, region_code, region_name, ' +
  'job_number, job_number_raw, dispenser_count_reported, hose_count_reported, storage_count_reported, ' +
  'notes, needs_review, compressors, dispensers, storage_vessels, recovery_tanks, gas_detectors, ' +
  'hoses, installed_srvs, overdue'

export interface StationSummary {
  station_id: string
  station_name: string
  normalized_name: string | null
  region_id: string
  region_code: string
  region_name: string
  region_sort_order: number
  bay_status: string | null
  bay_status_raw: string | null
  notes: string | null
  needs_review: boolean
  review_reason: string | null
  units: number
  assets: number
  overdue: number
  approaching_due: number
  unresolved_mapping: number
}

export interface UnitSummary {
  unit_id: string
  unit_name: string
  normalized_name: string | null
  station_id: string
  station_name: string
  region_id: string
  region_code: string
  region_name: string
  job_number: string | null
  job_number_raw: string | null
  dispenser_count_reported: number | null
  hose_count_reported: number | null
  storage_count_reported: number | null
  notes: string | null
  needs_review: boolean
  compressors: number
  dispensers: number
  storage_vessels: number
  recovery_tanks: number
  gas_detectors: number
  hoses: number
  installed_srvs: number
  overdue: number
}

export interface RegionSummary {
  region_id: string
  region_code: string
  region_name: string
  sort_order: number
  stations: number
  units: number
  assets: number
  overdue: number
  approaching_due: number
  unresolved_mapping: number
}

/** `unconfigured` is its own state: no Supabase URL is not a failed query. */
export type Loadable<T> =
  | { status: 'loading' }
  | { status: 'unconfigured' }
  | { status: 'error'; message: string }
  | { status: 'ready'; data: T }

export type StationSort =
  | 'name'
  | 'region'
  | 'units'
  | 'assets'
  | 'overdue'
  | 'approaching_due'
  | 'unresolved_mapping'

export interface StationQuery {
  search: string
  regionId: string | null
  /** 'attention' keeps only stations with something overdue or unresolved. */
  attention: 'all' | 'overdue' | 'unresolved'
  sort: StationSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_STATION_QUERY: StationQuery = {
  search: '',
  regionId: null,
  attention: 'all',
  sort: 'name',
  direction: 'asc',
  page: 0,
  pageSize: 50,
}

/** Maps a sort key to real columns. Ties break on name so paging is stable. */
const SORT_COLUMNS: Record<StationSort, string[]> = {
  name: ['station_name'],
  region: ['region_sort_order', 'station_name'],
  units: ['units', 'station_name'],
  assets: ['assets', 'station_name'],
  overdue: ['overdue', 'station_name'],
  approaching_due: ['approaching_due', 'station_name'],
  unresolved_mapping: ['unresolved_mapping', 'station_name'],
}

export interface StationPage {
  rows: StationSummary[]
  /** Total matching rows THE CALLER MAY SEE — RLS applies to the count too. */
  total: number
  /** True when the caller has stations, but none match the current filters. */
  filtered: boolean
}

export function useRegions(): { state: Loadable<RegionSummary[]>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RegionSummary[]>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })
      // Reuses the dashboard's region summary rather than adding a second view
      // that could drift from it — "overdue" must mean one thing everywhere.
      const { data, error } = await supabase
        .from('v_dashboard_region_summary')
        .select(
          'region_id, region_code, region_name, sort_order, stations, units, assets, overdue, approaching_due, unresolved_mapping',
        )
        .order('sort_order')
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as RegionSummary[] })
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  return { state, reload }
}

export function useStations(query: StationQuery): {
  state: Loadable<StationPage>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<StationPage>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  // The query object is rebuilt on every render by the caller; depending on it
  // directly would refetch forever. Depend on its VALUE instead.
  const key = JSON.stringify(query)

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      const q: StationQuery = JSON.parse(key)
      const term = q.search.trim()

      function base() {
        // `count: 'exact'` runs under the same RLS as the rows, so the total a
        // user pages through is their own total and never reveals the size of
        // a region they cannot read.
        let b = supabase!.from('v_station_summary').select(STATION_COLUMNS, { count: 'exact' })
        if (q.regionId) b = b.eq('region_id', q.regionId)
        if (q.attention === 'overdue') b = b.gt('overdue', 0)
        if (q.attention === 'unresolved') b = b.gt('unresolved_mapping', 0)
        if (term) {
          // Match the raw name OR the folded one, so `الماظه` finds `الماظة`
          // and `shobra` finds `Shobra`. PostgREST needs the wildcards inline.
          const raw = term.replace(/[,()]/g, ' ')
          const folded = foldName(raw)
          b = b.or(`station_name.ilike.*${raw}*,normalized_name.ilike.*${folded}*`)
        }
        return b
      }

      let request = base()
      for (const column of SORT_COLUMNS[q.sort]) {
        request = request.order(column, { ascending: q.direction === 'asc' })
      }
      const from = q.page * q.pageSize
      const { data, error, count } = await request.range(from, from + q.pageSize - 1)

      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as StationSummary[]
      const total = count ?? 0

      // "No stations at all" and "no stations match these filters" are
      // different answers and must never be rendered the same way. Only ask
      // the second question when the first could be misleading.
      let filtered = false
      if (total === 0 && (term || q.regionId || q.attention !== 'all')) {
        const { count: unfiltered } = await supabase!
          .from('v_station_summary')
          .select('station_id', { count: 'exact', head: true })
        if (cancelled) return
        filtered = (unfiltered ?? 0) > 0
      }

      setState({ status: 'ready', data: { rows, total, filtered } })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, key, nonce])

  return { state, reload }
}

/** One Station plus the Units it owns. Both must load, or neither is shown. */
export function useStation(stationId: string | undefined): {
  state: Loadable<{ station: StationSummary | null; units: UnitSummary[] }>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<{ station: StationSummary | null; units: UnitSummary[] }>>({
    status: 'loading',
  })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!stationId) {
        if (!cancelled) setState({ status: 'ready', data: { station: null, units: [] } })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      const [station, units] = await Promise.all([
        supabase.from('v_station_summary').select(STATION_COLUMNS).eq('station_id', stationId).maybeSingle(),
        supabase.from('v_unit_summary').select(UNIT_COLUMNS).eq('station_id', stationId).order('unit_name'),
      ])
      if (cancelled) return

      const failure = [station, units].find((r) => r.error)
      if (failure?.error) {
        setState({ status: 'error', message: failure.error.message })
        return
      }
      setState({
        status: 'ready',
        data: {
          // `null` here means "no such station, or not visible to you". The two
          // are deliberately indistinguishable: telling an unauthorized caller
          // that a station exists is the leak (CLAUDE.md §10).
          station: (station.data as unknown as StationSummary | null) ?? null,
          units: (units.data ?? []) as unknown as UnitSummary[],
        },
      })
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, stationId, nonce])

  return { state, reload }
}

export function useUnit(unitId: string | undefined): {
  state: Loadable<UnitSummary | null>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<UnitSummary | null>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!unitId) {
        if (!cancelled) setState({ status: 'ready', data: null })
        return
      }
      if (!cancelled) setState({ status: 'loading' })
      const { data, error } = await supabase
        .from('v_unit_summary')
        .select(UNIT_COLUMNS)
        .eq('unit_id', unitId)
        .maybeSingle()
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data as unknown as UnitSummary | null) ?? null })
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, unitId, nonce])

  return { state, reload }
}

/** Total pages for a result set, never fewer than one. */
export function pageCount(total: number, pageSize: number): number {
  return Math.max(1, Math.ceil(total / pageSize))
}

/** The `x–y of n` label, computed from what the caller can actually see. */
export function useRangeLabel(page: number, pageSize: number, rows: number, total: number): string {
  return useMemo(() => {
    if (total === 0) return '0'
    const first = page * pageSize + 1
    return `${first.toLocaleString()}–${(first + rows - 1).toLocaleString()} of ${total.toLocaleString()}`
  }, [page, pageSize, rows, total])
}
