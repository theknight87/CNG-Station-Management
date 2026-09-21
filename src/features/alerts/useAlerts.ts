import { useCallback, useEffect, useState } from 'react'

import type { RegistryPage } from '@/components/data/RegistryTable'
import { useSupabaseClient } from '@/lib/supabase/client'
import { foldName } from '@/features/hierarchy/foldName'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { DueStatus } from '@/features/units/useUnitWorkspace'

/**
 * The Alerts inbox.
 *
 * THREE LAYERS, KEPT SEPARATE — this is the whole point of the feature:
 *
 *   DUE STATUS  a calculated property of an asset's date. It exists whether or
 *               not anyone was ever notified, and the asset registries show it.
 *   ALERT       a persisted operational EVENT, created because a rule matched.
 *               It has its own identity, its own lifecycle, and it outlives the
 *               condition that produced it.
 *   DELIVERY    an attempt to surface an alert through email or web push.
 *               Delivery is not the alert: a failed send leaves the alert
 *               exactly as it was.
 *
 * Collapsing any two of these would be the easy mistake. An alert is not
 * deleted when an asset becomes current again, and a delivery failure is never
 * shown as "no alert".
 *
 * AUTHORIZATION IS THE DATABASE'S. `v_alert_inbox` is `security_invoker` over
 * `alerts`, whose SELECT policy scopes by the station's region and routes
 * station-unconfirmed rows through `cng_can_access_unmapped_srv()`. Every query
 * here — rows, counts and each `head: true` metric — runs under that policy.
 * `is_read` and the delivery statuses are the CALLER'S own.
 */

export type AlertSubject =
  | 'srv_calibration'
  | 'storage_inspection'
  | 'recovery_tank_inspection'
  | 'gas_detector_calibration'
  | 'hose_hydrotest'

export type AlertThreshold = 'due_60' | 'due_30' | 'due_15' | 'due_7' | 'due_today' | 'overdue'
export type AlertState = 'open' | 'acknowledged' | 'resolved' | 'suppressed'
export type DeliveryStatus = 'pending' | 'sent' | 'failed' | 'skipped' | null

export interface AlertRow {
  id: string
  subject: AlertSubject
  threshold: AlertThreshold
  state: AlertState
  asset_type: string
  asset_id: string
  region_id: string | null
  region_name: string | null
  station_id: string | null
  station_name: string | null
  /** True only for an SRV whose canonical Station is not yet confirmed. */
  needs_station_mapping: boolean
  /** Raw source place name for that case. Never a canonical Station. */
  source_station_name_raw: string | null
  unit_id: string | null
  unit_name: string | null
  due_date: string
  /** Live, against the Africa/Cairo business date — not the generation snapshot. */
  days_left: number | null
  due_status: DueStatus
  needs_mapping: boolean
  acknowledged_by: string | null
  acknowledged_at: string | null
  acknowledged_by_name: string | null
  resolved_at: string | null
  generated_at: string
  /** This caller's own read state. Another user reading it changes nothing here. */
  is_read: boolean
  read_at: string | null
  email_status: DeliveryStatus
  push_status: DeliveryStatus
  asset_serial: string | null
  asset_serial_status: string | null
}

const COLUMNS =
  'id, subject, threshold, state, asset_type, asset_id, region_id, region_name, station_id, ' +
  'station_name, needs_station_mapping, source_station_name_raw, unit_id, unit_name, ' +
  'due_date, days_left, due_status, needs_mapping, ' +
  'acknowledged_by, acknowledged_at, acknowledged_by_name, resolved_at, generated_at, ' +
  'is_read, read_at, email_status, push_status, asset_serial, asset_serial_status'

export type AlertSort = 'due_date' | 'generated_at' | 'threshold' | 'station' | 'serial' | 'subject'
export type AlertReadFilter = 'all' | 'unread' | 'read'
export type AlertAckFilter = 'all' | 'unacknowledged' | 'acknowledged'
export type AlertDeliveryFilter = 'all' | 'failed' | 'sent' | 'pending'

