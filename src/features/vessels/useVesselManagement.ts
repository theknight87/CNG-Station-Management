import type { SupabaseClient } from '@supabase/supabase-js'
import { useCallback, useEffect, useState } from 'react'

import type { DateOption } from '@/components/data/dateRange'
import { applyAssetFilters, EMPTY_ASSET_FILTERS, hasAssetFilters, type AssetFilters } from '@/components/data/assetFilters'
import type { RegistryPage } from '@/components/data/RegistryTable'
import { useSupabaseClient } from '@/lib/supabase/client'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus } from '@/features/units/useUnitWorkspace'

/**
 * Storage Vessels and Recovery Tanks.
 *
 * TWO ASSET TYPES, ONE WORKSPACE, STILL TWO ENTITIES. They share a table
 * (`v_vessel_management` unions them behind an `asset_type` discriminator) and
 * an inspection vocabulary, but they are separate tables with separate rows and
 * separate identities. Every query here pins `asset_type`, so a Storage screen
 * can never show a Recovery Tank, and neither is given a field the other has
 * just to make the two tables look symmetrical.
 *
 * WHAT THE SCHEMA ACTUALLY CARRIES. Both tables hold manufacturer, model,
 * serial (with `serial_status`), a raw `compressor_type_raw`, an inspection
 * date and a next-inspection date with explicit precision, plus provenance.
 * They carry NO capacity, NO design or working pressure, NO manufacture year
 * and NO certificate reference. Those columns do not exist and are not
 * invented — re-verified against the live schema for this prompt, not assumed
 * from Prompt 10.
 *
 * AUTHORIZATION IS THE DATABASE'S. `v_vessel_management` is `security_invoker`
 * over tables whose SELECT policy is `cng_can_read_region(region_id)`. Both
 * `station_id` and `region_id` are NOT NULL on these tables, so unlike SRVs
 * there is no station-unconfirmed path that needs a separate policy: every row
 * is region-scoped, and the `count: 'exact'` behind pagination is scoped with
 * it.
 */

export type VesselAssetType = 'storage_vessel' | 'recovery_tank'

/**
 * Mapping states these assets can actually hold.
 *
 * `asset_mapping_status` also defines `needs_station_mapping`, but that state
 * is UNREACHABLE for vessels: `station_id` is NOT NULL on both tables, so a
 * station-unconfirmed vessel cannot be stored. Verified by attempting the
 * insert, which the not-null constraint rejected. It is still handled in the
 * label map below so that if the schema ever changes, the UI states the truth
 * rather than rendering a blank.
 */
export type VesselMappingStatus = 'resolved' | 'needs_unit_mapping' | 'needs_station_mapping' | 'conflict'

export interface VesselRegistryRow {
  asset_type: VesselAssetType
  id: string
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  unit_id: string | null
  unit_name: string | null
  mapping_status: VesselMappingStatus
  needs_mapping: boolean
  manufacturer: string | null
  model: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  /** Raw source text for the vessel/tank type. Preserved, never interpreted. */
  compressor_type_raw: string | null
  last_inspection_date: string | null
  last_inspection_precision: DatePrecision | null
  last_inspection_display: string | null
  next_inspection_date: string | null
  next_inspection_precision: DatePrecision | null
  next_inspection_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
  /** True when the recorded serial is NULL or blank. Blank is not a duplicate. */
  serial_missing: boolean
  /**
   * DUPLICATE SERIAL CANDIDATE — not a duplicate asset.
   *
   * True when another vessel of the SAME asset type, visible to this caller,
   * records the same non-blank serial. It is EVIDENCE FOR REVIEW under data
   * principle 16: repeated values are not duplicates without supporting
   * evidence. Six identical relief valves on one station may be six real
   * devices. Nothing is merged, deduplicated or invalidated by this flag.
   *
   * Computed in `v_vessel_management`, which is `security_invoker`, so the
   * comparison runs over rows the caller may already read. A collision whose
   * other half is outside the caller's Regions is therefore NOT reported to
   * them, which is correct: it would otherwise disclose a row they may not see.
   */
  serial_duplicate: boolean
  /** How many records share that serial, or NULL where the serial is blank. */
  serial_duplicate_count: number | null
}

const COLUMNS =
  'asset_type, id, region_id, region_name, station_id, station_name, unit_id, unit_name, ' +
  'mapping_status, needs_mapping, manufacturer, model, serial_number, serial_number_raw, ' +
  'serial_status, compressor_type_raw, last_inspection_date, last_inspection_precision, ' +
  'last_inspection_display, next_inspection_date, next_inspection_precision, ' +
  'next_inspection_display, days_left, due_status, source_status_raw, needs_review, notes, ' +
  'serial_missing, serial_duplicate, serial_duplicate_count'

