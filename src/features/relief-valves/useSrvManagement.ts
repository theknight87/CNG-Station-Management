import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { RegistryPage } from '@/components/data/RegistryTable'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus, PressureUnit } from '@/features/units/useUnitWorkspace'

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
  'needs_review, notes, source_file, source_sheet, source_row'

const WAREHOUSE_COLUMNS =
  'id, availability_status, warehouse_code, serial_number, serial_number_raw, serial_status, part_number, ' +
  'manufacturer, size_type, inlet_size, outlet_size, set_pressure_raw, pressure_min, pressure_max, ' +
  'pressure_unit, target_region_id, target_region_name, target_station_id, target_station_name, ' +
  'is_unassigned_stock, warehouse_issue_date, last_calibration_date, last_calibration_precision, ' +
  'last_calibration_display, next_calibration_date, next_calibration_precision, ' +
  'next_calibration_display, days_left, due_status, calibration_location, source_status_raw, ' +
  'needs_review, notes'

export type MappingFilter = 'all' | 'resolved' | 'needs_equipment_mapping' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'
/** 'attention' is overdue OR any due bucket — stated, never left ambiguous. */
export type DueFilter = 'all' | 'overdue' | 'attention' | 'unknown'
export type InstalledSort = 'next_due' | 'last_calibration' | 'station' | 'unit' | 'serial' | 'mapping'

export interface InstalledQuery {
  search: string
  regionId: string | null
  mapping: MappingFilter
  due: DueFilter
  parentKind: 'all' | 'compressor' | 'storage_vessel' | 'dispenser'
  sort: InstalledSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_INSTALLED_QUERY: InstalledQuery = {
  search: '', regionId: null, mapping: 'all', due: 'all', parentKind: 'all',
  sort: 'next_due', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns, each with an explicit tie-break so paging is
 * stable. The FIRST column is the primary sort; later ones only break ties —
 * PostgREST applies `.order()` calls in sequence, and a Prompt-9 bug in the dev
 * stub (not the app) came from forgetting that.
 */
const INSTALLED_SORT: Record<InstalledSort, string[]> = {
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

      function base(head = false) {
        let b = supabase!
          .from('v_installed_srv_management')
          .select(head ? 'id' : INSTALLED_COLUMNS, { count: 'exact', head })
        if (q.regionId) b = b.eq('region_id', q.regionId)
        if (q.mapping !== 'all') b = b.eq('mapping_status', q.mapping)
        if (q.parentKind !== 'all') b = b.eq('parent_kind', q.parentKind)
        if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
        if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
        if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
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
        return b
      }

      let request = base()
      for (const column of INSTALLED_SORT[q.sort]) {
        request = request.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
      }
      const from = q.page * q.pageSize
      const { data, error, count } = await request.range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as InstalledSrvRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(term || q.regionId || q.mapping !== 'all' || q.due !== 'all' || q.parentKind !== 'all')
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

export interface WarehouseQuery {
  search: string
  availability: string | null
  due: DueFilter
  sort: WarehouseSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_WAREHOUSE_QUERY: WarehouseQuery = {
  search: '', availability: null, due: 'all', sort: 'serial', direction: 'asc', page: 0, pageSize: 50,
}

const WAREHOUSE_SORT: Record<WarehouseSort, string[]> = {
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

      let b = supabase.from('v_warehouse_srv_management').select(WAREHOUSE_COLUMNS, { count: 'exact' })
      if (q.availability) b = b.eq('availability_status', q.availability)
      if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
      if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
      if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
      if (term) {
        const raw = term.replace(/[,()]/g, ' ')
        b = b.or(
          [
            `serial_number.ilike.*${raw}*`,
            `part_number.ilike.*${raw}*`,
            `manufacturer.ilike.*${raw}*`,
            `warehouse_code.ilike.*${raw}*`,
          ].join(','),
        )
      }
      for (const column of WAREHOUSE_SORT[q.sort]) {
        b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
      }
      const from = q.page * q.pageSize
      const { data, error, count } = await b.range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as WarehouseSrvRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(term || q.availability || q.due !== 'all')
      if (total === 0 && hasFilters) {
        const { count: unfiltered } = await supabase!
          .from('v_warehouse_srv_management')
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
export function useInstalledSummary(): { state: Loadable<InstalledSummary>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<InstalledSummary>>({ status: 'loading' })
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

      // ONE round trip, ONE RLS-evaluated scan. This was previously seven
      // parallel count queries, and in production those statements peaked at
      // 7.9s against the `authenticated` role's 8s statement_timeout -- so
      // whichever crossed the line was cancelled and blanked the whole strip
      // (Prompt 25J-B). The counts are identical; only the number of scans
      // changed. Aggregation stays in SQL because tallying rows in the browser
      // could be silently truncated by PostgREST's row limit, and a WRONG count
      // is worse than a stated failure.
      const { data, error } = await supabase
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
  }, [supabase, nonce])

  return { state, reload }
}