export interface AlertQuery {
  search: string
  regionId: string | null
  stationId: string | null
  subject: 'all' | AlertSubject
  threshold: 'all' | AlertThreshold
  read: AlertReadFilter
  ack: AlertAckFilter
  delivery: AlertDeliveryFilter
  sort: AlertSort
  direction: 'asc' | 'desc'
  page: number
  pageSize: number
}

export const DEFAULT_ALERT_QUERY: AlertQuery = {
  search: '', regionId: null, stationId: null, subject: 'all', threshold: 'all',
  read: 'all', ack: 'all', delivery: 'all',
  // Most urgent first: the earliest due date is the most overdue.
  sort: 'due_date', direction: 'asc', page: 0, pageSize: 50,
}

/**
 * Sort keys to real columns, with `id` appended as a deterministic tie-break so
 * paging is stable and two requests for the same page cannot reorder.
 */
const SORT_COLUMNS: Record<AlertSort, string[]> = {
  due_date: ['due_date'],
  generated_at: ['generated_at'],
  threshold: ['threshold'],
  station: ['station_name', 'unit_name'],
  serial: ['asset_serial'],
  subject: ['subject'],
}

export function useAlerts(query: AlertQuery): {
  state: Loadable<RegistryPage<AlertRow>>
  reload: () => void
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<RegistryPage<AlertRow>>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])
  const key = JSON.stringify(query)

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })
      const q: AlertQuery = JSON.parse(key)
      const term = q.search.trim()

      let b = supabase.from('v_alert_inbox').select(COLUMNS, { count: 'exact' })
      if (q.regionId) b = b.eq('region_id', q.regionId)
      if (q.stationId) b = b.eq('station_id', q.stationId)
      if (q.subject !== 'all') b = b.eq('subject', q.subject)
      if (q.threshold !== 'all') b = b.eq('threshold', q.threshold)
      if (q.read !== 'all') b = b.eq('is_read', q.read === 'read')
      // Acknowledgement is a property of the ALERT; read state is per-user.
      // They filter independently because they mean different things.
      if (q.ack === 'acknowledged') b = b.eq('state', 'acknowledged')
      if (q.ack === 'unacknowledged') b = b.is('acknowledged_at', null)
      if (q.delivery !== 'all') b = b.eq('email_status', q.delivery)
      if (term) {
        // Retrieval only. A search hit acknowledges nothing and resolves nothing.
        const raw = term.replace(/[,()]/g, ' ')
        const folded = foldName(raw)
        b = b.or(
          [
            `asset_serial.ilike.*${raw}*`,
            `station_name.ilike.*${raw}*`,
            `unit_name.ilike.*${folded}*`,
          ].join(','),
        )
      }
      for (const column of [...SORT_COLUMNS[q.sort], 'id']) {
        b = b.order(column, { ascending: q.direction === 'asc', nullsFirst: false })
      }
      const from = q.page * q.pageSize
      const { data, error, count } = await b.range(from, from + q.pageSize - 1)
      if (cancelled) return
      if (error) {
        // A failure is a failure. It is never an empty inbox.
        setState({ status: 'error', message: error.message })
        return
      }

      const rows = (data ?? []) as unknown as AlertRow[]
      const total = count ?? 0
      let filtered = false
      const hasFilters = Boolean(
        term || q.regionId || q.stationId || q.subject !== 'all' || q.threshold !== 'all' ||
        q.read !== 'all' || q.ack !== 'all' || q.delivery !== 'all',
      )
      if (total === 0 && hasFilters) {
        const { count: unfiltered } = await supabase!
          .from('v_alert_inbox')
          .select('id', { count: 'exact', head: true })
        if (cancelled) return
        filtered = (unfiltered ?? 0) > 0
      }
      setState({ status: 'ready', data: { rows, total, filtered } })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, key, nonce])

  return { state, reload }
}

export interface AlertSummary {
  total: number
  overdue: number
  due_today: number
  due_7: number
  unread: number
  unacknowledged: number
  delivery_failed: number
}

