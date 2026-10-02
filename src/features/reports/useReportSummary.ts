import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { matchesMulti } from '@/components/data/multiFilter'
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

      const isUnfiltered = Object.values(filters).every((value) => !value)
      if (spec.id === 'due' && isUnfiltered) {
        const { data, error } = await supabase.from('v_report_due_summary').select('*')
        if (cancelled) return
        const row = error ? null : data?.[0]
        setLoading(false)
        setMetrics(row ? [
          { key: 'total', label: 'Total Records', value: row.total, description: 'Records within your authorized Regions' },
          ...DUE_BUCKETS.map((bucket) => ({
            ...bucket,
            value: row[bucket.key] as number,
          })),
        ] : null)
        return
      }

      const count = async (extra?: { column: string; value: string }) => {
        let q = supabase.from(spec.view).select(spec.idColumn, { count: 'exact', head: true })
        q = applyReportFilters(q as never, spec, filters) as never
        if (extra) q = q.eq(extra.column, extra.value) as never
        const { count: n, error } = await q
        return error ? null : (n ?? null)
      }

      // Every figure is an independent head count, so they are requested together (owner report 2026-10-02:
      // one after another, the strip took several round trips to fill).
      const dueColumn = spec.filterColumns.dueState
      // A bucket the user has already filtered to would just restate the total, so it is skipped.
      const buckets = dueColumn ? DUE_BUCKETS.filter((b) => matchesMulti(b.key, filters.dueState)) : []
      const breakdown = spec.summaryBreakdown?.values ?? []
      const [total, bucketCounts, breakdownCounts] = await Promise.all([
        count(),
        Promise.all(buckets.map((b) => count({ column: dueColumn!, value: b.key }))),
        Promise.all(breakdown.map((b) => count({ column: spec.summaryBreakdown!.column, value: b.value }))),
      ])

      const results: SummaryMetric[] = [{
        key: 'total', label: 'Total Records', value: total,
        description: 'Records matching the current filters, within your authorized Regions',
      }]
      buckets.forEach((b, i) => results.push({ key: b.key, label: b.label, description: b.description, value: bucketCounts[i] }))
      // A spec-declared breakdown, where the generic due/mapping split says nothing useful. Each value is
      // counted under the SAME filters and the same RLS, so a zero is a real zero for that caller.
      breakdown.forEach((b, i) => {
        if (breakdownCounts[i]) results.push({ key: b.value, label: b.label, value: breakdownCounts[i], description: b.description })
      })

      // Owner request 2026-10-02: no "Unresolved Mapping" tile — mapping is no longer filtered or reported here.

      if (cancelled) return
      setLoading(false)
      setMetrics(results)
    })()
    return () => { cancelled = true }
  }, [supabase, spec, key, filters])

  return { metrics, loading }
}
