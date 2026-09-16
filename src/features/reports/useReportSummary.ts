import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { applyReportFilters, type ReportFilterValues } from './useReportQuery'
import type { ReportSpec } from './reportSpecs'

/**
 * Management summary for the CURRENTLY FILTERED dataset.
 *
 * Counted by the database, over the same view with the same filters under the
 * same RLS — never from the page of rows the table happens to have loaded. A
 * metric computed from page 1 of 40 would be a confident, wrong number, and
 * this product's whole discipline is that a number is either true or absent.
 *
 * `head: true` asks PostgREST for the count and no rows at all, so each figure
 * costs one bounded aggregate rather than a download.
 */
export interface SummaryMetric {
  key: string
  label: string
  /** NULL means the count could not be read — shown as unavailable, never 0. */
  value: number | null
  description: string
}

const DUE_BUCKETS: { key: string; label: string; description: string }[] = [
  { key: 'overdue', label: 'Overdue', description: 'Past its exact due date' },
  { key: 'due_today', label: 'Due Today', description: 'Due on the Cairo business date' },
  { key: 'due_7', label: 'Due ≤ 7 days', description: 'Within seven days' },
  { key: 'due_30', label: 'Due ≤ 30 days', description: 'Within thirty days' },
  {
    key: 'unknown', label: 'Unknown Due Date',
    description: 'No exact due date — never counted as compliant and never as overdue',
  },
]

export function useReportSummary(
  spec: ReportSpec,
  filters: ReportFilterValues,
): { metrics: SummaryMetric[] | null; loading: boolean } {
  const supabase = useSupabaseClient()
  const [metrics, setMetrics] = useState<SummaryMetric[] | null>(null)
  const [loading, setLoading] = useState(false)

  const key = JSON.stringify([spec.id, filters])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      setLoading(true)

      const count = async (extra?: { column: string; value: string }) => {
        let q = supabase.from(spec.view).select(spec.idColumn, { count: 'exact', head: true })
        q = applyReportFilters(q as never, spec, filters) as never
        if (extra) q = q.eq(extra.column, extra.value) as never
        const { count: n, error } = await q
        return error ? null : (n ?? null)
      }

      const results: SummaryMetric[] = [
        {
          key: 'total', label: 'Total Records', value: await count(),
          description: 'Records matching the current filters, within your authorized Regions',
        },
      ]

      const dueColumn = spec.filterColumns.dueState
      if (dueColumn) {
        for (const bucket of DUE_BUCKETS) {
          // A bucket the user has already filtered to would just restate the
          // total, so it is skipped rather than shown twice.
          if (filters.dueState && filters.dueState !== bucket.key) continue
          results.push({
            key: bucket.key, label: bucket.label, description: bucket.description,
            value: await count({ column: dueColumn, value: bucket.key }),
          })
        }
      }

      const mappingColumn = spec.filterColumns.mappingStatus
      if (mappingColumn && !filters.mappingStatus) {
        // "Unresolved" is every mapping state that is not `resolved`, counted as
        // total minus resolved so no state is missed when a new one is added.
        const resolved = await count({ column: mappingColumn, value: 'resolved' })
        const total = results[0].value
        results.push({
          key: 'unresolved', label: 'Unresolved Mapping',
          value: total === null || resolved === null ? null : total - resolved,
          description: 'Records whose hierarchy the source did not fully prove',
        })
      }

      if (cancelled) return
      setLoading(false)
      setMetrics(results)
    })()
    return () => { cancelled = true }
  }, [supabase, spec, key, filters])

  return { metrics, loading }
}
