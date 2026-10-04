import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * Where is this serial? (owner request 2026-10-04). Reads cng_srv_serial_whereabouts (security invoker) for the serials
 * being typed into an add form: installed at a station, in the store, at the calibration company or awaiting return
 * blocks a new record; a store-sheet row that only says the valve was sent to a station does not (the warehouse add
 * closes it). The database refuses the same serials on save, so this is a preview, never the guard.
 */

export interface Whereabout { serial: string; kind: string; blocking: boolean; place: string; record_id: string }

export const serialKey = (s: string) => s.trim().toLowerCase()

/** Records found per serial (key: trimmed, lower case); `ready` is false while the typed list has not been checked. */
export function useSerialWhereabouts(serials: string[]) {
  const supabase = useSupabaseClient()
  const wanted = [...new Set(serials.map((s) => s.trim()).filter(Boolean))].sort()
  const key = wanted.join('\n')
  const [result, setResult] = useState<{ key: string; found: Map<string, Whereabout[]> } | null>(null)

  useEffect(() => {
    if (!supabase || !key) return
    let cancelled = false
    const timer = setTimeout(() => {
      void supabase.rpc('cng_srv_serial_whereabouts', { p_serials: key.split('\n') }).then(({ data, error }) => {
        if (cancelled || error) return
        const found = new Map<string, Whereabout[]>()
        for (const w of (data ?? []) as Whereabout[]) {
          const k = serialKey(w.serial)
          found.set(k, [...(found.get(k) ?? []), w])
        }
        setResult({ key, found })
      })
    }, 350)
    return () => { cancelled = true; clearTimeout(timer) }
  }, [supabase, key])

  const found = result?.key === key ? result.found : new Map<string, Whereabout[]>()
  const blocked = wanted.filter((s) => (found.get(serialKey(s)) ?? []).some((w) => w.blocking))
  return { found, blocked, ready: !key || result?.key === key }
}
