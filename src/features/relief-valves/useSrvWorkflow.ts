import { useCallback, useEffect, useState } from 'react'

import { useOptionalAppUser } from '@/hooks/useAppUser'
import { useSupabaseClient } from '@/lib/supabase/client'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { PressureUnit } from '@/features/units/useUnitWorkspace'
import { applySmartFilters, type SrvSmartFilters } from '@/features/relief-valves/useSrvManagement'

/**
 * The warehouse workflow: issue (صرف), SRV Log, Calibration (3rd party), Emergency and history.
 *
 * Every change goes through an admin-only SECURITY DEFINER function that derives the actor
 * server-side, audits the step and refuses a stale selection with HTTP 409. Nothing here writes
 * a table directly, and no payload carries an actor. The admin check below only hides controls;
 * the database refuses a non-admin regardless.
 */

export function useIsAdmin(): boolean {
  const app = useOptionalAppUser()
  return app?.status === 'active' && app.user.role === 'admin'
}

/** A readable sentence for a refused step. 409 means the selection changed under the user. */
export function workflowError(error: { code?: string; message: string }): string {
  if (error.code === 'PT409') return `${error.message}. Nothing was changed.`
  if (error.code === '42501') return 'Only an administrator can do this. Nothing was changed.'
  return error.message
}

export interface ValveFields {
  serial_number: string | null
  manufacturer: string | null
  part_number: string | null
  warehouse_code: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
}

export interface FieldLogRow extends ValveFields {
  id: string
  reason: 'replaced_on_issue' | 'reconcile_other_serial' | 'reconcile_station_not_found'
  status: 'at_station' | 'location_unconfirmed' | 'returned'
  is_emergency: boolean
  region_id: string | null
  region_name: string | null
  station_display: string | null
  unit_name: string | null
  installed_valve_id: string | null
  warehouse_valve_id: string | null
  warehouse_issue_date: string | null
  logged_at: string
  returned_at: string | null
}

export interface CalibrationRow extends ValveFields {
  id: string
  status: 'sent' | 'returned_awaiting_certificate' | 'certified'
  warehouse_valve_id: string
  sent_at: string
  returned_at: string | null
  certified_at: string | null
  certificate_date: string | null
  certificate_number: string | null
  next_calibration_date: string | null
}

export interface EmergencyRow {
  id: string
  issued_at: string
  notes: string | null
  region_id: string
  region_name: string
  station_name: string
  unit_name: string
  warehouse_valve_id: string
  issued_serial: string | null
  issued_code: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  replaced_installed_valve_id: string | null
  replaced_serial: string | null
  replaced_code: string | null
  replaced_status: 'at_station' | 'returned' | null
}

export interface WorkflowList<T> { rows: T[]; total: number }

/** Upper bound of rows a workflow tab loads at once; the tab states it when reached. */
export const WORKFLOW_LIMIT = 2000

const VALVE = 'serial_number, manufacturer, part_number, warehouse_code, size_type, inlet_size, outlet_size, ' +
  'set_pressure_raw, pressure_min, pressure_max, pressure_unit'

const SPECS = {
  log: {
    view: 'v_srv_field_log',
    columns: `id, reason, status, is_emergency, region_id, region_name, station_display, unit_name, installed_valve_id, ` +
      `warehouse_valve_id, warehouse_issue_date, logged_at, returned_at, ${VALVE}`,
    order: 'logged_at', station: 'station_display', region: 'region_id',
  },
  calibration: {
    view: 'v_srv_calibration',
    columns: `id, status, warehouse_valve_id, sent_at, returned_at, certified_at, certificate_date, certificate_number, ` +
      `next_calibration_date, ${VALVE}`,
    order: 'sent_at', station: null, region: null,
  },
  emergency: {
    view: 'v_srv_emergency',
    columns: 'id, issued_at, notes, region_id, region_name, station_name, unit_name, warehouse_valve_id, issued_serial, ' +
      'issued_code, set_pressure_raw, pressure_min, pressure_max, pressure_unit, replaced_installed_valve_id, ' +
      'replaced_serial, replaced_code, replaced_status',
    order: 'issued_at', station: 'station_name', region: 'region_id',
  },
} as const

