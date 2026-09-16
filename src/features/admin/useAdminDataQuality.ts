import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { SrvMappingStatus, SrvParentKind } from '@/types/domain'
import { describeAdminError } from './useAdminUsers'

/**
 * Data quality and manual mapping.
 *
 * NO COUNT IS HARD-CODED. The staged blocker figures recorded in project history
 * are a PIPELINE fact about a dry run, not a UI constant; every number on this
 * screen is counted from live data by `v_admin_data_quality`, so a resolved
 * record leaves the queue and a genuine zero reads as zero.
 *
 * A CANDIDATE IS NOT A MAPPING. This module offers no suggestion, no similarity
 * ranking and no default parent: the source evidence is shown, and an engineer
 * confirms Station, then Unit, then equipment. The database derives the
 * resulting `mapping_status` from what was actually proven, so a screen cannot
 * declare a record resolved by asserting it.
 */

export interface DataQualityQueue {
  asset: string
  queue: string
  open_count: number
}

export interface SrvQueueRow {
  id: string
  mapping_status: SrvMappingStatus
  updated_at: string
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  unit_id: string | null
  unit_name: string | null
  source_station_name_raw: string | null
  source_region_raw: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  part_number: string | null
  manufacturer: string | null
  manufacturer_raw: string | null
  set_pressure_raw: string | null
  expected_parent_kind: SrvParentKind | null
  source_file: string | null
  source_sheet: string | null
  source_row: number | null
}

export interface MappingDecision {
  stationId: string
  unitId: string | null
  parentKind: SrvParentKind | null
  parentId: string | null
  reason: string
}

/** One unresolved STAGED row, awaiting a pre-import decision. */
export interface StagedQueueRow {
  staging_row_id: string
  source_row_key: string
  target_table: PreImportTarget
  staged_mapping_status: string
  updated_at: string
  source_file: string
  source_sheet: string
  source_row: number
  raw_region: string | null
  raw_station: string | null
  raw_location: string | null
  raw_serial: string | null
  raw_manufacturer: string | null
  raw_model: string | null
  normalized_region: string | null
  serial_number: string | null
  manufacturer: string | null
  model: string | null
  candidate_proposals: { name?: string; score?: number }[] | null
  candidate_kind: string | null
  decision_id: string | null
  confirmed_station_id: string | null
  confirmed_station_name: string | null
  confirmed_unit_id: string | null
  confirmed_unit_name: string | null
  confirmed_mapping_status: string | null
  decided_by_name: string | null
  decided_at: string | null
  decision_reason: string | null
}

export type PreImportTarget = 'storage_vessels' | 'recovery_tanks' | 'gas_detectors' | 'hoses'

export const PRE_IMPORT_TARGETS: { value: PreImportTarget; label: string }[] = [
  { value: 'storage_vessels', label: 'Storage Vessel' },
  { value: 'recovery_tanks', label: 'Recovery Tank' },
  { value: 'gas_detectors', label: 'Gas Detector' },
  { value: 'hoses', label: 'Hose' },
]

export interface QueueFilters {
  /** '' means the canonical installed-SRV queue. */
  assetType: '' | PreImportTarget
  mappingStatus: string
  region: string
  stationSearch: string
}

export const EMPTY_QUEUE_FILTERS: QueueFilters = {
  assetType: '', mappingStatus: '', region: '', stationSearch: '',
}

export const QUEUE_PAGE_SIZE = 50

