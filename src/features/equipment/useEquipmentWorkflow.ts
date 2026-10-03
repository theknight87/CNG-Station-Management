import { useCallback, useEffect, useState } from 'react'

import { applyMulti } from '@/components/data/multiFilter'
import { useSupabaseClient } from '@/lib/supabase/client'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DatePrecision, DueStatus, PressureUnit } from '@/features/units/useUnitWorkspace'
import type { EquipmentKind } from './equipmentKinds'

/**
 * Data for the Hoses / Gas Detectors workflow tabs. Everything is read through security_invoker views under the
 * caller's RLS; every change is an admin-only SECURITY DEFINER function (see useWorkflowAction in the SRV workflow,
 * reused as is). Nothing here writes a table directly or carries an actor.
 */

export interface StockRow {
  id: string
  kind: EquipmentKind
  availability_status: 'available_new' | 'available_calibrated' | 'available_in_store_uc'
  serial_number: string | null
  serial_status: string
  manufacturer: string | null
  model: string | null
  description: string | null
  working_pressure_value: number | null
  working_pressure_unit: PressureUnit | null
  test_pressure_value: number | null
  test_pressure_unit: PressureUnit | null
  last_date: string | null
  last_precision: DatePrecision
  next_date: string | null
  next_precision: DatePrecision
  days_left: number | null
  due_status: DueStatus
  warehouse_code: string | null
  notes: string | null
  updated_at: string
}

export interface LogRow {
  id: string
  kind: EquipmentKind
  status: 'at_station' | 'returned'
  is_emergency: boolean
  region_name: string
  station_name: string
  unit_name: string | null
  serial_number: string | null
  manufacturer: string | null
  model: string | null
  description: string | null
  installed_hose_id: string | null
  installed_gas_detector_id: string | null
  logged_at: string
  returned_at: string | null
  /** Why it is in the Log: replaced by an issue, or the issued item itself after its issue was undone. */
  reason: 'replaced_on_issue' | 'issue_undone'
  issue_id: string
  issue_cancelled: boolean
}

/** One issue (not undone) and where the item it replaced is — the Log's Issued movement. */
export interface IssueRow {
  id: string
  kind: EquipmentKind
  issued_at: string
  is_emergency: boolean
  notes: string | null
  region_name: string
  station_name: string
  unit_name: string | null
  stock_id: string
  issued_serial: string | null
  issued_code: string | null
  manufacturer: string | null
  model: string | null
  description: string | null
  working_pressure_value: number | null
  working_pressure_unit: PressureUnit | null
  replaced_serial: string | null
  status: 'no_replacement' | 'replaced_at_station' | 'replaced_returned'
  replaced_returned_at: string | null
}

export interface JobRow {
  id: string
  kind: EquipmentKind
  status: 'sent' | 'returned_awaiting_certificate' | 'certified'
  stock_id: string
  warehouse_code: string | null
  serial_number: string | null
  manufacturer: string | null
  model: string | null
  description: string | null
  sent_at: string
  returned_at: string | null
  certified_at: string | null
  certificate_date: string | null
  certificate_number: string | null
  next_date: string | null
}

export interface EmergencyRow {
  id: string
  kind: EquipmentKind
  issued_at: string
  notes: string | null
  region_name: string
  station_name: string
  unit_name: string | null
  stock_id: string
  issued_serial: string | null
  issued_code: string | null
  manufacturer: string | null
  model: string | null
  description: string | null
  replaced_serial: string | null
  replaced_status: 'at_station' | 'returned' | null
}

const LISTS = {
  stock: {
    view: 'v_equipment_stock', order: 'updated_at',
    columns: 'id, kind, availability_status, serial_number, serial_status, manufacturer, model, description, working_pressure_value, ' +
      'working_pressure_unit, test_pressure_value, test_pressure_unit, last_date, last_precision, next_date, next_precision, ' +
      'days_left, due_status, warehouse_code, notes, updated_at',
    search: ['serial_number', 'warehouse_code', 'manufacturer', 'model', 'description'],
  },
  log: {
    view: 'v_equipment_field_log', order: 'logged_at',
    columns: 'id, kind, status, is_emergency, region_name, station_name, unit_name, serial_number, manufacturer, model, description, ' +
      'installed_hose_id, installed_gas_detector_id, logged_at, returned_at, reason, issue_id, issue_cancelled',
    search: ['serial_number', 'station_name', 'unit_name', 'manufacturer', 'model', 'description'],
  },
  jobs: {
    view: 'v_equipment_calibration', order: 'sent_at',
    columns: 'id, kind, status, stock_id, warehouse_code, serial_number, manufacturer, model, description, sent_at, returned_at, ' +
      'certified_at, certificate_date, certificate_number, next_date',
    search: ['serial_number', 'warehouse_code', 'certificate_number', 'manufacturer', 'model', 'description'],
  },
  issues: {
    view: 'v_equipment_issue_log', order: 'issued_at',
    columns: 'id, kind, issued_at, is_emergency, notes, region_name, station_name, unit_name, stock_id, issued_serial, issued_code, ' +
      'manufacturer, model, description, working_pressure_value, working_pressure_unit, replaced_serial, status, replaced_returned_at',
    search: ['issued_serial', 'issued_code', 'replaced_serial', 'station_name', 'unit_name'],
  },
  emergency: {
    view: 'v_equipment_emergency', order: 'issued_at',
    columns: 'id, kind, issued_at, notes, region_name, station_name, unit_name, stock_id, issued_serial, issued_code, manufacturer, ' +
      'model, description, replaced_serial, replaced_status',
    search: ['issued_serial', 'issued_code', 'replaced_serial', 'station_name', 'unit_name'],
  },
} as const

