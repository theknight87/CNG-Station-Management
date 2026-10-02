import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { PaginationControls } from '@/components/data/PaginationControls'
import { cairoBusinessDate, downloadCsv, exportFilename, toCsv } from './csv'
import { ReportFiltersBar } from './ReportFiltersBar'
import { ReportTable } from './ReportTable'
import { csvColumnsFor, type ReportSpec } from './reportSpecs'
import { cn } from '@/lib/utils'
import { EMPTY_FILTERS, EXPORT_MAX_ROWS, useReportQuery, type ReportFilterValues } from './useReportQuery'
import { useReportSummary } from './useReportSummary'

/**
 * One workspace, driven by a report spec.
 *
 * Every report — due, SRV, vessels, detectors, hoses, data quality, activity —
 * is this component with a different spec. That is why the export cannot drift
 * from the table and why a new report cannot quietly acquire different
 * authorization behaviour: there is one query path, one column order and one
 * export, and the spec only says WHICH view and WHICH columns.
 */
export function ReportWorkspace({ spec }: { spec: ReportSpec }) {
  const [filters, setFilters] = useState<ReportFilterValues>(EMPTY_FILTERS)
  const query = useReportQuery(spec, filters)
  // The due tiles ARE the due-state buckets, so they are counted without that one filter (memoized: the summary
  // reloads whenever its filters object changes).
  const summaryFilters = useMemo(() => ({ ...filters, dueState: '' }), [filters])
  const summary = useReportSummary(spec, summaryFilters)
  // Owner request 2026-10-02: the tiles are quick filters — Total clears the due state, a due tile selects it,
  // and pressing the active tile again clears it.
  const canPick = spec.filters.includes('dueState')
  const pickTile = (key: string) => {
    const dueState = key === 'total' || filters.dueState === key ? '' : key
    setFilters({ ...filters, dueState })
  }
  const [exporting, setExporting] = useState(false)
  const [exportNote, setExportNote] = useState<string | null>(null)

  async function handleExport() {
    setExporting(true)
    setExportNote(null)
    // The export re-runs the SAME authorized query. It never reads a table
    // directly and never filters in the browser, so it cannot contain a row the
    // table could not have shown this user.
    const result = await query.fetchAllForExport()
    setExporting(false)
    if (!result) { setExportNote('The export could not be prepared.'); return }
    const csv = toCsv(csvColumnsFor(spec), result.rows)
    downloadCsv(exportFilename(spec.id, cairoBusinessDate()), csv)
    setExportNote(
      result.truncated
        ? `Exported the first ${EXPORT_MAX_ROWS.toLocaleString()} rows. Narrow the filters to export the rest — the file is not the whole result set.`
        : `Exported ${result.rows.length.toLocaleString()} rows.`,
    )
  }

  return (
    <section className="space-y-3" aria-labelledby={`report-${spec.id}`}>
      <SectionHeader
        id={`report-${spec.id}`}
        title={spec.label}
        description={spec.description}
        actions={
          <Button
            type="button" variant="outline" size="sm"
            disabled={exporting || query.rows === null || query.rows.length === 0}
            onClick={() => void handleExport()}
          >
            {exporting ? 'Preparing…' : 'Export CSV'}
          </Button>
        }
      />

      <ReportFiltersBar spec={spec} applied={filters} onApply={setFilters} />

      <ReportSummaryStrip
        metrics={summary.metrics} loading={summary.loading}
        active={filters.dueState || 'total'} onPick={canPick ? pickTile : undefined}
      />

      {exportNote ? (
        <p className="text-xs text-muted-foreground" role="status">{exportNote}</p>
      ) : null}

      {query.loadError ? (
        <ErrorState title="This report could not be loaded" message={query.loadError} />
      ) : query.rows === null ? (
        <LoadingState label={`Loading the ${spec.label} report`} />
      ) : query.rows.length === 0 ? (
        <EmptyReport spec={spec} filtered={JSON.stringify(filters) !== JSON.stringify(EMPTY_FILTERS)} />
      ) : (
        <>
          <ReportTable spec={spec} rows={query.rows} />
          {query.total !== null ? <PaginationControls label={`${spec.label} report`} page={query.page} pageSize={query.pageSize} total={query.total} visibleRows={query.rows.length} loading={query.loading} onPage={query.setPage} /> : null}
        </>
      )}
    </section>
  )
}