export function useAdminDataQuality(): {
  queues: DataQualityQueue[] | null
  srvQueue: SrvQueueRow[] | null
  loadError: string | null
  actionError: string | null
  busy: boolean
  mapSrv: (row: SrvQueueRow, decision: MappingDecision) => Promise<boolean>
} {
  const supabase = useSupabaseClient()
  const [queues, setQueues] = useState<DataQualityQueue[] | null>(null)
  const [srvQueue, setSrvQueue] = useState<SrvQueueRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      const [q, s] = await Promise.all([
        supabase.from('v_admin_data_quality').select('*'),
        supabase.from('v_admin_srv_mapping_queue').select('*').order('updated_at').limit(200),
      ])
      if (cancelled) return
      if (q.error) {
        setLoadError(q.error.message)
        return
      }
      setLoadError(null)
      setQueues((q.data ?? []) as DataQualityQueue[])
      setSrvQueue(s.error ? [] : ((s.data ?? []) as SrvQueueRow[]))
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  const mapSrv = useCallback(
    async (row: SrvQueueRow, decision: MappingDecision) => {
      if (!supabase) return false
      setBusy(true)
      setActionError(null)
      // The status is NOT sent. It is derived in SQL from how far the decision
      // actually goes, which is what stops a screen from claiming resolution it
      // has not proven.
      const { error } = await supabase.rpc('cng_admin_map_srv', {
        p_srv_id: row.id,
        p_station_id: decision.stationId,
        p_unit_id: decision.unitId,
        p_parent_kind: decision.parentKind,
        p_parent_id: decision.parentId,
        p_expected_updated_at: row.updated_at,
        p_reason: decision.reason || null,
      })
      setBusy(false)
      if (error) {
        setActionError(describeMappingError(error.message))
        return false
      }
      setNonce((n) => n + 1)
      return true
    },
    [supabase],
  )

  return { queues, srvQueue, loadError, actionError, busy, mapSrv }
}

/**
 * The composite foreign keys reject an impossible hierarchy with a constraint
 * name. That is the correct refusal but not a usable sentence, so it is
 * translated — WITHOUT softening it into a warning or offering to proceed.
 */
export function describeMappingError(message: string): string {
  if (/irv_unit_station_fk/.test(message)) {
    return 'Refused: that Unit does not belong to the confirmed Station. Nothing was changed.'
  }
  if (/irv_compressor_unit_fk|irv_storage_vessel_unit_fk|irv_dispenser_unit_fk/.test(message)) {
    return 'Refused: that equipment does not belong to the confirmed Unit. Nothing was changed.'
  }
  if (/imd_unit_station_fk/.test(message)) {
    return 'Refused: that Unit does not belong to the confirmed Station. Nothing was changed.'
  }
  if (/a decision already exists/.test(message)) {
    return 'Refused: a decision for this source row already exists. Reload so you can see it before changing it.'
  }
  if (/needs no mapping decision|not committable/.test(message)) {
    return 'Refused: this staged row is not one a mapping decision applies to.'
  }
  if (/irv_status_shape_ck|irv_resolved_attribution_ck|imd_status_shape_ck/.test(message)) {
    return 'Refused: the mapping would leave the record in a shape the hierarchy does not allow.'
  }
  if (/before any deeper mapping|before its Unit|unproven/.test(message)) {
    return 'Refused: the hierarchy cannot be skipped. Confirm the Station, then the Unit, then the equipment.'
  }
  return describeAdminError(message)
}

/**
 * The working queues, with the filtering and bounded paging an admin needs to
 * get through the whole staged backlog.
 *
 * One hook serves both the canonical installed-SRV queue and the four
 * pre-import staged queues, because they are the same job at two different
 * stages of a record's life — but they read different sources and are never
 * merged into one list, because one is a stored asset and the other is not yet
 * a record at all.
 */
