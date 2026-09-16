import { useState } from 'react'
import { Link } from 'react-router-dom'

import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { cairoBusinessDate, downloadCsv, exportFilename, toCsv } from './csv'
import { ReportFiltersBar } from './ReportFiltersBar'
import { ReportTable } from './ReportTable'
import { csvColumnsFor, type ReportSpec } from './reportSpecs'
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
  const summary = useReportSummary(spec, filters)
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

      <ReportSummaryStrip metrics={summary.metrics} loading={summary.loading} />

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
          <div className="flex items-center gap-3">
            <span className="text-xs text-muted-foreground">
              Showing <span className="tabular">{query.rows.length.toLocaleString()}</span>
              {query.total !== null ? (
                <> of <span className="tabular">{query.total.toLocaleString()}</span></>
              ) : null}{' '}
              records
              {query.hasMore ? '' : ' — this is the whole result under these filters'}
            </span>
            {query.hasMore ? (
              <Button
                type="button" variant="outline" size="sm"
                disabled={query.loading} onClick={query.loadMore}
              >
                Load more
              </Button>
            ) : null}
          </div>
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

function ReportSummaryStrip({
  metrics, loading,
}: { metrics: ReturnType<typeof useReportSummary>['metrics']; loading: boolean }) {
  if (loading && !metrics) {
    return <LoadingState label="Counting records" className="py-2" />
  }
  if (!metrics) return null
  return (
    <dl className="flex flex-wrap gap-2" aria-label="Summary for the current filters">
      {metrics.map((m) => (
        <div key={m.key} className="min-w-28 rounded border bg-card px-2 py-1">
          <dt className="text-xs text-muted-foreground" title={m.description}>{m.label}</dt>
          <dd className="tabular text-lg font-semibold">
            {/* An unreadable count shows as unavailable, never as a confident 0. */}
            {m.value === null
              ? <span className="text-sm font-normal text-muted-foreground">unavailable</span>
              : m.value.toLocaleString()}
          </dd>
        </div>
      ))}
    </dl>
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