export type VesselSort = 'region' | 'next_due' | 'last_inspection' | 'station' | 'unit' | 'serial' | 'manufacturer' | 'mapping'
export type VesselDueFilter = 'all' | 'overdue' | 'attention' | 'unknown'
export type VesselMappingFilter = 'all' | VesselMappingStatus

export interface VesselQuery {
  search: string
  regionId: string | null
  mapping: VesselMappingFilter
  due: VesselDueFilter
  /** Narrow to duplicate serial candidates. Never hides a member of a pair. */
  duplicateSerial: boolean
  filters: AssetFilters
  sort: VesselSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_VESSEL_QUERY: VesselQuery = {
  search: '', regionId: null, mapping: 'all', due: 'all', duplicateSerial: false, filters: EMPTY_ASSET_FILTERS,
  sort: 'region', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns. The requested column comes FIRST and `id` is
 * appended as a deterministic tie-break, so paging is stable and a secondary
 * `.order()` can never displace the primary sort.
 */
const SORT_COLUMNS: Record<VesselSort, string[]> = {
  next_due: ['next_inspection_date', 'id'],
  last_inspection: ['last_inspection_date', 'id'],
  // Owner default (as SRV): Region, then Station, then Unit. Vessels carry no pressure, so Unit is the third key.
  region: ['region_name', 'station_name', 'unit_name', 'id'],
  station: ['station_name', 'unit_name', 'id'],
  unit: ['unit_name', 'id'],
  serial: ['serial_number', 'id'],
  manufacturer: ['manufacturer', 'id'],
  mapping: ['mapping_status', 'id'],
}

/** Every filter the registry applies (no sort, no paging): the table AND its summary use this, so they agree. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function applyVesselQuery<B extends { eq: any; in: any; or: any; ilike: any; lte: any; gte: any; lt: any }>(b: B, q: VesselQuery): B {
  const term = q.search.trim()
  if (q.regionId) b = b.eq('region_id', q.regionId)
  if (q.mapping !== 'all') b = b.eq('mapping_status', q.mapping)
  if (q.due === 'overdue') b = b.eq('due_status', 'overdue')
  if (q.due === 'unknown') b = b.eq('due_status', 'unknown')
  if (q.due === 'attention') b = b.in('due_status', ATTENTION_BUCKETS)
  if (q.duplicateSerial) b = b.eq('serial_duplicate', true)
  b = applyAssetFilters(b, q.filters, { serial: 'serial_number', station: 'station_name', maker: 'manufacturer', date: VESSEL_DATE })
  if (term) {
    // Retrieval only. Matching a station name here resolves nothing; the
    // folded form is offered so an Arabic query typed one way finds the
    // other, using the same folding the SQL uses.
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
  return b
}

export const VESSEL_DATE: DateOption = { column: 'next_inspection_date', label: 'Next inspection', precision: 'next_inspection_precision' }

/** Overdue PLUS every due bucket out to 60 days. Stated, never left ambiguous. */
const ATTENTION_BUCKETS = ['overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60']

/** The registry query for one vessel type: filters and sort, no paging (shared by the table and its export). */
export function vesselRequest(supabase: SupabaseClient, assetType: VesselAssetType, q: VesselQuery) {
  // `asset_type` is pinned on EVERY query so the two registries can never bleed into one another.
  let b = supabase.from('v_vessel_management').select(COLUMNS, { count: 'exact' }).eq('asset_type', assetType)
  b = applyVesselQuery(b, q)
  for (const column of SORT_COLUMNS[q.sort]) {
    b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
  }
  return b
}

export function useVessels(
  assetType: VesselAssetType,
  query: VesselQuery,
): { state: Loadable<RegistryPage<VesselRegistryRow>>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RegistryPage<VesselRegistryRow>>>({ status: 'loading' })
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
      const q: VesselQuery = JSON.parse(key)

      // `asset_type` is pinned on EVERY query, including the unfiltered count,
      // so the two registries can never bleed into one another.
      const from = q.page * q.pageSize
      const { data, error, count } = await vesselRequest(supabase, assetType, q).range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as VesselRegistryRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(
        q.search.trim() || q.regionId || q.mapping !== 'all' || q.due !== 'all' || q.duplicateSerial ||
          hasAssetFilters(q.filters),
      )
      if (total === 0 && hasFilters) {
        const { count: unfiltered } = await supabase!
          .from('v_vessel_management')
          .select('id', { count: 'exact', head: true })
          .eq('asset_type', assetType)
        if (cancelled) return
        filtered = (unfiltered ?? 0) > 0
      }
      setState({ status: 'ready', data: { rows, total, filtered } })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, assetType, key, nonce])

