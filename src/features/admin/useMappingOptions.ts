import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { SrvParentKind } from '@/types/domain'

/**
 * The choices a mapping decision may be made FROM.
 *
 * Each level is loaded from the level above, so the picker cannot offer a Unit
 * that belongs to another Station or a compressor that belongs to another Unit.
 * That is CONVENIENCE, not enforcement: the composite foreign keys reject an
 * impossible combination regardless of what this offers, which is why the
 * queries below are allowed to be simple.
 *
 * Nothing here ranks, scores or pre-selects a candidate. `expected_parent_kind`
 * narrows which KIND of equipment is offered — it never picks the record.
 */
export interface Option { id: string; label: string }

export function useStations(): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const { data } = await supabase.from('stations').select('id, station_name').order('station_name')
      if (cancelled) return
      setOptions((data ?? []).map((r) => ({ id: r.id as string, label: (r.station_name as string) ?? '' })))
    })()
    return () => { cancelled = true }
  }, [supabase])
  return options
}

export function useUnits(stationId: string | null): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase || !stationId) { setOptions([]); return }
      const { data } = await supabase
        .from('units').select('id, unit_name').eq('station_id', stationId).order('unit_name')
      if (cancelled) return
      setOptions((data ?? []).map((r) => ({ id: r.id as string, label: (r.unit_name as string) ?? '' })))
    })()
    return () => { cancelled = true }
  }, [supabase, stationId])
  return options
}

// All three parent kinds carry `serial_number`, so the column is a literal
// rather than an interpolated one: a dynamic select string defeats the client's
// type checking, which is the only thing catching a renamed column here.
const PARENT_TABLE: Record<SrvParentKind, string> = {
  compressor: 'compressors',
  storage_vessel: 'storage_vessels',
  dispenser: 'dispensers',
}

export function useEquipment(kind: SrvParentKind | null, unitId: string | null): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase || !kind || !unitId) { setOptions([]); return }
      const { data } = await supabase
        .from(PARENT_TABLE[kind]).select('id, serial_number').eq('unit_id', unitId)
      if (cancelled) return
      setOptions(
        (data ?? []).map((r, i) => ({
          id: r.id as string,
          // A serial may genuinely be absent (principle #20). The record is
          // still real, so it is offered — identified by position, and never
          // with an invented identifier standing in for the missing serial.
          label: (r.serial_number as string | null) ?? `${kind} ${i + 1} (no serial recorded)`,
        })),
      )
    })()
    return () => { cancelled = true }
  }, [supabase, kind, unitId])
  return options
}

/** Canonical Regions, for the queue filters. */
export function useRegions(): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const { data } = await supabase.from('regions').select('id, name').order('name')
      if (cancelled) return
      setOptions((data ?? []).map((r) => ({ id: r.id as string, label: (r.name as string) ?? '' })))
    })()
    return () => { cancelled = true }
  }, [supabase])
  return options
}
