import { useCallback, useEffect, useState } from 'react'
import type { SupabaseClient } from '@supabase/supabase-js'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { RegistryPage } from '@/components/data/RegistryTable'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus, PressureUnit } from '@/features/units/useUnitWorkspace'
import { applyDateRange, EMPTY_DATE_RANGE, hasDateRange, type DateOption, type DateRange } from '@/components/data/dateRange'

/**
 * Global SRV Management data: installed valves and warehouse stock.
 *
 * TWO DATASETS, NEVER MERGED. Installed valves live in the physical hierarchy;
 * warehouse stock is inventory with no Station, Unit or equipment parent. They
 * are queried separately, paged separately and never unioned - two valves that
 * happen to share a part number are still two different things.
 *
 * AUTHORIZATION IS THE DATABASE'S. Both reads go through `security_invoker`
 * views over RLS-protected tables, so:
 *
 *   - a Region-scoped user sees only their Regions' installed valves;
 *   - `needs_station_mapping` rows (station_id IS NULL) are gated by
 *     `cng_can_access_unmapped_srv()`, which is admin/manager only - an
 *     unconfirmed station name is evidence, never permission (CLAUDE.md §10);
 *   - the `count: 'exact'` behind pagination runs under the same RLS, so a
 *     total can never reveal the size of a Region the caller cannot read.
 *
 * Nothing here filters by region in JavaScript, and nothing fetches rows in
 * order to count them.
 */

export interface InstalledSrvRow {
  id: string
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  source_station_name_raw: string | null
  station_display: string | null
  needs_station_mapping: boolean
  unit_id: string | null
  unit_name: string | null
  mapping_status: 'resolved' | 'needs_equipment_mapping' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'
  needs_mapping: boolean
  mapping_label: string | null
  expected_parent_kind: 'compressor' | 'storage_vessel' | 'dispenser' | null
  location_raw: string | null
  parent_kind: 'compressor' | 'storage_vessel' | 'dispenser' | null
  parent_id: string | null
  parent_label: string | null
  tag_number: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  part_number: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  last_calibration_date: string | null
  last_calibration_precision: DatePrecision | null
  last_calibration_display: string | null
  next_calibration_date: string | null
  next_calibration_precision: DatePrecision | null
  next_calibration_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
  source_file: string | null
  source_sheet: string | null
  source_row: number | null
  /** Recorded code, else the code of the single warehouse record with the same serial. */
  warehouse_code: string | null
  warehouse_code_source: 'recorded' | 'serial_match' | null
}

export interface WarehouseSrvRow {
  id: string
  availability_status: string | null
  warehouse_code: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  part_number: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  /** A DESTINATION for stock, not an installed position. Never hierarchy. */
  target_region_id: string | null
  target_region_name: string | null
  target_station_id: string | null
  target_station_name: string | null
  is_unassigned_stock: boolean
  updated_at: string
  warehouse_issue_date: string | null
  last_calibration_date: string | null
  last_calibration_precision: DatePrecision | null
  last_calibration_display: string | null
  next_calibration_date: string | null
  next_calibration_precision: DatePrecision | null
  next_calibration_display: string | null
  days_left: number | null
  due_status: DueStatus
  calibration_location: string | null
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
}

const INSTALLED_COLUMNS =
  'id, region_id, region_name, station_id, station_name, source_station_name_raw, station_display, ' +
  'needs_station_mapping, unit_id, unit_name, mapping_status, needs_mapping, mapping_label, ' +
  'expected_parent_kind, location_raw, parent_kind, parent_id, parent_label, tag_number, serial_number, ' +
  'serial_number_raw, serial_status, part_number, manufacturer, size_type, inlet_size, outlet_size, ' +
  'set_pressure_raw, pressure_min, pressure_max, pressure_unit, last_calibration_date, ' +
  'last_calibration_precision, last_calibration_display, next_calibration_date, ' +
  'next_calibration_precision, next_calibration_display, days_left, due_status, source_status_raw, ' +
  'needs_review, notes, source_file, source_sheet, source_row, warehouse_code, warehouse_code_source'

/** Warehouse availability, as the store names it. Shared by the table and the export. */
export const AVAILABILITY_LABEL: Record<string, string> = {
  available_new: 'Available — new',
  available_calibrated: 'Available — calibrated',
  available_in_store_uc: 'Available — in store (UC)',
  sent_to_station_received: 'Sent to station — received',
  sent_to_station_not_received: 'Sent to station — not received',
}

