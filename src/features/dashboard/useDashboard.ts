import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { DueStatus } from './dueBuckets'

/**
 * Dashboard data.
 *
 * THE RULE THIS FILE EXISTS TO ENFORCE: **a database error is not zero.**
 *
 * The state is a discriminated union, so there is no shape in which a failed
 * query can present as an empty result. A dashboard that renders 0 overdue
 * valves because the query failed is worse than one that renders nothing at
 * all — it is a safety system quietly reporting "all clear" when it does not
 * know. `error` and `ready` are different states and always look different.
 *
 * All five queries hit `security_invoker` aggregate views, so region scoping
 * happens in PostgreSQL under RLS. Nothing here filters by region in
 * JavaScript, and nothing fetches rows in order to count them.
 */

export interface AssetCount {
  asset_kind: string
  total: number
}

export interface DueRow {
  asset_kind: string
  due_status: DueStatus
  total: number
}

export interface RegionRow {
  region_id: string
  region_code: string
  region_name: string
  sort_order: number
  stations: number
  units: number
  assets: number
  overdue: number
  approaching_due: number
  unresolved_mapping: number
}

export interface MappingRow {
  asset_kind: string
  mapping_status: string
  total: number
}

export interface WarehouseRow {
  total: number
  overdue: number
  approaching_due: number
}

export interface DashboardData {
  assets: AssetCount[]
  due: DueRow[]
  regions: RegionRow[]
  mapping: MappingRow[]
  warehouse: WarehouseRow
}

export type DashboardState =
  | { status: 'loading' }
  | { status: 'unconfigured' }
  | { status: 'error'; message: string }
  | { status: 'ready'; data: DashboardData }

export function useDashboard(): { state: DashboardState; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<DashboardState>({ status: 'loading' })
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

      const { data, error } = await supabase.rpc('cng_dashboard_snapshot')

      if (cancelled) return

      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const snapshot = data as DashboardData
      setState({
        status: 'ready',
        data: snapshot,
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  return { state, reload }
}

/** Total across every installed asset kind that carries a due date. */
export function dueTotal(due: DueRow[], statuses: readonly DueStatus[]): number {
  return due.filter((d) => statuses.includes(d.due_status)).reduce((sum, d) => sum + d.total, 0)
}

export function dueFor(due: DueRow[], kind: string, status: DueStatus): number {
  return due.find((d) => d.asset_kind === kind && d.due_status === status)?.total ?? 0
}

export function assetTotal(assets: AssetCount[], kind: string): number {
  return assets.find((a) => a.asset_kind === kind)?.total ?? 0
}

export function mappingTotal(mapping: MappingRow[]): number {
  return mapping.reduce((sum, m) => sum + m.total, 0)
}
