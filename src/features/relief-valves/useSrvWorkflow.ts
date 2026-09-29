import { useCallback, useEffect, useState } from 'react'

import { useOptionalAppUser } from '@/hooks/useAppUser'
import { useSupabaseClient } from '@/lib/supabase/client'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { PressureUnit } from '@/features/units/useUnitWorkspace'
import { applySmartFilters, type SrvSmartFilters } from '@/features/relief-valves/useSrvManagement'
import type { DateOption } from '@/components/data/dateRange'

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
  serial_number: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
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
    dates: [
      { column: 'logged_at', label: 'Entered the log' },
      { column: 'warehouse_issue_date', label: 'Issued from warehouse' },
      { column: 'returned_at', label: 'Returned' },
    ],
  },
  calibration: {
    view: 'v_srv_calibration',
    columns: `id, status, warehouse_valve_id, sent_at, returned_at, certified_at, certificate_date, certificate_number, ` +
      `next_calibration_date, ${VALVE}`,
    order: 'sent_at', station: null, region: null,
    dates: [
      { column: 'sent_at', label: 'Sent' },
      { column: 'returned_at', label: 'Returned' },
      { column: 'certificate_date', label: 'Certificate' },
    ],
  },
  emergency: {
    view: 'v_srv_emergency',
    columns: 'id, issued_at, notes, region_id, region_name, station_name, unit_name, warehouse_valve_id, issued_serial, ' +
      'issued_code, set_pressure_raw, pressure_min, pressure_max, pressure_unit, replaced_installed_valve_id, ' +
      'replaced_serial, replaced_code, replaced_status, serial_number, manufacturer, size_type, inlet_size, outlet_size',
    order: 'issued_at', station: 'station_name', region: 'region_id',
    dates: [{ column: 'issued_at', label: 'Issued' }],
  },
} as const satisfies Record<string, { view: string; columns: string; order: string; station: string | null; region: string | null; dates: DateOption[] }>

/** The dates each workflow tab can be filtered by. */
export const WORKFLOW_DATES = {
  log: SPECS.log.dates, calibration: SPECS.calibration.dates, emergency: SPECS.emergency.dates,
} as { log: DateOption[]; calibration: DateOption[]; emergency: DateOption[] }

/** The tab's filters on a workflow query (everything except status), shared by the list and its counts. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function workflowFilters<B extends { ilike: any; lte: any; gte: any; lt: any; eq: any }>(b: B, kind: keyof typeof SPECS, f?: SrvSmartFilters): B {
  if (!f) return b
  const spec = SPECS[kind]
  const dates = [...spec.dates] as DateOption[]
  // Emergency rows carry the ISSUED valve's serial, manufacturer, size and pressure (view 20260928170000).
  if (spec.station) return applySmartFilters(b, f, spec.station, spec.region ?? 'region_id', dates)
  return applySmartFilters(b, { ...f, station: '', region: '' }, 'serial_number', 'region_id', dates)
}

/**
 * How many rows each status holds under the tab's filters (owner request 2026-09-29: a count strip on the
 * Calibration tab that follows the filters). One head-only count per status: exact, and never capped by the
 * row limit the list itself uses.
 */
export function useWorkflowCounts(
  kind: keyof typeof SPECS,
  statuses: readonly string[],
  filters: SrvSmartFilters,
  nonce = 0,
): Loadable<Record<string, number>> {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<Record<string, number>>>({ status: 'loading' })
  const key = JSON.stringify({ statuses, filters })
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) { if (!cancelled) setState({ status: 'unconfigured' }); return }
      const o: { statuses: string[]; filters: SrvSmartFilters } = JSON.parse(key)
      const spec = SPECS[kind]
      const results = await Promise.all(o.statuses.map(async (st) => {
        const b = workflowFilters(supabase.from(spec.view).select('id', { count: 'exact', head: true }), kind, o.filters)
        const { count, error } = await b.eq('status', st)
        return { st, count, error }
      }))
      if (cancelled) return
      const failed = results.find((r) => r.error)
      if (failed?.error) { setState({ status: 'error', message: failed.error.message }); return }
      setState({ status: 'ready', data: Object.fromEntries(results.map((r) => [r.st, r.count ?? 0])) })
    })()
    return () => { cancelled = true }
  }, [supabase, kind, key, nonce])
  return state
}

export function useWorkflowList<T>(
  kind: keyof typeof SPECS,
  opts: { status?: string[]; filters?: SrvSmartFilters },
): { state: Loadable<WorkflowList<T>>; reload: () => void; version: number } {
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
      let b = workflowFilters(supabase.from(spec.view).select(spec.columns, { count: 'exact' }), kind, o.filters)
      if (o.status?.length) b = b.in('status', o.status)
      const { data, error, count } = await b.order(spec.order, { ascending: false }).order('id').range(0, WORKFLOW_LIMIT - 1)
      if (cancelled) return
      if (error) { setState({ status: 'error', message: error.message }); return }
      setState({ status: 'ready', data: { rows: (data ?? []) as unknown as T[], total: count ?? 0 } })
    })()
    return () => { cancelled = true }
  }, [supabase, kind, key, nonce])

  return { state, reload, version: nonce }
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

/** Runs one admin RPC after an explicit confirmation; reports the outcome. */
export function useConfirmedAction(onDone: () => void) {
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  async function act(question: string, fn: string, args: Record<string, unknown>, message: string) {
    if (!window.confirm(question)) return
    setError(null); setDone(null)
    const err = await run(fn, args)
    if (err) { setError(err); return }
    setDone(message); onDone()
  }
  return { act, busy, error, done, setError, setDone, run }
}