const WAREHOUSE_COLUMNS =
  'id, availability_status, warehouse_code, serial_number, serial_number_raw, serial_status, part_number, ' +
  'manufacturer, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, ' +
  'pressure_unit, target_region_id, target_region_name, target_station_id, target_station_name, ' +
  'is_unassigned_stock, updated_at, warehouse_issue_date, last_calibration_date, last_calibration_precision, ' +
  'last_calibration_display, next_calibration_date, next_calibration_precision, ' +
  'next_calibration_display, days_left, due_status, calibration_location, source_status_raw, ' +
  'needs_review, notes'

/**
 * Dedicated filters (owner request): each narrows ONE column, independently of the
 * free-text search, and they combine with AND. Set pressure matches valves whose
 * recorded range contains the value (pressure_min <= v <= pressure_max) in the chosen unit.
 * Size is the FULL size as the table shows it (`M 3/4" X 1"`): the M/F prefix narrows the
 * size type, and the parts either side of X narrow inlet and outlet.
 */
export interface SrvSmartFilters extends DateRange {
  /** Free text over the tab's own columns (serial, codes, Station) — the workflow tabs' one search box. */
  search: string
  serial: string
  region: string
  station: string
  size: string
  pressure: string
  pressureUnit: '' | 'BAR' | 'PSI'
  manufacturer: string
}
export const EMPTY_SMART_FILTERS: SrvSmartFilters = {
  search: '', serial: '', region: '', station: '', size: '', pressure: '', pressureUnit: '', manufacturer: '', ...EMPTY_DATE_RANGE,
}

export function hasSmartFilters(f: SrvSmartFilters): boolean {
  return Boolean(f.search.trim() || f.serial.trim() || f.region || f.station.trim() || f.size.trim() || f.pressure.trim() || f.pressureUnit || f.manufacturer
    || hasDateRange(f))
}

/** Splits a full size (`M 3/4" X 1"`) into its type, inlet and outlet parts. Any part may be absent. */
export function parseSize(value: string): { type: 'male' | 'female' | 'flange' | null; inlet: string; outlet: string } {
  let v = value.trim()
  let type: 'male' | 'female' | 'flange' | null = null
  const m = /^(flange|male|female|M|F)(?:\s+|(?=\d)|$)/i.exec(v)
  if (m) {
    const t = m[1].toLowerCase()
    type = t === 'm' || t === 'male' ? 'male' : t === 'f' || t === 'female' ? 'female' : 'flange'
    v = v.slice(m[0].length)
  }
  const [inlet = '', outlet = ''] = v.split(/\s*[xX×]\s*/)
  return { type, inlet: inlet.trim(), outlet: outlet.trim() }
}

/**
 * Set pressure filter: one value ("30") or a range ("30-35"). A valve matches when its recorded range overlaps
 * lo..hi, in the unit chosen beside it. Anything unreadable filters nothing rather than guessing.
 */
export function parsePressure(value: string): { lo: number; hi: number } | null {
  const m = /^\s*(\d+(?:\.\d+)?)\s*(?:[-–]\s*(\d+(?:\.\d+)?))?\s*$/.exec(value)
  if (!m) return null
  const a = Number(m[1]), b = m[2] === undefined ? a : Number(m[2])
  return { lo: Math.min(a, b), hi: Math.max(a, b) }
}

/** Applies the dedicated filters to a PostgREST builder. Station and Region columns differ per dataset. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function applySmartFilters<B extends { ilike: any; lte: any; gte: any; lt: any; eq: any }>(
  b: B, f: SrvSmartFilters, stationColumn: string, regionColumn = 'region_id', date?: DateOption,
): B {
  const clean = (v: string) => v.trim().replace(/[%*,()]/g, ' ').trim()
  if (clean(f.serial)) b = b.ilike('serial_number', `%${clean(f.serial)}%`)
  if (f.region) b = b.eq(regionColumn, f.region)
  if (clean(f.station)) b = b.ilike(stationColumn, `%${clean(f.station)}%`)
  if (f.size.trim()) {
    const size = parseSize(f.size)
    if (size.type) b = b.ilike('size_type', size.type)
    if (clean(size.inlet)) b = b.ilike('inlet_size', `${clean(size.inlet)}%`)
    if (clean(size.outlet)) b = b.ilike('outlet_size', `${clean(size.outlet)}%`)
  }
  const range = parsePressure(f.pressure)
  if (range) b = b.lte('pressure_min', range.hi).gte('pressure_max', range.lo)
  if (f.manufacturer) b = b.ilike('manufacturer', clean(f.manufacturer))
  if (f.pressureUnit) b = b.eq('pressure_unit', f.pressureUnit)
  return applyDateRange(b, f, date)
}

/** The date each SRV registry is filtered by (one per tab, owner request 2026-09-29). */
export const INSTALLED_DATE: DateOption = { column: 'next_calibration_date', label: 'Next calibration', precision: 'next_calibration_precision' }
export const WAREHOUSE_DATE: DateOption = INSTALLED_DATE

