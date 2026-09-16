import { useCallback, useEffect, useState } from 'react'

import type { RegistryPage } from '@/components/data/RegistryTable'
import { useSupabaseClient } from '@/lib/supabase/client'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus } from '@/features/units/useUnitWorkspace'

/**
 * Global Gas Detector Management.
 *
 * WHAT THIS IS. A calibration and inventory registry over `gas_detectors`, read
 * through `v_gas_detector_management` (migration 0011). It is NOT a monitoring
 * console: the schema stores no reading, no gas concentration, no alarm state,
 * no online/offline flag, no sensor health and no battery level, so none is
 * shown and none is invented. Re-verified against the live schema for this
 * prompt rather than assumed.
 *
 * TWO KINDS OF ROW, ONE VIEW. The view is a UNION:
 *
 *   1. installed detector assets      — `detector_id` is the `gas_detectors` id
 *   2. explicit presence EVIDENCE     — `detector_id IS NULL`
 *
 * 138 source rows state "Not exist in the station". That is information, and
 * `gas_detector_presence` keeps it WITHOUT fabricating a detector record to
 * represent absence. Because an evidence row is not a device, the registry
 * defaults to `presence = 'installed'`, so "Detectors" always counts real
 * hardware. The evidence is one filter selection away, never silently mixed
 * into an asset count.
 *
 * AREA TYPE IS NOT A DETECTOR COLUMN. `area_type` lives on
 * `gas_detector_presence`, not on `gas_detectors`; the view LEFT JOINs it by
 * (station_id, unit_id). So it classifies the AREA a detector sits in, shared
 * by every detector in that unit, and it is NULL where no presence row covers
 * the detector's station and unit. It is an `area_type` enum of `open` |
 * `closed` — there is NO free-text detector `location` column anywhere in this
 * schema, so no location is displayed and none is inferred.
 *
 * AUTHORIZATION IS THE DATABASE'S. The view is `security_invoker` over two
 * tables whose SELECT policy is `cng_can_read_region(region_id)`, and
 * `region_id` is NOT NULL on both, pinned to the station's region by the
 * `*_station_region_fk` composite foreign keys. Every query here — including
 * every `count: 'exact'` and every `head: true` metric — runs under that
 * policy, so a total is the caller's own total. Nothing is fetched broadly and
 * filtered in React.
 */

/**
 * Mapping states a gas detector can actually hold.
 *
 * `asset_mapping_status` defines four values, but `needs_station_mapping` is
 * UNREACHABLE for gas detectors: `gas_detectors.station_id` is NOT NULL.
 * Verified for this prompt by attempting the insert, which the not-null
 * constraint rejected — the same shape as the vessel discrepancy found in
 * Prompt 12, and a NEW Prompt-21 import blocker for the 219 detector rows
 * Prompt 6 staged in that state. See docs/gas-detector-management.md §4.
 *
 * It is still mapped below so that if the schema ever changes, the UI states
 * the truth instead of rendering a blank badge.
 */
export type DetectorMappingStatus = 'resolved' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'

export type DetectorPresence = 'installed' | 'not_installed' | 'unknown'
export type DetectorAreaType = 'open' | 'closed'

export interface DetectorRegistryRow {
  detector_id: string | null
  detector_presence: DetectorPresence
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  unit_id: string | null
  unit_name: string | null
  /** From `gas_detector_presence`, not from the detector. NULL where unrecorded. */
  area_type: DetectorAreaType | null
  area_type_raw: string | null
  /** NULL on a presence-evidence row: absence has no mapping lifecycle. */
  mapping_status: DetectorMappingStatus | null
  needs_mapping: boolean
  manufacturer: string | null
  model: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
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
}

const COLUMNS =
  'detector_id, detector_presence, region_id, region_name, station_id, station_name, unit_id, ' +
  'unit_name, area_type, area_type_raw, mapping_status, needs_mapping, manufacturer, model, ' +
  'serial_number, serial_number_raw, serial_status, last_calibration_date, ' +
  'last_calibration_precision, last_calibration_display, next_calibration_date, ' +
  'next_calibration_precision, next_calibration_display, days_left, due_status, ' +
  'source_status_raw, needs_review, notes'

/**
 * A stable React key and a deterministic sort identity.
 *
 * A presence-evidence row has no `detector_id`, but
 * `gas_detector_presence` carries a unique index on (station_id, unit_id) and a
 * second on station_id where unit_id IS NULL — so that pair identifies it
 * exactly. Sorting therefore tie-breaks on detector_id, station_id and unit_id
 * together, which is fully deterministic across both branches of the UNION
 * without adding a view column.
 */
export function detectorRowKey(row: DetectorRegistryRow): string {
  if (row.detector_id) return row.detector_id
  return `presence:${row.station_id ?? 'no-station'}:${row.unit_id ?? 'no-unit'}`
}

export type DetectorSort =
  | 'next_due' | 'last_calibration' | 'station' | 'unit' | 'serial'
  | 'manufacturer' | 'area' | 'mapping'

export type DetectorDueFilter = 'all' | 'overdue' | 'attention' | 'unknown'
export type DetectorMappingFilter = 'all' | DetectorMappingStatus
export type DetectorAreaFilter = 'all' | DetectorAreaType
export type DetectorPresenceFilter = 'installed' | 'not_installed' | 'unknown' | 'all'