export function useMappingQueues(filters: QueueFilters): {
  srvRows: SrvQueueRow[] | null
  stagedRows: StagedQueueRow[] | null
  loadError: string | null
  loading: boolean
  hasMore: boolean
  loadMore: () => void
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [srvRows, setSrvRows] = useState<SrvQueueRow[] | null>(null)
  const [stagedRows, setStagedRows] = useState<StagedQueueRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [hasMore, setHasMore] = useState(false)
  const [nonce, setNonce] = useState(0)

  // The page number is stored WITH the filter key it belongs to, so changing a
  // filter resets paging by derivation rather than by an effect that would
  // cascade a second render.
  const key = JSON.stringify(filters)
  const [paging, setPaging] = useState({ key, pages: 1 })
  const pages = paging.key === key ? paging.pages : 1

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      setLoading(true)
      const limit = pages * QUEUE_PAGE_SIZE

      if (filters.assetType === '') {
        let query = supabase
          .from('v_admin_srv_mapping_queue')
          .select('*')
          .order('updated_at')
          .limit(limit + 1)
        if (filters.mappingStatus) query = query.eq('mapping_status', filters.mappingStatus)
        if (filters.region) query = query.eq('region_id', filters.region)
        if (filters.stationSearch) {
          const safe = filters.stationSearch.replace(/[(),*]/g, ' ').trim()
          if (safe) {
            query = query.or(
              `station_name.ilike.%${safe}%,source_station_name_raw.ilike.%${safe}%`,
            )
          }
        }
        const { data, error } = await query
        if (cancelled) return
        setLoading(false)
        if (error) { setLoadError(error.message); return }
        const rows = (data ?? []) as SrvQueueRow[]
        setHasMore(rows.length > limit)
        setSrvRows(rows.slice(0, limit))
        setStagedRows(null)
        setLoadError(null)
        return
      }

      let query = supabase
        .from('v_admin_staged_mapping_queue')
        .select('*')
        .eq('target_table', filters.assetType)
        .order('source_file')
        .order('source_row')
        .limit(limit + 1)
      if (filters.mappingStatus) query = query.eq('staged_mapping_status', filters.mappingStatus)
      // Region on a staged row is RAW text — there is no region_id to filter on,
      // because the Region is exactly what is unconfirmed.
      if (filters.region) query = query.eq('normalized_region', filters.region)
      if (filters.stationSearch) {
        const safe = filters.stationSearch.replace(/[(),*]/g, ' ').trim()
        if (safe) query = query.ilike('raw_station', `%${safe}%`)
      }
      const { data, error } = await query
      if (cancelled) return
      setLoading(false)
      if (error) { setLoadError(error.message); return }
      const rows = (data ?? []) as StagedQueueRow[]
      setHasMore(rows.length > limit)
      setStagedRows(rows.slice(0, limit))
      setSrvRows(null)
      setLoadError(null)
    }
    void load()
    return () => { cancelled = true }
  }, [supabase, key, pages, nonce, filters])

  return {
    srvRows, stagedRows, loadError, loading, hasMore,
    loadMore: () => setPaging({ key, pages: pages + 1 }),
    reload: () => setNonce((n) => n + 1),
  }
}

/**
 * Record a pre-import decision.
 *
 * `p_expected_decision_at` carries the decision the screen was looking at, or
 * NULL for "there was none". Either way a mismatch is refused, so two admins
 * working the same queue cannot both win, and a duplicate decision cannot be
 * recorded by accident.
 */
export function useStagedMappingDecision(): {
  decide: (row: StagedQueueRow, stationId: string, unitId: string | null, reason: string) => Promise<boolean>
  actionError: string | null
  busy: boolean
} {
  const supabase = useSupabaseClient()
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  const decide = useCallback(
    async (row: StagedQueueRow, stationId: string, unitId: string | null, reason: string) => {
      if (!supabase) return false
      setBusy(true)
      setActionError(null)
      const { error } = await supabase.rpc('cng_admin_decide_staged_mapping', {
        p_staging_row_id: row.staging_row_id,
        p_station_id: stationId,
        p_unit_id: unitId,
        p_expected_decision_at: row.decided_at,
        p_reason: reason || null,
      })
      setBusy(false)
      if (error) { setActionError(describeMappingError(error.message)); return false }
      return true
    },
    [supabase],
  )

  return { decide, actionError, busy }
}