  return { state, reload }
}

export interface VesselSummary {
  total: number
  overdue: number
  /** Includes overdue. */
  attention: number
  needs_unit_mapping: number
  conflict: number
  /** No exact next-inspection date, so no countdown is possible. */
  unknown_date: number
  /** Records sharing a non-blank serial with another record. Candidates only. */
  serial_duplicate: number
}

/**
 * The attention summary for this asset type. Given the registry query it counts exactly the rows the
 * filters match (owner request 2026-09-28); without one, the whole authorized dataset. Never the page.
 *
 * Seven `head: true` counts: the server returns numbers and no rows. Each runs
 * under the caller's RLS, so the totals are the caller's own. Any failure fails
 * the whole strip, because six correct metrics beside one that silently reads
 * zero is the same lie in a smaller box.
 */
export function useVesselSummary(assetType: VesselAssetType, query?: VesselQuery): {
  state: Loadable<VesselSummary>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<VesselSummary>>({ status: 'loading' })
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

      // With the registry's filters the strip counts exactly what the table shows (owner request 2026-09-28).
      const q: VesselQuery | null = key ? JSON.parse(key) : null
      const view = () => {
        const b = supabase
          .from('v_vessel_management')
          .select('id', { count: 'exact', head: true })
          .eq('asset_type', assetType)
        return q ? applyVesselQuery(b, q) : b
      }

      const [total, overdue, attention, needsUnit, conflict, unknownDate, duplicateSerial] =
        await Promise.all([
          view(),
          view().eq('due_status', 'overdue'),
          view().in('due_status', ATTENTION_BUCKETS),
          view().eq('mapping_status', 'needs_unit_mapping'),
          view().eq('mapping_status', 'conflict'),
          view().eq('due_status', 'unknown'),
          view().eq('serial_duplicate', true),
        ])
      if (cancelled) return

      const failure = [
        total, overdue, attention, needsUnit, conflict, unknownDate, duplicateSerial,
      ].find((r) => r.error)
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
          conflict: conflict.count ?? 0,
          unknown_date: unknownDate.count ?? 0,
          serial_duplicate: duplicateSerial.count ?? 0,
        },
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, assetType, key, nonce])

  return { state, reload }
}

export interface RelatedSrv {
  id: string
  serial_number: string | null
  serial_status: string | null
  part_number: string | null
  tag_number: string | null
  next_calibration_display: string | null
  next_calibration_precision: DatePrecision | null
  due_status: DueStatus
}

/**
 * Installed SRVs whose equipment parent IS this storage vessel.
 *
 * ONLY A PROVEN RELATIONSHIP. The query filters `parent_kind = 'storage_vessel'`
 * AND `parent_id = <this vessel>`, which resolves through the composite foreign
 * key `irv_storage_vessel_unit_fk (storage_vessel_id, unit_id)`. A valve whose
 * source `Location` merely says "Storage" has no `storage_vessel_id` and never
 * appears here — that text is a parent-KIND hint, not an identity.
 *
 * RECOVERY TANKS ARE NOT SUPPORTED, and this hook must never be called for one.
 * `installed_relief_valves` has no `recovery_tank_id` column, no such foreign
 * key, and `srv_parent_kind` is `compressor | storage_vessel | dispenser`. A
 * recovery tank therefore cannot own an SRV, and none is fabricated.
 *
 * NOT N+1: this runs only when a row is EXPANDED, one query for that one
 * vessel, never once per table row.
 */
export function useRelatedSrvs(vesselId: string | null): { state: Loadable<RelatedSrv[]> } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RelatedSrv[]>>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!vesselId) {
        if (!cancelled) setState({ status: 'ready', data: [] })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      const { data, error } = await supabase
        .from('v_installed_srv_management')
        .select(
          'id, serial_number, serial_status, part_number, tag_number, next_calibration_display, ' +
            'next_calibration_precision, due_status',
        )
        .eq('parent_kind', 'storage_vessel')
        .eq('parent_id', vesselId)
        .order('serial_number', { nullsFirst: false })

      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as unknown as RelatedSrv[] })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, vesselId])

  return { state }
}
