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
 * All seven queries hit `security_invoker` aggregate views, so region scoping
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

/** A Station with work piling up (dashboard insight, owner request 2026-10-02). */
export interface StationOverdueRow {
  station_id: string
  station_name: string
  region_name: string
  overdue: number
  approaching_due: number
  assets: number
}

/** Installed relief valves of one manufacturer, and how many are late. */
export interface ManufacturerDueRow {
  manufacturer: string
  total: number
  overdue: number
  approaching_due: number
}

/** How many Stations the insight lists: the worst few, not a second Regions table. */
export const TOP_STATIONS = 8

export interface DashboardData {
  assets: AssetCount[]
  due: DueRow[]
  regions: RegionRow[]
  mapping: MappingRow[]
  warehouse: WarehouseRow
  stations: StationOverdueRow[]
  manufacturers: ManufacturerDueRow[]
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

      const [assets, due, regions, mapping, warehouse, stations, manufacturers] = await Promise.all([
        supabase.from('v_dashboard_asset_counts').select('asset_kind, total'),
        supabase.from('v_dashboard_due_summary').select('asset_kind, due_status, total'),
        supabase
          .from('v_dashboard_region_summary')
          .select(
            'region_id, region_code, region_name, sort_order, stations, units, assets, overdue, approaching_due, unresolved_mapping',
          )
          .order('sort_order'),
        supabase.from('v_dashboard_mapping_summary').select('asset_kind, mapping_status, total'),
        supabase.from('v_dashboard_warehouse_summary').select('total, overdue, approaching_due').maybeSingle(),
        supabase
          .from('v_dashboard_station_overdue')
          .select('station_id, station_name, region_name, overdue, approaching_due, assets')
          .gt('overdue', 0)
          .order('overdue', { ascending: false })
          .order('station_name')
          .limit(TOP_STATIONS),
        supabase
          .from('v_dashboard_srv_manufacturer_due')
          .select('manufacturer, total, overdue, approaching_due')
          .order('overdue', { ascending: false })
          .order('manufacturer'),
      ])

      if (cancelled) return

      // ANY failure fails the whole dashboard. Rendering four working panels
      // beside one silently-empty panel would be the same lie in a smaller box.
      const failure = [assets, due, regions, mapping, warehouse, stations, manufacturers].find((r) => r.error)
      if (failure?.error) {
        setState({ status: 'error', message: failure.error.message })
        return
      }

      setState({
        status: 'ready',
        data: {
          assets: (assets.data ?? []) as AssetCount[],
          due: (due.data ?? []) as DueRow[],
          regions: (regions.data ?? []) as RegionRow[],
          mapping: (mapping.data ?? []) as MappingRow[],
          // An empty warehouse table yields no row at all from an aggregate
          // with no GROUP BY; zero is the correct reading THERE, because the
          // query succeeded.
          warehouse: (warehouse.data as WarehouseRow | null) ?? { total: 0, overdue: 0, approaching_due: 0 },
          stations: (stations.data ?? []) as StationOverdueRow[],
          manufacturers: (manufacturers.data ?? []) as ManufacturerDueRow[],
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