export interface DetectorQuery {
  search: string
  regionId: string | null
  stationId: string | null
  presence: DetectorPresenceFilter
  area: DetectorAreaFilter
  mapping: DetectorMappingFilter
  due: DetectorDueFilter
  sort: DetectorSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

/**
 * Defaults to installed detectors: the registry's subject is the device.
 * Not-installed evidence is reachable, but it is never counted as a detector.
 */
export const DEFAULT_DETECTOR_QUERY: DetectorQuery = {
  search: '', regionId: null, stationId: null, presence: 'installed', area: 'all',
  mapping: 'all', due: 'all', sort: 'next_due', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns. The requested column comes FIRST; the identity
 * triple is appended so paging is stable and a tie can never reorder between
 * two requests for the same page.
 */
const SORT_COLUMNS: Record<DetectorSort, string[]> = {
  next_due: ['next_calibration_date'],
  last_calibration: ['last_calibration_date'],
  station: ['station_name', 'unit_name'],
  unit: ['unit_name'],
  serial: ['serial_number'],
  manufacturer: ['manufacturer', 'model'],
  area: ['area_type'],
  mapping: ['mapping_status'],
}

const TIE_BREAK = ['detector_id', 'station_id', 'unit_id']

/** Overdue PLUS every due bucket out to 60 days. Stated, never left ambiguous. */
const ATTENTION_BUCKETS = ['overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60']

export function useGasDetectors(query: DetectorQuery): {
  state: Loadable<RegistryPage<DetectorRegistryRow>>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RegistryPage<DetectorRegistryRow>>>({ status: 'loading' })
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
      const q: DetectorQuery = JSON.parse(key)
      const term = q.search.trim()

      // Every filter is applied SERVER-SIDE, including the ones that narrow the
      // count. Fetching company-wide rows and hiding them in React would make
      // the browser the authorization boundary.
      let b = supabase.from('v_gas_detector_management').select(COLUMNS, { count: 'exact' })
      if (q.presence !== 'all') b = b.eq('detector_presence', q.presence)
      if (q.regionId) b = b.eq('region_id', q.regionId)
      if (q.stationId) b = b.eq('station_id', q.stationId)
      if (q.area !== 'all') b = b.eq('area_type', q.area)
      if (q.mapping !== 'all') b = b.eq('mapping_status', q.mapping)
      if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
      if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
      if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
      if (term) {
        // Retrieval only. Matching a station name here RESOLVES NOTHING — no
        // mapping state is advanced by a search hit. The folded form is offered
        // so an Arabic name typed one way finds the other, using the same
        // folding rule the SQL uses.
        const raw = term.replace(/[,()]/g, ' ')
        const folded = foldName(raw)
        b = b.or(
          [
            `serial_number.ilike.*${raw}*`,
            `manufacturer.ilike.*${raw}*`,
            `model.ilike.*${raw}*`,
            `station_name.ilike.*${raw}*`,
            `unit_name.ilike.*${folded}*`,
          ].join(','),
        )
      }
      for (const column of [...SORT_COLUMNS[q.sort], ...TIE_BREAK]) {
        b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
      }
      const from = q.page * q.pageSize
      const { data, error, count } = await b.range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        // A failure is a failure. It is never rendered as an empty registry.
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as DetectorRegistryRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(
        term || q.regionId || q.stationId || q.area !== 'all' || q.mapping !== 'all' ||
        q.due !== 'all' || q.presence !== DEFAULT_DETECTOR_QUERY.presence,
      )
      if (total === 0 && hasFilters) {
        // Distinguishes "you have no detectors" from "none match these
        // filters" — two different empty screens with two different remedies.
        const { count: unfiltered } = await supabase!
          .from('v_gas_detector_management')
          .select('detector_id', { count: 'exact', head: true })
          .eq('detector_presence', 'installed')
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

export interface DetectorSummary {
  /** Installed detector ASSETS. Never includes presence evidence. */
  total: number
  overdue: number
  /** Includes overdue. */
  attention: number
  needs_unit_mapping: number
  /** No exact next-calibration date, so no countdown is possible. */
  unknown_date: number
  /** Explicit "not installed" evidence. A fact about a place, not a device. */
  not_installed: number
  open_area: number
  closed_area: number
}

/**
 * The attention summary, counted over the WHOLE authorized dataset — not the
 * current page and not the current filters.
 *
 * Eight `head: true` counts: the server returns numbers and no rows, each under
 * the caller's own RLS. Any failure fails the whole strip, because seven
 * correct metrics beside one that silently reads zero is the same lie in a
 * smaller box.
 */
export function useGasDetectorSummary(): { state: Loadable<DetectorSummary>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<DetectorSummary>>({ status: 'loading' })
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

      const installed = () =>
        supabase
          .from('v_gas_detector_management')
          .select('detector_id', { count: 'exact', head: true })
          .eq('detector_presence', 'installed')

      const [total, overdue, attention, needsUnit, unknownDate, notInstalled, openArea, closedArea] =
        await Promise.all([
          installed(),
          installed().eq('due_status', 'overdue'),
          installed().in('due_status', ATTENTION_BUCKETS),
          installed().eq('mapping_status', 'needs_unit_mapping'),
          installed().eq('due_status', 'unknown'),
          supabase
            .from('v_gas_detector_management')
            .select('detector_id', { count: 'exact', head: true })
            .eq('detector_presence', 'not_installed'),
          installed().eq('area_type', 'open'),
          installed().eq('area_type', 'closed'),
        ])
      if (cancelled) return

      const all = [total, overdue, attention, needsUnit, unknownDate, notInstalled, openArea, closedArea]
      const failure = all.find((r) => r.error)
      if (failure?.error) {
        setState({ status: 'error', message: failure.error.message })
        return
      }

      setState({
        status: 'ready',
        data: {
          total: total.count ?? 0,
          overdue: overdue.count ?? 0,
          attention: attention.count ?? 0,
          needs_unit_mapping: needsUnit.count ?? 0,
          unknown_date: unknownDate.count ?? 0,
          not_installed: notInstalled.count ?? 0,
          open_area: openArea.count ?? 0,
          closed_area: closedArea.count ?? 0,
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
