import { useCallback, useMemo, useState } from 'react'
import { CheckCheck, Search, X } from 'lucide-react'
import { Link } from 'react-router-dom'

import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar, PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { DEFAULT_STATION_QUERY, useRegions, useStations } from '@/features/hierarchy/useHierarchy'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { DueBadge, Text } from '@/features/units/assetDisplay'
import {
  AckState, AlertAssetCell, AlertStationCell, AlertUnitCell, DeliveryState, ReadState,
  SubjectLabel, ThresholdBadge,
} from '@/features/alerts/AlertPieces'
import { EnableNotifications } from '@/features/alerts/EnableNotifications'
import {
  DEFAULT_ALERT_QUERY, useAlertActions, useAlertSummary, useAlerts,
  type AlertQuery, type AlertRow, type AlertSort,
} from '@/features/alerts/useAlerts'

/**
 * The Alerts inbox.
 *
 * It answers, in column order: how urgent, which asset, where, when was it due,
 * how far off is that now, have I read it, has anyone acknowledged it, and did
 * the notification get out.
 *
 * ALERT IS NOT DUE STATUS. The Alert column shows the THRESHOLD that fired —
 * a historical fact about why this record exists. The Days left and Status
 * columns show where the asset stands TODAY, live against the Africa/Cairo
 * business date. They routinely disagree, and that is correct: an alert raised
 * at 30 days still says "30 days" long after the asset went overdue.
 *
 * No siren, no pulsing red, no "CRITICAL". Threshold urgency is a scheduling
 * fact, not an assertion about equipment safety.
 */

/** Where an asset's own workspace lives, when its hierarchy is confirmed. */
function assetHref(row: AlertRow): string | null {
  // Neither a Unit nor a Station URL is fabricated for an unresolved one.
  if (row.unit_id) return `/units/${row.unit_id}`
  if (row.station_id) return `/stations/${row.station_id}`
  return null
}