/**
 * Dataset-wide counts, under the caller's own RLS — never the current page and
 * never the current filters. Any single failure fails the whole strip, because
 * six correct metrics beside one silent zero is the same lie in a smaller box.
 */
export function useAlertSummary(nonce = 0): { state: Loadable<AlertSummary>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<AlertSummary>>({ status: 'loading' })
  const [local, setLocal] = useState(0)
  const reload = useCallback(() => setLocal((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      const { data, error } = await supabase.from('v_alert_summary').select('*')
      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }

      const summary = (data?.[0] ?? null) as AlertSummary | null
      if (!summary) {
        setState({ status: 'error', message: 'Alert summary returned no row' })
        return
      }

      setState({
        status: 'ready',
        data: summary,
      })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce, local])

  return { state, reload }
}

/**
 * The two mutations, both routed through database functions.
 *
 * ACKNOWLEDGEMENT IS NEVER A CLIENT WRITE. `authenticated` holds SELECT on
 * `alerts` and no UPDATE grant, so the browser CANNOT set `acknowledged_by` or
 * `acknowledged_at` — it can only ask `cng_acknowledge_alert`, which takes no
 * identity parameter and stamps the actor and time from the server. That is
 * what makes the attribution non-forgeable, and it is why acknowledgement
 * shipped here while mapping mutation is still deferred elsewhere.
 *
 * READ is separate and per-user, via `cng_mark_alert_read` / `_unread`.
 * Opening a row does NOT acknowledge it, and does not mark it read either —
 * both are explicit acts (see docs/alerts-notifications.md).
 */
export function useAlertActions(): {
  markRead: (id: string, read: boolean) => Promise<string | null>
  markAllRead: () => Promise<string | null>
  acknowledge: (id: string) => Promise<string | null>
} {
  const supabase = useSupabaseClient()

  const markRead = useCallback(
    async (id: string, read: boolean): Promise<string | null> => {
      if (!supabase) return 'Not connected'
      const { error } = await supabase.rpc(read ? 'cng_mark_alert_read' : 'cng_mark_alert_unread', {
        p_alert_id: id,
      })
      return error ? error.message : null
    },
    [supabase],
  )

  /**
   * Marks every alert the CALLER can see as read, server-side in one statement.
   *
   * Doing this client-side would mean one RPC per row and would mark only the
   * page currently loaded — "mark all as read" that silently means "mark these
   * fifty" is worse than not offering it. The function is SECURITY INVOKER, so
   * the set is bounded by the same RLS that bounds the inbox, and it is read
   * state only: nothing is acknowledged.
   */
  const markAllRead = useCallback(async (): Promise<string | null> => {
    if (!supabase) return 'Not connected'
    const { error } = await supabase.rpc('cng_mark_all_alerts_read')
    return error ? error.message : null
  }, [supabase])

  const acknowledge = useCallback(
    async (id: string): Promise<string | null> => {
      if (!supabase) return 'Not connected'
      const { error } = await supabase.rpc('cng_acknowledge_alert', { p_alert_id: id })
      return error ? error.message : null
    },
    [supabase],
  )

  return { markRead, markAllRead, acknowledge }
}

/**
 * How many alerts the caller has not read.
 *
 * A HEAD-only count: no rows cross the wire, and `v_alert_inbox` is
 * security_invoker so the number is already scoped to the caller's Regions —
 * the badge can never hint at an alert they may not read.
 *
 * It is fetched ONCE per mount and on demand, never polled. A background poll
 * on every screen would cost a request a second for a number that changes
 * daily, and a count that silently reads zero on a failed request is worse than
 * no badge at all — so a failure leaves the count null and the badge hidden.
 */
export function useUnreadAlertCount(): { count: number | null; refresh: () => void } {
  const supabase = useSupabaseClient()
  const [count, setCount] = useState<number | null>(null)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      const { count: n, error } = await supabase
        .from('v_alert_inbox')
        .select('id', { count: 'exact', head: true })
        .eq('is_read', false)
      if (cancelled) return
      setCount(error ? null : (n ?? 0))
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  const refresh = useCallback(() => setNonce((n) => n + 1), [])
  return { count, refresh }
}