export function useWorkflowList<T>(
  kind: keyof typeof SPECS,
  opts: { status?: string[]; filters?: SrvSmartFilters },
): { state: Loadable<WorkflowList<T>>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<WorkflowList<T>>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  const key = JSON.stringify(opts)

  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { if (!cancelled) setState({ status: 'unconfigured' }); return }
      if (!cancelled) setState({ status: 'loading' })
      const o: typeof opts = JSON.parse(key)
      const spec = SPECS[kind]
      let b = supabase.from(spec.view).select(spec.columns, { count: 'exact' })
      if (o.status?.length) b = b.in('status', o.status)
      if (o.filters) {
        // Emergency rows carry the ISSUED valve's pressure, not a serial_number column.
        const f = kind === 'emergency' ? { ...o.filters, serial: '', size: '' } : o.filters
        if (spec.station) b = applySmartFilters(b, f, spec.station, spec.region ?? 'region_id')
        else b = applySmartFilters(b, { ...f, station: '', region: '' }, 'serial_number')
      }
      const { data, error, count } = await b.order(spec.order, { ascending: false }).order('id').range(0, WORKFLOW_LIMIT - 1)
      if (cancelled) return
      if (error) { setState({ status: 'error', message: error.message }); return }
      setState({ status: 'ready', data: { rows: (data ?? []) as unknown as T[], total: count ?? 0 } })
    })()
    return () => { cancelled = true }
  }, [supabase, kind, key, nonce])

  return { state, reload }
}

export interface HistoryEvent {
  occurred_at: string | null
  event: string
  summary: string
  actor_name: string | null
  from_source: boolean
}

export function useValveHistory(valveId: string): Loadable<HistoryEvent[]> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<HistoryEvent[]>>({ status: 'loading' })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { if (!cancelled) setState({ status: 'unconfigured' }); return }
      const { data, error } = await supabase.rpc('cng_srv_valve_history', { p_valve_id: valveId })
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as HistoryEvent[] })
    })()
    return () => { cancelled = true }
  }, [supabase, valveId])
  return state
}

export interface ReplacementCandidate extends ValveFields {
  id: string
  location_raw: string | null
  unit_name: string | null
  station_confirmed: boolean
  next_calibration_date: string | null
}

export function useReplacementCandidates(unitId: string | null, warehouseValveId: string): Loadable<ReplacementCandidate[]> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<ReplacementCandidate[]>>({ status: 'ready', data: [] })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase || !unitId) { if (!cancelled) setState({ status: 'ready', data: [] }); return }
      setState({ status: 'loading' })
      const { data, error } = await supabase.rpc('cng_srv_replacement_candidates', {
        p_unit_id: unitId, p_warehouse_valve_id: warehouseValveId,
      })
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as ReplacementCandidate[] })
    })()
    return () => { cancelled = true }
  }, [supabase, unitId, warehouseValveId])
  return state
}

/** Runs one workflow RPC; returns an error sentence or null. */
export function useWorkflowAction() {
  const supabase = useSupabaseClient()
  const [busy, setBusy] = useState(false)
  const run = useCallback(async (fn: string, args: Record<string, unknown>): Promise<string | null> => {
    if (!supabase) return 'Supabase is not configured.'
    setBusy(true)
    try {
      const { error } = await supabase.rpc(fn, args)
      return error ? workflowError(error) : null
    } catch (e) {
      return e instanceof Error ? e.message : 'The request failed.'
    } finally {
      setBusy(false)
    }
  }, [supabase])
  return { run, busy }
}

/** The full size exactly as the tables show it: `M 3/4" X 1"`. */
export function sizeText(type: string | null, inlet: string | null, outlet: string | null): string {
  const prefix = type?.toLowerCase() === 'male' ? 'M' : type?.toLowerCase() === 'female' ? 'F' : type
  return ([prefix, inlet].filter(Boolean).join(' ') + (outlet ? ` X ${outlet}` : '')).trim()
}
