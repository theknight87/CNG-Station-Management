import { Link } from 'react-router-dom'

import { EntityName } from '@/components/data/TechnicalText'
import { StatusBadge } from '@/components/data/StatusBadge'
import { SectionHeader } from '@/components/layout/PageContainer'
import {
  DataTable,
  RowHeaderCell,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  TableScroll,
} from '@/components/data/DataTable'
import { cn } from '@/lib/utils'
import {
  ASSET_LABELS,
  ASSET_ROUTES,
  DUE_ASSET_KINDS,
  DUE_BUCKETS,

} from './dueBuckets'
import { assetTotal, dueFor, type AssetCount, type DueRow, type MappingRow, type RegionRow, type WarehouseRow } from './useDashboard'

/**
 * Dashboard panels.
 *
 * Deliberately NOT the generic four-huge-KPIs-then-two-decorative-charts
 * layout (prompt §14). An engineer opening this wants to know what is late and
 * where, in one screen, so the shapes are a compact metric strip, a due MATRIX,
 * and dense tables. Nothing is a card merely because it could be.
 */

/** A number and its meaning, sized for scanning rather than for impact. */
function Metric({
  label,
  value,
  to,
  emphasis = 'normal',
  hint,
}: {
  label: string
  value: number
  to?: string
  emphasis?: 'normal' | 'attention' | 'critical'
  hint?: string
}) {
  const body = (
    <>
      <span
        className={cn(
          'tabular text-xl font-semibold leading-none',
          emphasis === 'critical' && value > 0 && 'text-status-overdue',
          emphasis === 'attention' && value > 0 && 'text-status-due-soon',
        )}
      >
        {value.toLocaleString()}
      </span>
      <span className="mt-0.5 text-xs text-muted-foreground">{label}</span>
    </>
  )

  const className = cn(
    'flex min-w-[6.5rem] flex-col rounded border bg-card px-2.5 py-2',
    to && 'transition-colors hover:border-foreground/25 hover:bg-accent/50',
  )

  // No dead clickable surfaces: a metric is only a link when its destination
  // actually exists (prompt §17).
  return to ? (
    <Link to={to} className={className} title={hint}>
      {body}
    </Link>
  ) : (
    <div className={className} title={hint}>
      {body}
    </div>
  )
}

/**
 * A compact inventory figure — secondary weight, deliberately.
 *
 * These answer "how much is there", which is reference information. They must
 * not compete with the attention metrics above, which answer "what is wrong".
 */
function InventoryItem({ label, value, to }: { label: string; value: number; to?: string }) {
  const body = (
    <>
      <span className="tabular text-sm font-semibold">{value.toLocaleString()}</span>
      <span className="text-xs text-muted-foreground">{label}</span>
    </>
  )
  const className = cn(
    'flex items-baseline gap-1.5 whitespace-nowrap rounded px-2 py-1',
    to && 'transition-colors hover:bg-accent',
  )
  return to ? (
    <Link to={to} className={className}>
      {body}
    </Link>
  ) : (
    <span className={className}>{body}</span>
  )
}

/**
 * The operational summary, in TWO tiers.
 *
 * An earlier version gave ten metrics identical visual weight, so "197
 * overdue" and "71 hoses" competed for the same glance — and the strip wrapped
 * nine-then-one, which reads as eyeballed rather than aligned.
 *
 * Now the three ATTENTION figures lead, and the inventory counts sit beneath
 * them at secondary weight. Size and colour follow importance, which is what a
 * shift engineer opening this screen actually needs.
 */
export function SummaryStrip({
  assets,
  attentionTotal,
  overdueTotal,
  unresolvedTotal,
}: {
  assets: AssetCount[]
  attentionTotal: number
  overdueTotal: number
  unresolvedTotal: number
}) {
  return (
    <section aria-labelledby="summary-heading" className="space-y-2">
      <h2 id="summary-heading" className="sr-only">
        Operational summary
      </h2>

      {/* Tier 1 — what needs a decision. */}
      <div className="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
        <Metric
          label="Overdue"
          value={overdueTotal}
          emphasis="critical"
          to="/alerts"
          hint="Installed assets past their due date, across every asset type"
        />
        <Metric
          label="Needs attention ≤60d"
          value={attentionTotal}
          emphasis="attention"
          to="/alerts"
          hint="Overdue plus everything due within 60 days"
        />
        <Metric
          label="Unresolved mapping"
          value={unresolvedTotal}
          to="/admin"
          hint="Assets whose place in the hierarchy is not yet confirmed by a human"
        />
      </div>

      {/* Tier 2 — how much exists. Reference, not a decision. */}
      <div className="flex flex-wrap items-center gap-x-1 gap-y-0.5 rounded border bg-card px-1 py-1">
        {(['station', 'unit', 'installed_relief_valve', 'storage_vessel', 'recovery_tank', 'gas_detector', 'hose'] as const).map(
          (kind, i) => (
            <span key={kind} className="flex items-center">
              {i > 0 ? <span aria-hidden="true" className="mx-0.5 h-3 w-px bg-border" /> : null}
              <InventoryItem
                label={ASSET_LABELS[kind]}
                value={assetTotal(assets, kind)}
                to={ASSET_ROUTES[kind]}
              />
            </span>
          ),
        )}
      </div>
    </section>
  )
}

