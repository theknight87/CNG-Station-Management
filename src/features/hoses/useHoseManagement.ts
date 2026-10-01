import type { SupabaseClient } from '@supabase/supabase-js'
import { useCallback, useEffect, useState } from 'react'

import type { DateOption } from '@/components/data/dateRange'
import { applyAssetFilters, EMPTY_ASSET_FILTERS, hasAssetFilters, type AssetFilters } from '@/components/data/assetFilters'
import type { RegistryPage } from '@/components/data/RegistryTable'
import { useSupabaseClient } from '@/lib/supabase/client'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus, PressureUnit } from '@/features/units/useUnitWorkspace'

/**
 * Global Hoses Management.
 *
 * A hose is an INDIVIDUALLY TRACEABLE ITEM, which is what makes this registry
 * different from the others: identity is the primary concern, and serial
 * quality is a first-class operational signal rather than a footnote.
 *
 * WHAT THE SCHEMA ACTUALLY CARRIES. `hoses` holds a free-text `description`, a
 * serial (with `serial_status` and the raw cell), a working-pressure and a
 * test-pressure quad (raw, value, unit), a last-test and next-test date each
 * with explicit precision, `source_status_raw`, and provenance. It carries NO
 * manufacturer and NO model — those columns do not exist and are not parsed out
 * of `description`, because free text is free text. Re-verified against the
 * live schema for this prompt, not assumed from Prompt 10.
 *
 * THE HIERARCHY HAS A LEVEL THE OTHER REGISTRIES DO NOT. `hoses.dispenser_id`
 * exists, so the physical chain is
 * `Region → Station → Unit → Dispenser → Hose`. A dispenser may only be
 * attached once the Unit is known (`hoses_dispenser_needs_unit_ck`), and it
 * must belong to that same Unit (`hoses_dispenser_unit_fk`). Where the source
 * does not say which dispenser a hose serves, `dispenser_id` stays NULL — a
 * description such as `خرطوم غاز C` hints at a bay letter, but mapping that to
 * a dispenser label is not deterministic and is left to a human.
 *
 * AUTHORIZATION IS THE DATABASE'S. `v_hose_registry` is `security_invoker` over
 * `hoses`, whose SELECT policy is `cng_can_read_region(region_id)`, and
 * `region_id` is NOT NULL and pinned to the station's region by
 * `hoses_station_region_fk`. Every query here — including each `count: 'exact'`
 * and each `head: true` metric — runs under that policy.
 */

/**
 * Mapping states a hose can actually hold.
 *
 * `asset_mapping_status` defines four values, but `needs_station_mapping` is
 * UNREACHABLE: `hoses.station_id` is NOT NULL. Verified by attempting the
 * insert, which the not-null constraint rejected. The state could only be
 * stored by naming a Station the record does not actually have, which would be
 * fabricating a mapping — forbidden. Prompt 6 staged 49 hose rows in that
 * state, so this is a THIRD Prompt-21 import blocker alongside the vessel and
 * detector ones. See docs/hoses-management.md §4.
 *
 * `needs_equipment_mapping` does not apply either: a hose's optional parent is
 * a Dispenser, reached through the Unit, not through the SRV lifecycle.
 */
export type HoseMappingStatus = 'resolved' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'

export interface HoseRegistryRow {
  id: string
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  unit_id: string | null
  unit_name: string | null
  dispenser_id: string | null
  dispenser_name: string | null
  mapping_status: HoseMappingStatus
  needs_mapping: boolean
  /** Free source text. Never parsed into manufacturer or model. */
  description: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  /** The source recorded no serial. Distinct from `serial_duplicate`. */
  serial_missing: boolean
  /** Another hose the caller may see carries the same serial. See migration 0030. */
  serial_duplicate: boolean
  working_pressure_raw: string | null
  working_pressure_value: number | null
  working_pressure_unit: PressureUnit | null
  test_pressure_raw: string | null
  test_pressure_value: number | null
  test_pressure_unit: PressureUnit | null
  last_test_date: string | null
  last_test_precision: DatePrecision | null
  last_test_display: string | null
  next_test_date: string | null
  next_test_precision: DatePrecision | null
  next_test_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
  source_file: string | null
  source_sheet: string | null
  source_row: number | null
}