export type MappingFilter = 'all' | 'resolved' | 'needs_equipment_mapping' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'
/** 'attention' is overdue OR any due bucket — stated, never left ambiguous. */
export type DueFilter = 'all' | 'overdue' | 'attention' | 'unknown'
export type InstalledSort = 'region' | 'next_due' | 'last_calibration' | 'station' | 'unit' | 'serial' | 'mapping'
  | 'pressure' | 'manufacturer' | 'size' | 'due'

export interface InstalledQuery {
  search: string
  regionId: string | null
  mapping: MappingFilter
  due: DueFilter
  parentKind: 'all' | 'compressor' | 'storage_vessel' | 'dispenser'
  filters: SrvSmartFilters
  sort: InstalledSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_INSTALLED_QUERY: InstalledQuery = {
  search: '', regionId: null, mapping: 'all', due: 'all', parentKind: 'all', filters: EMPTY_SMART_FILTERS,
  sort: 'region', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns, each with an explicit tie-break so paging is
 * stable. The FIRST column is the primary sort; later ones only break ties —
 * PostgREST applies `.order()` calls in sequence, and a Prompt-9 bug in the dev
 * stub (not the app) came from forgetting that.
 */
const INSTALLED_SORT: Record<InstalledSort, string[]> = {
  // Owner default: Region, then Station, then set pressure smallest first (BAR and PSI on one scale).
  region: ['region_name', 'station_name', 'pressure_sort_bar', 'id'],
  pressure: ['pressure_sort_bar', 'id'],
  manufacturer: ['manufacturer', 'id'],
  size: ['size_type', 'inlet_size', 'outlet_size', 'id'],
  due: ['due_status', 'next_calibration_date', 'id'],
  next_due: ['next_calibration_date', 'id'],
  last_calibration: ['last_calibration_date', 'id'],
  station: ['station_name', 'unit_name', 'id'],
  unit: ['unit_name', 'id'],
  serial: ['serial_number', 'id'],
  mapping: ['mapping_status', 'id'],
}

/** Buckets that mean "needs attention within 60 days OR already overdue". */
const ATTENTION_BUCKETS = ['overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60']

/** The shared registry page shape. Re-exported so callers here keep one import. */
export type SrvPage<T> = RegistryPage<T>

/**
 * The Installed SRV registry query: every filter and the sort, no paging. The table pages it and the export
 * reads it whole, so an export can never widen (or narrow) what the screen shows.
 */
export function installedRequest(supabase: SupabaseClient, q: InstalledQuery) {
  const term = q.search.trim()
  let b = supabase.from('v_installed_srv_management').select(INSTALLED_COLUMNS, { count: 'exact' })
  if (q.regionId) b = b.eq('region_id', q.regionId)
  if (q.mapping !== 'all') b = b.eq('mapping_status', q.mapping)
  if (q.parentKind !== 'all') b = b.eq('parent_kind', q.parentKind)
  if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
  if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
  if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
  b = applySmartFilters(b, q.filters, 'station_display', 'region_id', INSTALLED_DATE)
  if (term) {
    // Retrieval, never resolution: matching a station name here does not
    // map anything. The folded form is offered too so an Arabic query
    // typed with one spelling finds the other.
    const raw = term.replace(/[,()]/g, ' ')
    const folded = foldName(raw)
    b = b.or(
      [
        `serial_number.ilike.*${raw}*`,
        `part_number.ilike.*${raw}*`,
        `manufacturer.ilike.*${raw}*`,
        `tag_number.ilike.*${raw}*`,
        `station_name.ilike.*${raw}*`,
        `unit_name.ilike.*${raw}*`,
        `source_station_name_raw.ilike.*${folded}*`,
      ].join(','),
    )
  }
  for (const column of INSTALLED_SORT[q.sort]) {
    b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
  }
  return b
}

export function useInstalledSrvs(query: InstalledQuery): {
  state: Loadable<SrvPage<InstalledSrvRow>>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<SrvPage<InstalledSrvRow>>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  const key = JSON.stringify(query)

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })
      const q: InstalledQuery = JSON.parse(key)
      const term = q.search.trim()

