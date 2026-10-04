import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/** Destination options for a store valve: every live Station and Unit (owner request 2026-10-04). */

export interface Destination { station_id: string; unit_id: string | null }
export interface DestinationOption extends Destination { label: string }

/** All live Stations and Units, labelled "Station · Region" and "Unit — Station · Region" (the caller's RLS). */
export function useDestinationOptions(): DestinationOption[] {
  const supabase = useSupabaseClient()
  const [options, setOptions] = useState<DestinationOption[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      let r, s, u
      try {
        [r, s, u] = await Promise.all([
          supabase.from('regions').select('id, name'),
          supabase.from('stations').select('id, station_name, region_id').is('archived_at', null).order('station_name').limit(5000),
          supabase.from('units').select('id, unit_name, station_id').is('archived_at', null).order('unit_name').limit(5000),
        ])
      } catch {
        return
      }
      if (cancelled || r.error || s.error || u.error) return
      const region = new Map((r.data ?? []).map((x) => [x.id as string, x.name as string]))
      const stations = (s.data ?? []).map((x) => ({
        id: x.id as string, name: (x.station_name as string) ?? '', region: region.get(x.region_id as string) ?? '',
      }))
      const byId = new Map(stations.map((x) => [x.id, x]))
      const list: DestinationOption[] = stations.map((x) => ({
        station_id: x.id, unit_id: null, label: [x.name, x.region].filter(Boolean).join(' · '),
      }))
      for (const x of u.data ?? []) {
        const st = byId.get(x.station_id as string)
        if (!st) continue
        list.push({
          station_id: st.id, unit_id: x.id as string,
          label: `${(x.unit_name as string) ?? ''} — ${[st.name, st.region].filter(Boolean).join(' · ')}`,
        })
      }
      // Labels are what the user picks by, so they must be unique.
      const seen = new Set<string>()
      setOptions(list.filter((o) => (seen.has(o.label) ? false : (seen.add(o.label), true))))
    })()
    return () => { cancelled = true }
  }, [supabase])
  return options
}

export function destinationLabel(options: DestinationOption[], d: Destination | null): string {
  if (!d) return ''
  return options.find((o) => o.station_id === d.station_id && o.unit_id === d.unit_id)?.label ?? ''
}
