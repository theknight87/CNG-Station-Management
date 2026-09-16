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
  if (/irv_status_shape_ck|irv_resolved_attribution_ck/.test(message)) {
    return 'Refused: the mapping would leave the record in a shape the hierarchy does not allow.'
  }
  if (/before any deeper mapping|before its Unit|unproven/.test(message)) {
    return 'Refused: the hierarchy cannot be skipped. Confirm the Station, then the Unit, then the equipment.'
  }
  return describeAdminError(message)
}