      const from = q.page * q.pageSize
      const { data, error, count } = await installedRequest(supabase, q).range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as InstalledSrvRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(term || q.regionId || q.mapping !== 'all' || q.due !== 'all' || q.parentKind !== 'all' || hasSmartFilters(q.filters))
      if (total === 0 && hasFilters) {
        const { count: unfiltered } = await supabase!
          .from('v_installed_srv_management')
          .select('id', { count: 'exact', head: true })
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

export type WarehouseSort = 'next_due' | 'serial' | 'part_number' | 'manufacturer' | 'availability'
  | 'pressure' | 'size' | 'warehouse_code' | 'last_calibration' | 'target'

export interface WarehouseQuery {
  search: string
  availability: string | null
  due: DueFilter
  filters: SrvSmartFilters
  sort: WarehouseSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_WAREHOUSE_QUERY: WarehouseQuery = {
  search: '', availability: null, due: 'all', filters: EMPTY_SMART_FILTERS, sort: 'pressure', direction: 'asc', page: 0, pageSize: 50,
}

const WAREHOUSE_SORT: Record<WarehouseSort, string[]> = {
  // Owner default (2026-09-29): set pressure smallest first; within it each size together, smallest first; within
  // one pressure and size calibrated first (oldest calibration first), then new, then under calibration.
  pressure: ['pressure_sort_bar', 'inlet_sort_in', 'outlet_sort_in', 'inlet_size', 'outlet_size', 'size_type',
    'availability_rank', 'last_calibration_date', 'warehouse_code', 'id'],
  size: ['inlet_sort_in', 'outlet_sort_in', 'size_type', 'inlet_size', 'outlet_size', 'id'],
  warehouse_code: ['warehouse_code', 'id'],
  last_calibration: ['last_calibration_date', 'id'],
  target: ['target_station_name', 'id'],
  next_due: ['next_calibration_date', 'id'],
  serial: ['serial_number', 'id'],
  part_number: ['part_number', 'id'],
  manufacturer: ['manufacturer', 'id'],
  availability: ['availability_status', 'id'],
}

/**
 * Warehouse stock.
 *
 * Its query model is deliberately INDEPENDENT of the installed hierarchy: no
 * Region filter is offered, because warehouse stock has no Region. It has a
 * `target_region`/`target_station` — where stock is being sent — and that is a
 * destination, not a physical position (CLAUDE.md §4).
 */
/** The warehouse registry query: every filter and the sort, no paging (shared by the table and its export). */
export function warehouseRequest(supabase: SupabaseClient, q: WarehouseQuery) {
  const term = q.search.trim()
  let b = supabase.from('v_srv_warehouse_stock').select(WAREHOUSE_COLUMNS, { count: 'exact' })
  if (q.availability) b = b.eq('availability_status', q.availability)
  if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
  if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
  if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
  b = applySmartFilters(b, q.filters, 'target_station_name', 'target_region_id', WAREHOUSE_DATE)
  if (term) {
    const raw = term.replace(/[,()]/g, ' ')
    b = b.or(
      [
        `serial_number.ilike.*${raw}*`,
        `part_number.ilike.*${raw}*`,
        `manufacturer.ilike.*${raw}*`,
        `warehouse_code.ilike.*${raw}*`,
        // The destination Station, so the one search box also replaces a separate Station filter.
        `target_station_name.ilike.*${raw}*`,
      ].join(','),
    )
  }
  for (const column of WAREHOUSE_SORT[q.sort]) {
    b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
  }
  return b
}

export function useWarehouseSrvs(query: WarehouseQuery): {
  state: Loadable<SrvPage<WarehouseSrvRow>>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<SrvPage<WarehouseSrvRow>>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  const key = JSON.stringify(query)

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })
      const q: WarehouseQuery = JSON.parse(key)
      const term = q.search.trim()

      const from = q.page * q.pageSize
      const { data, error, count } = await warehouseRequest(supabase, q).range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as WarehouseSrvRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(term || q.availability || q.due !== 'all' || hasSmartFilters(q.filters))
      if (total === 0 && hasFilters) {
        const { count: unfiltered } = await supabase!
          .from('v_srv_warehouse_stock')
          .select('id', { count: 'exact', head: true })
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


export interface InstalledSummary {
  total: number
  overdue: number
  /** Overdue PLUS every due bucket out to 60 days. Deliberately explicit. */
  attention: number
  needs_station_mapping: number
  needs_unit_mapping: number
  needs_equipment_mapping: number
  conflict: number
}

/**
 * The attention and mapping summary.
 *
 * Counted over the WHOLE authorized dataset, not the current page: a strip that
 * said "Needs mapping 0" because page one happened to hold none would be worse
 * than no strip at all.
 *
 * Every figure is a `head: true` count — the server returns a number and no
 * rows, so this costs seven counts and transfers no data. Each runs under the
 * caller's RLS, so the totals are the caller's own and can never reveal the
 * size of a Region they cannot read.
 *
 * The summary describes the dataset, NOT the active filters. It answers "what
 * needs attention overall", which is what an operations lead opens this screen
 * for; the table answers "what matches my filters".
 */
export function useInstalledSummary(query?: InstalledQuery): { state: Loadable<InstalledSummary>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<InstalledSummary>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  // Only the FILTERS drive the counts; paging and sorting never change them.
  const params = query ? summaryParams(query) : null
  const key = JSON.stringify(params)

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      // ONE round trip, ONE RLS-evaluated scan. This was previously seven
      // parallel count queries, and in production those statements peaked at
      // 7.9s against the `authenticated` role's 8s statement_timeout -- so
      // whichever crossed the line was cancelled and blanked the whole strip
      // (Prompt 25J-B). The counts are identical; only the number of scans
      // changed. Aggregation stays in SQL because tallying rows in the browser
      // could be silently truncated by PostgREST's row limit, and a WRONG count
      // is worse than a stated failure.
      // No filters: the precomputed one-row view. Filters: the same counts over the filtered set, one scan,
      // SECURITY INVOKER (cng_installed_srv_summary_filtered), with the predicates the table itself uses.
      const p = JSON.parse(key) as Record<string, string> | null
      const { data, error } = p && Object.keys(p).length > 0
        ? await supabase.rpc('cng_installed_srv_summary_filtered', { p }).maybeSingle<InstalledSummary>()
        : await supabase
            .from('v_installed_srv_summary')
            .select('total, overdue, attention, needs_station_mapping, needs_unit_mapping, needs_equipment_mapping, conflict')
            .maybeSingle()
      if (cancelled) return

      // A failure is STATED, never rendered as 0.
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }
      if (!data) {
        setState({ status: 'error', message: 'The attention summary returned no row.' })
        return
      }

      setState({
        status: 'ready',
        data: {
          total: data.total ?? 0,
          overdue: data.overdue ?? 0,
          attention: data.attention ?? 0,
          needs_station_mapping: data.needs_station_mapping ?? 0,
          needs_unit_mapping: data.needs_unit_mapping ?? 0,
          needs_equipment_mapping: data.needs_equipment_mapping ?? 0,
          conflict: data.conflict ?? 0,
        },
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce, key])

  return { state, reload }
}

/** The active filters as the summary function's parameters; empty values are left out. */
export function summaryParams(q: InstalledQuery): Record<string, string> {
  const clean = (v: string) => v.trim().replace(/[%*,()]/g, ' ').trim()
  const size = parseSize(q.filters.size)
  const term = q.search.trim().replace(/[,()]/g, ' ')
  const range = parsePressure(q.filters.pressure)
  const all: Record<string, string> = {
    region_id: q.regionId ?? '',
    mapping: q.mapping === 'all' ? '' : q.mapping,
    parent_kind: q.parentKind === 'all' ? '' : q.parentKind,
    due: q.due === 'all' ? '' : q.due,
    serial: clean(q.filters.serial),
    station: clean(q.filters.station),
    size_type: q.filters.size.trim() && size.type ? size.type : '',
    inlet: q.filters.size.trim() ? clean(size.inlet) : '',
    outlet: q.filters.size.trim() ? clean(size.outlet) : '',
    pressure_lo: range ? String(range.lo) : '',
    pressure_hi: range ? String(range.hi) : '',
    manufacturer: q.filters.manufacturer,
    pressure_unit: q.filters.pressureUnit,
    search: term,
    search_folded: term ? foldName(term) : '',
  }
  return Object.fromEntries(Object.entries(all).filter(([, x]) => x !== ''))
}
