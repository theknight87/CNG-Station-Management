import { useEffect, useState } from 'react'

import { makerKey } from '@/components/data/assetColors'
import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * The manufacturer names present in a registry view (under the caller's RLS), for the Manufacturer filter.
 * Spellings that differ only by case or spacing are offered once; the filter matches them case-insensitively.
 */
export function useMakers(view: string, column = 'manufacturer', eq?: [string, string]): string[] {
  const supabase = useSupabaseClient()
  const [makers, setMakers] = useState<string[]>([])
  const eqKey = eq ? eq.join('=') : ''
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      try {
        let b = supabase.from(view).select(column)
        if (eqKey) { const [c, v] = eqKey.split('='); b = b.eq(c, v) }
        const { data } = await b.range(0, 4999)
        if (cancelled || !data) return
        const seen = new Map<string, string>()
        for (const row of data as unknown as Record<string, string | null>[]) {
          const v = row[column]
          if (v && v.trim() && !seen.has(makerKey(v))) seen.set(makerKey(v), v.replace(/\s+/g, ' ').trim())
        }
        setMakers([...seen.values()].sort((a, b) => a.localeCompare(b)))
      } catch {
        // The filter simply offers no choices; the registry itself is unaffected.
      }
    })()
    return () => { cancelled = true }
  }, [supabase, view, column, eqKey])
  return makers
}