const COLUMNS =
  'id, region_id, region_name, station_id, station_name, unit_id, unit_name, dispenser_id, ' +
  'dispenser_name, mapping_status, needs_mapping, description, serial_number, serial_number_raw, ' +
  'serial_status, serial_missing, serial_duplicate, working_pressure_raw, working_pressure_value, ' +
  'working_pressure_unit, test_pressure_raw, test_pressure_value, test_pressure_unit, ' +
  'last_test_date, last_test_precision, last_test_display, next_test_date, next_test_precision, ' +
  'next_test_display, days_left, due_status, source_status_raw, needs_review, notes, ' +
  'source_file, source_sheet, source_row'

export type HoseSort =
  | 'region' | 'working_pressure' | 'next_due' | 'last_test' | 'station' | 'unit' | 'serial' | 'description' | 'mapping'

export type HoseDueFilter = 'all' | 'overdue' | 'attention' | 'unknown'
export type HoseMappingFilter = 'all' | HoseMappingStatus
/** Serial QUALITY — a different dimension from mapping and from due status. */
export type HoseSerialFilter = 'all' | 'missing' | 'duplicate' | 'recorded'

export interface HoseQuery {
  search: string
  regionId: string | null
  stationId: string | null
  mapping: HoseMappingFilter
  due: HoseDueFilter
  serial: HoseSerialFilter
  filters: AssetFilters
  sort: HoseSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_HOSE_QUERY: HoseQuery = {
  search: '', regionId: null, stationId: null, mapping: 'all', due: 'all', serial: 'all', filters: EMPTY_ASSET_FILTERS,
  sort: 'region', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns. The requested column comes FIRST and `id` is
 * appended as a deterministic tie-break, so paging is stable and a tie can
 * never reorder rows between two requests for the same page.
 */
const SORT_COLUMNS: Record<HoseSort, string[]> = {
  next_due: ['next_test_date'],
  last_test: ['last_test_date'],
  // Owner default (as SRV): Region, then Station, then working pressure smallest first.
  region: ['region_name', 'station_name', 'working_pressure_value'],
  working_pressure: ['working_pressure_value'],
  station: ['station_name', 'unit_name'],
  unit: ['unit_name'],
  serial: ['serial_number'],
  description: ['description'],
  mapping: ['mapping_status'],
}

export const HOSE_DATE: DateOption = { column: 'next_test_date', label: 'Next test', precision: 'next_test_precision' }

/** Every filter the registry applies (no sort, no paging): the table AND its summary use this, so they agree. */
export function applyHoseQuery<B extends { eq: any; in: any; or: any; ilike: any; lte: any; gte: any; lt: any }>(b: B, q: HoseQuery): B { // eslint-disable-line @typescript-eslint/no-explicit-any
  const term = q.search.trim()
  if (q.regionId) b = b.eq('region_id', q.regionId)
  if (q.stationId) b = b.eq('station_id', q.stationId)
  if (q.mapping !== 'all') b = b.eq('mapping_status', q.mapping)
  if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
  if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
  if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
  // Serial quality is its own axis: a missing serial is not an unresolved
  // mapping and not an overdue test.
  if (q.serial === 'missing') b = b.eq('serial_missing', true)
  if (q.serial === 'duplicate') b = b.eq('serial_duplicate', true)
  if (q.serial === 'recorded') b = b.eq('serial_missing', false)
  b = applyAssetFilters(b, q.filters, {
    serial: 'serial_number', station: 'station_name', pressure: 'working_pressure_value', pressureUnit: 'working_pressure_unit',
    date: HOSE_DATE,
  })
  if (term) {
    // Retrieval only. A search hit resolves no mapping and never merges two
    // serials. The folded form is offered so an Arabic description or unit
    // name typed one way finds the other, using the same folding as the SQL.
    const raw = term.replace(/[,()]/g, ' ')
    const folded = foldName(raw)
    b = b.or(
      [
        `serial_number.ilike.*${raw}*`,
        `description.ilike.*${raw}*`,
        `station_name.ilike.*${raw}*`,
        `unit_name.ilike.*${folded}*`,
      ].join(','),
    )
  }
  return b
}

/** Overdue PLUS every due bucket out to 30 days (owner request 2026-10-01, not 60). Stated, never left ambiguous. */
const ATTENTION_BUCKETS = ['overdue', 'due_today', 'due_7', 'due_15', 'due_30']

/** The registry query: filters and sort, no paging (shared by the table and its export). */
export function hoseRequest(supabase: SupabaseClient, q: HoseQuery) {
  let b = supabase.from('v_hose_registry').select(COLUMNS, { count: 'exact' })
  b = applyHoseQuery(b, q)
  for (const column of [...SORT_COLUMNS[q.sort], 'id']) {
    b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
  }
  return b
}

export function useHoses(query: HoseQuery): {
  state: Loadable<RegistryPage<HoseRegistryRow>>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RegistryPage<HoseRegistryRow>>>({ status: 'loading' })
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
      const q: HoseQuery = JSON.parse(key)

      // Every filter is applied SERVER-SIDE, including the ones that narrow the
      // count. Fetching company-wide rows and hiding them in React would make
      // the browser the authorization boundary.
      const from = q.page * q.pageSize
      const { data, error, count } = await hoseRequest(supabase, q).range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        // A failure is a failure. It is never rendered as an empty registry.
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as HoseRegistryRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(
        q.search.trim() || q.regionId || q.stationId || q.mapping !== 'all' || q.due !== 'all' || q.serial !== 'all' ||
          hasAssetFilters(q.filters),
      )
      if (total === 0 && hasFilters) {
        // Distinguishes "you have no hoses" from "none match these filters" —
        // two different empty screens with two different remedies.
        const { count: unfiltered } = await supabase!
          .from('v_hose_registry')
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

export interface HoseSummary {
  total: number
  overdue: number
  /** Includes overdue. */
  attention: number
  needs_unit_mapping: number
  /** No exact next-test date, so no countdown is possible. */
  unknown_date: number
  /** The source recorded no serial. Never conflated with a duplicate. */
  serial_missing: number
  /** Shares a serial with another hose the caller may see. */
  serial_duplicate: number
}

/**
 * The attention summary. Without filters it reads v_hose_summary; with them (owner request 2026-09-28) it counts
 * v_hose_registry through the registry's own filters, so it matches the table. Never the page.
 *
 * Seven `head: true` counts: the server returns numbers and no rows, each under
 * the caller's own RLS. Any failure fails the whole strip, because six correct
 * metrics beside one that silently reads zero is the same lie in a smaller box.
 */
export function useHoseSummary(query?: HoseQuery): { state: Loadable<HoseSummary>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<HoseSummary>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  const key = query ? JSON.stringify({ ...query, sort: null, direction: null, page: 0 }) : ''

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      if (key) {
        const q: HoseQuery = JSON.parse(key)
        const view = () => applyHoseQuery(supabase.from('v_hose_registry').select('id', { count: 'exact', head: true }), q)
        const parts = await Promise.all([
          view(), view().eq('due_status', 'overdue'), view().in('due_status', ATTENTION_BUCKETS),
          view().eq('mapping_status', 'needs_unit_mapping'), view().eq('due_status', 'unknown'),
          view().eq('serial_missing', true), view().eq('serial_duplicate', true),
        ])
        if (cancelled) return
        const failure = parts.find((r) => r.error)
        if (failure?.error) { setState({ status: 'error', message: failure.error.message }); return }
        const [total, overdue, attention, needsUnit, unknownDate, missing, duplicate] = parts.map((r) => r.count ?? 0)
        setState({ status: 'ready', data: {
          total, overdue, attention, needs_unit_mapping: needsUnit, unknown_date: unknownDate,
          serial_missing: missing, serial_duplicate: duplicate,
        } })
        return
      }

      const { data, error } = await supabase.from('v_hose_summary').select('*')
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const summary = (data?.[0] ?? null) as HoseSummary | null
      if (!summary) {
        setState({ status: 'error', message: 'Hose summary returned no row' })
        return
      }

      setState({
        status: 'ready',
        data: summary,
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, key, nonce])

  return { state, reload }
}