/**
 * The due matrix: asset kind down, bucket across.
 *
 * A matrix rather than a chart because the operational question is "which
 * asset type is late, and by how much" — a number answers that exactly, and a
 * bar only approximately. The buckets are mutually exclusive, so a row sums to
 * that asset kind's total.
 */
export function DueMatrix({ due }: { due: DueRow[] }) {
  const kinds = DUE_ASSET_KINDS.filter((k) => due.some((d) => d.asset_kind === k))

  return (
    <section aria-labelledby="due-heading" className="space-y-1.5">
      <SectionHeader
        id="due-heading"
        title="Inspection and calibration"
        description="Buckets are mutually exclusive — each asset appears in exactly one column, so a row sums to its total."
      />

      {kinds.length === 0 ? (
        <p className="rounded border border-dashed px-3 py-6 text-center text-sm text-muted-foreground">
          No assets with inspection or calibration dates are visible to you yet.
        </p>
      ) : (
        <TableScroll label="Inspection and calibration by asset type">
          <DataTable caption="Asset types by due bucket. Buckets are mutually exclusive.">
            <TableHead>
              <TableRow>
                <TableHeader>Asset type</TableHeader>
                {DUE_BUCKETS.map((b) => (
                  <TableHeader key={b.status} align="right">
                    <span title={b.description}>{b.label}</span>
                  </TableHeader>
                ))}
                <TableHeader align="right">Total</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {kinds.map((kind) => {
                const rowTotal = DUE_BUCKETS.reduce((sum, b) => sum + dueFor(due, kind, b.status), 0)
                return (
                  <TableRow key={kind}>
                    <RowHeaderCell>
                      {ASSET_ROUTES[kind] ? (
                        <Link to={ASSET_ROUTES[kind]!} className="underline-offset-4 hover:underline">
                          {ASSET_LABELS[kind]}
                        </Link>
                      ) : (
                        ASSET_LABELS[kind]
                      )}
                    </RowHeaderCell>
                    {DUE_BUCKETS.map((b) => {
                      const n = dueFor(due, kind, b.status)
                      return (
                        <TableCell key={b.status} align="right" numeric>
                          <span
                            className={cn(
                              n === 0 && 'text-muted-foreground',
                              n > 0 && b.status === 'overdue' && 'font-semibold text-status-overdue',
                              n > 0 && (b.status === 'due_today' || b.status === 'due_7') && 'font-medium text-status-due-soon',
                            )}
                          >
                            {n.toLocaleString()}
                          </span>
                        </TableCell>
                      )
                    })}
                    <TableCell align="right" numeric className="font-medium">
                      {rowTotal.toLocaleString()}
                    </TableCell>
                  </TableRow>
                )
              })}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}

/**
 * Region overview.
 *
 * A dense table with an inline proportional bar — NOT a map. ui-ux-pro-max's
 * own guidance says a choropleth misleads when regions differ in size and is
 * poor on mobile; the operational question here is "where is the work", which
 * a ranked table answers precisely.
 *
 * The bar is decoration ON TOP of the number, never instead of it, so the
 * information is fully available as text (prompt §22).
 */
export function RegionOverview({ regions }: { regions: RegionRow[] }) {
  const maxAssets = Math.max(1, ...regions.map((r) => r.assets))

  return (
    <section aria-labelledby="regions-heading" className="space-y-1.5">
      <SectionHeader
        id="regions-heading"
        title="Regions"
        description="Only Regions you are authorized for are listed."
      />

      {regions.length === 0 ? (
        <p className="rounded border border-dashed px-3 py-6 text-center text-sm text-muted-foreground">
          You are not authorized for any Region yet. An administrator grants Region access.
        </p>
      ) : (
        <TableScroll label="Regions">
          <DataTable caption="Regions with their stations, units, assets and outstanding work">
            <TableHead>
              <TableRow>
                <TableHeader>Region</TableHeader>
                <TableHeader align="right">Stations</TableHeader>
                <TableHeader align="right">Units</TableHeader>
                <TableHeader align="right">Assets</TableHeader>
                <TableHeader align="right">Overdue</TableHeader>
                <TableHeader align="right">Due ≤60d</TableHeader>
                <TableHeader align="right">Unresolved</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {regions.map((r) => (
                <TableRow key={r.region_id}>
                  <RowHeaderCell>
                    <div className="flex items-center gap-2">
                      <EntityName name={r.region_name} />
                      {/* Proportional bar: a visual aid beside the number, never
                          a replacement for it. Hidden from assistive tech,
                          which reads the Assets column instead. */}
                      <span
                        aria-hidden="true"
                        className="h-1 w-12 overflow-hidden rounded-sm bg-muted"
                        title={`${r.assets} assets`}
                      >
                        <span
                          className="block h-full bg-foreground/35"
                          style={{ width: `${Math.round((r.assets / maxAssets) * 100)}%` }}
                        />
                      </span>
                    </div>
                  </RowHeaderCell>
                  <TableCell align="right" numeric>{r.stations.toLocaleString()}</TableCell>
                  <TableCell align="right" numeric>{r.units.toLocaleString()}</TableCell>
                  <TableCell align="right" numeric>{r.assets.toLocaleString()}</TableCell>
                  <TableCell align="right" numeric>
                    <span className={cn(r.overdue > 0 ? 'font-semibold text-status-overdue' : 'text-muted-foreground')}>
                      {r.overdue.toLocaleString()}
                    </span>
                  </TableCell>
                  <TableCell align="right" numeric>
                    <span className={cn(r.approaching_due > 0 ? 'text-status-due-soon' : 'text-muted-foreground')}>
                      {r.approaching_due.toLocaleString()}
                    </span>
                  </TableCell>
                  <TableCell align="right" numeric>
                    <span className={cn(r.unresolved_mapping === 0 && 'text-muted-foreground')}>
                      {r.unresolved_mapping.toLocaleString()}
                    </span>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}
    </section>
  )
}

const MAPPING_LABEL: Record<string, string> = {
  needs_station_mapping: 'Needs station mapping',
  needs_unit_mapping: 'Needs unit mapping',
  needs_equipment_mapping: 'Needs equipment mapping',
  conflict: 'Conflict',
}

/** Unresolved work is surfaced, never hidden — it is the Data Quality queue. */
export function DataQualityPanel({ mapping }: { mapping: MappingRow[] }) {
  const byStatus = new Map<string, number>()
  for (const m of mapping) byStatus.set(m.mapping_status, (byStatus.get(m.mapping_status) ?? 0) + m.total)
  const statuses = [...byStatus.entries()].filter(([, n]) => n > 0)

  return (
    <section aria-labelledby="dq-heading" className="space-y-1.5">
      <SectionHeader
        id="dq-heading"
        title="Data quality"
        description="Assets whose place in the hierarchy is not yet confirmed. Unresolved is missing evidence, not a fault."
        actions={
          <Link to="/admin" className="text-xs underline-offset-4 hover:underline">
            Open Data Quality
          </Link>
        }
      />

      {statuses.length === 0 ? (
        <p className="rounded border border-dashed px-3 py-4 text-sm text-muted-foreground">
          No unresolved mapping work in the records visible to you.
        </p>
      ) : (
        <div className="flex flex-wrap gap-1.5">
          {statuses.map(([status, n]) => (
            <div key={status} className="flex items-center gap-2 rounded border bg-card px-2.5 py-1.5">
              <StatusBadge
                kind={status === 'conflict' ? 'conflict' : 'unmapped'}
                label={MAPPING_LABEL[status] ?? status}
              />
              <span className="tabular text-sm font-semibold">{n.toLocaleString()}</span>
            </div>
          ))}
        </div>
      )}
    </section>
  )
}

/**
 * Warehouse inventory, visually and semantically separated.
 *
 * These valves belong to no Unit and carry no mapping lifecycle. They are on
 * the dashboard because stock matters operationally, and in their own bordered
 * strip because adding them to a station asset total would be wrong.
 */
export function WarehousePanel({ warehouse }: { warehouse: WarehouseRow }) {
  return (
    <section aria-labelledby="wh-heading" className="space-y-1.5">
      <SectionHeader
        id="wh-heading"
        title="Warehouse inventory"
        description="Stock, not installed equipment. Never included in Station or Unit asset counts."
      />
      <div className="flex flex-wrap gap-1.5">
        <Metric label="Warehouse SRVs in stock" value={warehouse.total} to="/manage/srvs" />
        <Metric label="Stock overdue calibration" value={warehouse.overdue} emphasis="critical" />
        <Metric label="Stock due ≤60d" value={warehouse.approaching_due} emphasis="attention" />
      </div>
    </section>
  )
}

export { Metric }