function columns(): RegistryColumn<AlertRow>[] {
  return [
    {
      key: 'threshold', header: 'Alert', rowHeader: true, sort: 'threshold',
      render: (r) => <ThresholdBadge value={r.threshold} />,
    },
    { key: 'serial', header: 'Asset', sort: 'serial', render: (r) => <AlertAssetCell row={r} /> },
    { key: 'station', header: 'Station', sort: 'station', render: (r) => <AlertStationCell row={r} /> },
    { key: 'unit', header: 'Unit', render: (r) => <AlertUnitCell row={r} /> },
    {
      key: 'due_date', header: 'Due date', sort: 'due_date',
      // Always an exact date: a year-only date can never reach an alert.
      render: (r) => <span className="tabular whitespace-nowrap">{r.due_date}</span>,
    },
    {
      key: 'days_left', header: 'Days left', align: 'right', numeric: true,
      render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
    },
    { key: 'due', header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
    { key: 'read', header: 'Read', render: (r) => <ReadState row={r} /> },
    { key: 'ack', header: 'Acknowledged', render: (r) => <AckState row={r} /> },
    // Subject sits here, not second. It is the widest column (~200px) and it is
    // both filterable and implied by the asset type, whereas Acknowledged is a
    // core workflow of this screen — with Subject second, Acknowledged fell 17px
    // outside the visible region at the 1440px desktop target.
    { key: 'subject', header: 'Subject', sort: 'subject', render: (r) => <SubjectLabel value={r.subject} /> },
    { key: 'delivery', header: 'Email', render: (r) => <DeliveryState value={r.email_status} /> },
  ]
}

export function AlertsView() {
  const [query, setQuery] = useState<AlertQuery>(DEFAULT_ALERT_QUERY)
  const [nonce, setNonce] = useState(0)
  const { state, reload } = useAlerts(query)
  const { state: summary, reload: reloadSummary } = useAlertSummary(nonce)
  const { markRead, markAllRead, acknowledge } = useAlertActions()
  const [actionError, setActionError] = useState<string | null>(null)
  const regions = useRegions()

  const stationQuery = useMemo(
    () => ({ ...DEFAULT_STATION_QUERY, regionId: query.regionId, pageSize: 200 }),
    [query.regionId],
  )
  const stations = useStations(stationQuery)

  const update = useCallback((patch: Partial<AlertQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as AlertSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const refresh = useCallback(() => {
    reload()
    setNonce((n) => n + 1)
    reloadSummary()
  }, [reload, reloadSummary])

  // A failed action is SAID, not swallowed. The server is the authority on
  // whether it happened, so the list is re-read either way.
  const onMarkRead = useCallback(
    async (row: AlertRow) => {
      const err = await markRead(row.id, !row.is_read)
      setActionError(err)
      refresh()
    },
    [markRead, refresh],
  )

  /**
   * Marks everything the viewer may see as read — server-side, so it is not
   * quietly limited to the rows currently loaded. It is READ STATE ONLY;
   * nothing here acknowledges anything, and the Acknowledged column is
   * unchanged by it.
   */
  const onMarkAllRead = useCallback(async () => {
    const err = await markAllRead()
    setActionError(err)
    if (!err) refresh()
  }, [markAllRead, refresh])

  const onAcknowledge = useCallback(
    async (row: AlertRow) => {
      const err = await acknowledge(row.id)
      setActionError(err)
      refresh()
    },
    [acknowledge, refresh],
  )

  const clearFilters = useCallback(() => setQuery(DEFAULT_ALERT_QUERY), [])
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.stationId !== null ||
    query.subject !== 'all' || query.threshold !== 'all' || query.read !== 'all' ||
    query.ack !== 'all' || query.delivery !== 'all'
  const total = state.status === 'ready' ? state.data.total : null

  return (
    <PageContainer>
      <PageHeader
        title="Alerts"
        description="Calibration, inspection and test alerts raised for assets you are authorized to see."
        actions={
          <div className="flex flex-wrap items-center gap-2">
            {/* Read is not acknowledgement, so this button says exactly what it
                does and never offers to acknowledge in bulk — that is a
                per-alert operational act. */}
            <Button variant="outline" size="sm" className="h-7" onClick={() => void onMarkAllRead()}>
              <CheckCheck className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
              Mark all as read
            </Button>
            <EnableNotifications />
          </div>
        }
      />

      <div className="flex min-w-0 flex-col gap-3">
        {actionError ? (
          <p role="alert" className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
            That action did not complete: {actionError}
          </p>
        ) : null}

        {summary.status === 'error' ? (
          <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
            The alert summary could not be loaded, so no counts are shown. The table below is unaffected.
          </p>
        ) : null}
        {summary.status === 'ready' ? (
          <section aria-labelledby="alert-attention" className="rounded border bg-card px-3 py-2">
            <h2 id="alert-attention" className="sr-only">
              Alert summary
            </h2>
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4 lg:grid-cols-7">
              <Metric label="Alerts" value={summary.data.total.toLocaleString()} hint="visible to you" />
              <Metric label="Overdue" value={summary.data.overdue.toLocaleString()} tone="overdue" />
              <Metric label="Due today" value={summary.data.due_today.toLocaleString()} tone="due" />
              <Metric label="7-day" value={summary.data.due_7.toLocaleString()} tone="due" />
              <Metric label="Unread" value={summary.data.unread.toLocaleString()} hint="yours" />
              <Metric label="Unacknowledged" value={summary.data.unacknowledged.toLocaleString()} tone="unmapped" />
              {/* A delivery failure is an alert that EXISTS but was not sent —
                * never the same thing as no alert. */}
              <Metric label="Delivery failed" value={summary.data.delivery_failed.toLocaleString()} hint="alert still stands" />
            </div>
            {total !== null && total !== summary.data.total ? (
              <p className="mt-1.5 text-xs text-muted-foreground">
                Counts cover all alerts visible to you. The table below shows{' '}
                <span className="tabular">{total.toLocaleString()}</span> matching the current filters.
              </p>
            ) : null}
          </section>
        ) : null}

        <DataToolbar label="Search and filter alerts">
          <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
            <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
            <span className="sr-only">Search alerts</span>
            <input
              type="search"
              value={query.search}
              onChange={(e) => update({ search: e.target.value })}
              placeholder="Asset serial, station…"
              dir="auto"
              className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
            />
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Region</span>
            <select
              value={query.regionId ?? ''}
              onChange={(e) => update({ regionId: e.target.value || null, stationId: null })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              <option value="">All Regions</option>
              {regions.state.status === 'ready'
                ? regions.state.data.map((r) => (
                    <option key={r.region_id} value={r.region_id}>
                      {r.region_name}
                    </option>
                  ))
                : null}
            </select>
          </label>

          {query.regionId ? (
            <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <span>Station</span>
              <select
                value={query.stationId ?? ''}
                onChange={(e) => update({ stationId: e.target.value || null })}
                className="h-7 max-w-[12rem] rounded border bg-background px-1.5 text-sm text-foreground"
              >
                <option value="">All Stations</option>
                {stations.state.status === 'ready'
                  ? stations.state.data.rows.map((s) => (
                      <option key={s.station_id} value={s.station_id}>
                        {s.station_name}
                      </option>
                    ))
                  : null}
              </select>
            </label>
          ) : null}

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Subject</span>
            <select
              value={query.subject}
              onChange={(e) => update({ subject: e.target.value as AlertQuery['subject'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* The five subjects the schema defines. None invented. */}
              <option value="all">All subjects</option>
              <option value="srv_calibration">SRV calibration</option>
              <option value="storage_inspection">Storage vessel inspection</option>
              <option value="recovery_tank_inspection">Recovery tank inspection</option>
              <option value="gas_detector_calibration">Gas detector calibration</option>
              <option value="hose_hydrotest">Hose hydrotest</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Threshold</span>
            <select
              value={query.threshold}
              onChange={(e) => update({ threshold: e.target.value as AlertQuery['threshold'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              <option value="all">All thresholds</option>
              <option value="overdue">Overdue</option>
              <option value="due_today">Due today</option>
              <option value="due_7">7 days</option>
              <option value="due_15">15 days</option>
              <option value="due_30">30 days</option>
              <option value="due_60">60 days</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Read</span>
            <select
              value={query.read}
              onChange={(e) => update({ read: e.target.value as AlertQuery['read'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              <option value="all">Any read state</option>
              <option value="unread">Unread</option>
              <option value="read">Read</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Acknowledgement</span>
            <select
              value={query.ack}
              onChange={(e) => update({ ack: e.target.value as AlertQuery['ack'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              <option value="all">Any</option>
              <option value="unacknowledged">Not acknowledged</option>
              <option value="acknowledged">Acknowledged</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Delivery</span>
            <select
              value={query.delivery}
              onChange={(e) => update({ delivery: e.target.value as AlertQuery['delivery'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              <option value="all">Any</option>
              <option value="failed">Failed</option>
              <option value="sent">Sent</option>
              <option value="pending">Pending</option>
            </select>
          </label>

          {hasFilters ? (
            <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
              <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
              Clear
            </Button>
          ) : null}
        </DataToolbar>

        <RegistryTable
          label="Alerts"
          state={state}
          reload={reload}
          columns={columns()}
          rowKey={(r) => r.id}
          sort={query.sort}
          direction={query.direction}
          onSort={onSort}
          page={query.page}
          pageSize={query.pageSize}
          onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
          onClearFilters={clearFilters}
          emptyTitle="No alerts"
          emptyDescription="No alert has been raised for any asset you are authorized to see. Alerts are generated daily from assets that have an exact next due date."
          errorTitle="Could not load Alerts"
          detail={(r) => (
            <>
              <Fact label="Alert"><ThresholdBadge value={r.threshold} /></Fact>
              <Fact label="Subject"><SubjectLabel value={r.subject} /></Fact>
              <Fact label="Asset"><AlertAssetCell row={r} /></Fact>
              <Fact label="Asset type"><Text value={r.asset_type.replace(/_/g, ' ')} /></Fact>
              <Fact label="Region"><Text value={r.region_name} /></Fact>
              <Fact label="Station"><AlertStationCell row={r} /></Fact>
              {/* Preserved verbatim; never promoted to a canonical Station. */}
              <Fact label="Station (source text)"><Text value={r.source_station_name_raw} /></Fact>
              <Fact label="Unit"><AlertUnitCell row={r} /></Fact>
              <Fact label="Due date"><span className="tabular">{r.due_date}</span></Fact>
              <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
              <Fact label="Status now"><DueBadge status={r.due_status} /></Fact>
              <Fact label="Raised"><span className="tabular">{r.generated_at.slice(0, 10)}</span></Fact>
              <Fact label="Read"><ReadState row={r} /></Fact>
              <Fact label="Acknowledged"><AckState row={r} /></Fact>
              <Fact label="Acknowledged at">
                {r.acknowledged_at ? <span className="tabular">{r.acknowledged_at.slice(0, 10)}</span> : <NullValue />}
              </Fact>
              {/* Delivery is its own layer: it never changes the alert. */}
              <Fact label="Email delivery"><DeliveryState value={r.email_status} /></Fact>
              <Fact label="Push delivery"><DeliveryState value={r.push_status} /></Fact>

              <div className="col-span-full mt-1 flex flex-wrap items-center gap-2 border-t pt-2">
                <Button variant="outline" size="sm" className="h-7" onClick={() => void onMarkRead(r)}>
                  {r.is_read ? 'Mark as unread' : 'Mark as read'}
                </Button>
                {/* Acknowledging is deliberately a separate, explicit act.
                  * Opening this panel did neither. */}
                <Button
                  variant="outline"
                  size="sm"
                  className="h-7"
                  disabled={Boolean(r.acknowledged_at)}
                  onClick={() => void onAcknowledge(r)}
                >
                  {r.acknowledged_at ? 'Already acknowledged' : 'Acknowledge'}
                </Button>
                {assetHref(r) ? (
                  <Link
                    to={assetHref(r)!}
                    className="text-sm text-brand-strong underline underline-offset-2"
                  >
                    Open {r.unit_id ? 'Unit' : 'Station'}
                  </Link>
                ) : (
                  <span className="text-xs text-muted-foreground">
                    No confirmed hierarchy to open
                  </span>
                )}
              </div>
            </>
          )}
          footnote={
            'The Alert column is the threshold that raised this record; Days left and Status show where the asset stands today, against the Africa/Cairo date. They can differ, and that is expected. ' +
            'Reading an alert is personal to you; acknowledging is a shared operational act recorded with the server-derived user and time. ' +
            'A failed delivery never removes or changes an alert.'
          }
        />
      </div>
    </PageContainer>
  )
}