/** Upper bound of rows a tab loads at once; the tab says so when reached. */
export const EQUIPMENT_LIMIT = 2000

export interface ListQuery {
  search: string
  /** A multi-choice of statuses ('' = all), see multiFilter.ts. */
  status: string
  /** Store only: a multi-choice of due statuses. */
  due?: string
}

export function useEquipmentList<T>(list: keyof typeof LISTS, kind: EquipmentKind, q: ListQuery, nonce = 0): Loadable<{ rows: T[]; total: number }> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<{ rows: T[]; total: number }>>({ status: 'loading' })
  const key = JSON.stringify(q)
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { if (!cancelled) setState({ status: 'unconfigured' }); return }
      const o: ListQuery = JSON.parse(key)
      const spec = LISTS[list]
      let b = supabase.from(spec.view).select(spec.columns, { count: 'exact' }).eq('kind', kind)
      b = applyMulti(b, list === 'stock' ? 'availability_status' : 'status', o.status)
      if (list === 'stock') b = applyMulti(b, 'due_status', o.due)
      const term = o.search.trim().replace(/[,()*%]/g, ' ').trim()
      if (term) b = b.or(spec.search.map((c) => `${c}.ilike.*${term}*`).join(','))
      const { data, error, count } = await b.order(spec.order, { ascending: false }).order('id').range(0, EQUIPMENT_LIMIT - 1)
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: { rows: (data ?? []) as unknown as T[], total: count ?? 0 } })
    })()
    return () => { cancelled = true }
  }, [supabase, list, kind, key, nonce])
  return state
}

/** One head-only count per status for a tab's count strip, under the tab's search (statuses ignore the status filter). */
export function useEquipmentCounts(list: 'stock' | 'log' | 'jobs' | 'issues', kind: EquipmentKind, statuses: readonly string[], search: string, nonce = 0): Record<string, number> | null {
  const supabase = useSupabaseClient()
  const [counts, setCounts] = useState<Record<string, number> | null>(null)
  const key = JSON.stringify({ statuses, search })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const o: { statuses: string[]; search: string } = JSON.parse(key)
      const spec = LISTS[list]
      const column = list === 'stock' ? 'availability_status' : 'status'
      const term = o.search.trim().replace(/[,()*%]/g, ' ').trim()
      const results = await Promise.all(o.statuses.map(async (st) => {
        let b = supabase.from(spec.view).select('id', { count: 'exact', head: true }).eq('kind', kind).eq(column, st)
        if (term) b = b.or(spec.search.map((c) => `${c}.ilike.*${term}*`).join(','))
        const { count, error } = await b
        return { st, count: error ? null : count }
      }))
      if (cancelled) return
      // A count that failed is left out rather than shown as 0.
      setCounts(Object.fromEntries(results.filter((r) => r.count !== null).map((r) => [r.st, r.count as number])))
    })()
    return () => { cancelled = true }
  }, [supabase, list, kind, key, nonce])
  return counts
}

export interface HistoryRow { occurred_at: string; event: string; summary: string; actor_name: string | null }

export function useEquipmentHistory(kind: EquipmentKind, id: string): Loadable<HistoryRow[]> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<HistoryRow[]>>({ status: 'loading' })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { if (!cancelled) setState({ status: 'unconfigured' }); return }
      const { data, error } = await supabase.rpc('cng_equipment_history', { p_kind: kind, p_id: id })
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as HistoryRow[] })
    })()
    return () => { cancelled = true }
  }, [supabase, kind, id])
  return state
}

export interface Candidate { id: string; serial_number: string | null; manufacturer: string | null; model: string | null; description: string | null; unit_name: string | null; last_date: string | null }

/** Items of this kind installed at the Station (and Unit, when chosen) that the issued one may replace. */
export function useReplacementCandidates(kind: EquipmentKind, stationId: string | null, unitId: string | null): Loadable<Candidate[]> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<Candidate[]>>({ status: 'ready', data: [] })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase || !stationId) { if (!cancelled) setState({ status: 'ready', data: [] }); return }
      setState({ status: 'loading' })
      const { data, error } = await supabase.rpc('cng_equipment_replacement_candidates', {
        p_kind: kind, p_station_id: stationId, p_unit_id: unitId,
      })
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as Candidate[] })
    })()
    return () => { cancelled = true }
  }, [supabase, kind, stationId, unitId])
  return state
}

/** A reload counter shared by a tab's list and its counts. */
export function useNonce(): [number, () => void] {
  const [n, setN] = useState(0)
  return [n, useCallback(() => setN((x) => x + 1), [])]
}
