import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * Dependent hierarchy options for the report filters.
 *
 * Region -> Station -> Unit, each level queried FROM the level above, so a
 * Station selector can never offer a Station outside the chosen Region and a
 * Unit selector can never offer a Unit outside the chosen Station.
 *
 * That is convenience, not enforcement, and the difference matters: the lists
 * come back under the caller's RLS, so an engineer is offered only their own
 * Regions' Stations — and if they hand-crafted a request for another Region's
 * Station id, the report query would still return nothing, because every report
 * view is `security_invoker`. Nothing here infers a missing level: a Station
 * with no Units simply offers none.
 *
 * These are deliberately separate from the Admin module's option hooks, which
 * list every Station irrespective of Region because a mapping decision may
 * legitimately move a record between them. Reports filter; Admin assigns.
 *
 * Each query names its columns as a LITERAL, not an interpolated string: the
 * Supabase client type-checks a literal select and cannot check a built one.
 */
export interface Option { id: string; label: string }

export function useRegionOptions(): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const { data, error } = await supabase.from('regions').select('id, name').order('name')
      if (cancelled || error) return
      setOptions((data ?? []).map((r) => ({ id: r.id as string, label: (r.name as string) ?? '' })))
    })()
    return () => { cancelled = true }
  }, [supabase])
  return options
}

export function useStationOptions(regionId: string): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      // No Region chosen means no Station list: offering every Station would
      // invite a Station/Region pair the hierarchy does not support.
      if (!regionId) { setOptions([]); return }
      const { data, error } = await supabase
        .from('stations').select('id, station_name')
        .eq('region_id', regionId).order('station_name')
      if (cancelled || error) return
      setOptions((data ?? []).map((r) => ({
        id: r.id as string, label: (r.station_name as string) ?? '',
      })))
    })()
    return () => { cancelled = true }
  }, [supabase, regionId])
  return options
}

export function useUnitOptions(stationId: string): Option[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<Option[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      if (!stationId) { setOptions([]); return }
      const { data, error } = await supabase
        .from('units').select('id, unit_name')
        .eq('station_id', stationId).order('unit_name')
      if (cancelled || error) return
      setOptions((data ?? []).map((r) => ({
        id: r.id as string, label: (r.unit_name as string) ?? '',
      })))
    })()
    return () => { cancelled = true }
  }, [supabase, stationId])
  return options
}