/**
 * Empty is a RESULT, not a failure.
 *
 * Production has run no import yet, so most reports are legitimately empty. The
 * two cases are told apart, because "your filters matched nothing" and "nothing
 * has been imported yet" call for different next actions.
 */
function EmptyReport({ spec, filtered }: { spec: ReportSpec; filtered: boolean }) {
  if (filtered) {
    return (
      <EmptyState
        title="No records match the selected filters"
        description="That is a real result, not a missing one. Clear or widen the filters to see more."
      />
    )
  }
  return (
    <EmptyState
      title={`No ${spec.label.toLowerCase()} records yet`}
      description="No canonical assets have been imported yet, so there is nothing to report on. This is the expected state until the controlled import is performed."
    />
  )
}

/** Due-state keys a tile may select; anything else (a spec breakdown) stays a plain figure. */
const PICKABLE = new Set(['total', 'overdue', 'due_today', 'due_7', 'due_30', 'unknown'])

function ReportSummaryStrip({
  metrics, loading, active, onPick,
}: {
  metrics: ReturnType<typeof useReportSummary>['metrics']
  loading: boolean
  active: string
  onPick?: (key: string) => void
}) {
  if (loading && !metrics) {
    return <LoadingState label="Counting records" className="py-2" />
  }
  if (!metrics) return null
  return (
    <div role="group" className="flex flex-wrap gap-2" aria-label="Summary for the current filters">
      {metrics.map((m) => {
        const pickable = Boolean(onPick) && PICKABLE.has(m.key)
        const pressed = pickable && active === m.key
        return (
          <div key={m.key} className={cn('min-w-28 rounded border border-b-2 bg-card', pressed ? 'border-b-brand-strong bg-brand-strong/10' : 'border-b-transparent')}>
            {pickable ? (
              <button
                type="button" aria-pressed={pressed} onClick={() => onPick!(m.key)}
                title={pressed && m.key !== 'total' ? `Showing ${m.label} only — press again to show all` : m.description}
                className="block w-full rounded px-2 py-1 text-left transition-colors hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-strong"
              >
                <SummaryFigure label={m.label} value={m.value} description={m.description} />
              </button>
            ) : (
              <div className="px-2 py-1"><SummaryFigure label={m.label} value={m.value} description={m.description} /></div>
            )}
          </div>
        )
      })}
    </div>
  )
}

function SummaryFigure({ label, value, description }: { label: string; value: number | null; description: string }) {
  return (
    <>
      <span className="block text-xs text-muted-foreground" title={description}>{label}</span>
      <span className="tabular block text-lg font-semibold">
        {/* An unreadable count shows as unavailable, never as a confident 0. */}
        {value === null
          ? <span className="text-sm font-normal text-muted-foreground">unavailable</span>
          : value.toLocaleString()}
      </span>
    </>
  )
}

/**
 * The Data Quality report's pointer back to where corrections actually happen.
 *
 * Reports is a READ surface. There is no mapping control here and no second
 * mapping workflow — only a link, and only for someone who could use it.
 */
export function AdminDataQualityLink({ isAdmin }: { isAdmin: boolean }) {
  if (!isAdmin) {
    return (
      <p className="text-xs text-muted-foreground">
        This report is read-only. Mapping corrections are made by an administrator
        in Admin → Data Quality.
      </p>
    )
  }
  return (
    <p className="text-xs text-muted-foreground">
      This report is read-only.{' '}
      <Link to="/admin/data-quality" className="underline underline-offset-2">
        Resolve mappings in Admin → Data Quality
      </Link>
      .
    </p>
  )
}
