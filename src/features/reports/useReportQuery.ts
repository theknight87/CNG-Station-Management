import { useCallback, useEffect, useMemo, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { selectColumnsFor, type ReportRow, type ReportSpec } from './reportSpecs'

/**
 * The report data layer.
 *
 * SERVER-SIDE EVERYTHING. Filtering, ordering, counting and paging all happen
 * in PostgreSQL. Nothing fetches a table and filters it in the browser: that
 * would be slow once the workbooks are imported, and — far worse — it would mean
 * the browser had briefly held rows the filters were meant to exclude.
 *
 * AUTHORIZATION IS NOT HERE. Every view this reads is `security_invoker`, so
 * RLS applies as the calling user and a viewer or engineer simply cannot select
 * a row outside their Regions, whatever this file asks for. The filters below
 * are a convenience for the person reading; the boundary is the database.
 * A forged `region_id` returns that Region's rows only if the caller was
 * already entitled to them.
 *
 * DETERMINISTIC ORDER. Every query ends with the row's own id. Without a stable
 * tiebreak, two rows sharing a due date can swap between page 1 and page 2 and
 * a record is silently shown twice or not at all.
 */

export interface ReportFilterValues {
  region: string
  station: string
  unit: string
  assetType: string
  dueState: string
  mappingStatus: string
  from: string
  to: string
  search: string
}

export const EMPTY_FILTERS: ReportFilterValues = {
  region: '', station: '', unit: '', assetType: '',
  dueState: '', mappingStatus: '', from: '', to: '', search: '',
}

export const PAGE_SIZE = 50

/**
 * The export ceiling, and why it exists.
 *
 * An export must not be an unbounded table scan streamed into a browser tab.
 * This is a deliberate, documented maximum rather than a silent truncation: the
 * UI states it when a result set is larger, so nobody receives a short file
 * believing it is complete.
 */
export const EXPORT_MAX_ROWS = 10_000
const EXPORT_CHUNK = 1_000

/** Strip the characters PostgREST's `or=` grammar would otherwise read as syntax. */
function safeSearchTerm(raw: string): string {
  return raw.replace(/[(),*"\\]/g, ' ').trim()
}

type QueryBuilder = {
  eq: (col: string, val: unknown) => QueryBuilder
  gte: (col: string, val: unknown) => QueryBuilder
  lte: (col: string, val: unknown) => QueryBuilder
  or: (expr: string) => QueryBuilder
  order: (col: string, opts: { ascending: boolean }) => QueryBuilder
  range: (from: number, to: number) => QueryBuilder
}

/**
 * Apply the active filters to a query, in the columns THIS view actually has.
 *
 * Exported because the export path must apply the identical predicate set. Two
 * copies of this logic is how an export quietly widens its scope.
 */
export function applyReportFilters<Q extends QueryBuilder>(
  query: Q,
  spec: ReportSpec,
  filters: ReportFilterValues,
): Q {
  const cols = spec.filterColumns
  let q = query
  if (filters.region && cols.region) q = q.eq(cols.region, filters.region) as Q
  if (filters.station && cols.station) q = q.eq(cols.station, filters.station) as Q
  if (filters.unit && cols.unit) q = q.eq(cols.unit, filters.unit) as Q
  if (filters.assetType && cols.assetType) q = q.eq(cols.assetType, filters.assetType) as Q
  if (filters.dueState && cols.dueState) q = q.eq(cols.dueState, filters.dueState) as Q
  if (filters.mappingStatus && cols.mappingStatus) {
    q = q.eq(cols.mappingStatus, filters.mappingStatus) as Q
  }
  if (cols.dateRange) {
    if (filters.from) q = q.gte(cols.dateRange, filters.from) as Q
    if (filters.to) q = q.lte(cols.dateRange, `${filters.to}T23:59:59.999Z`) as Q
  }
  if (filters.search && cols.search?.length) {
    const term = safeSearchTerm(filters.search)
    if (term) q = q.or(cols.search.map((c) => `${c}.ilike.%${term}%`).join(',')) as Q
  }
  return q
}

export function applyReportOrder<Q extends QueryBuilder>(query: Q, spec: ReportSpec): Q {
  let q = query
  for (const o of spec.orderBy) q = q.order(o.column, { ascending: o.ascending }) as Q
  // The stable tiebreak. Always last, always present.
  return q.order(spec.idColumn, { ascending: true }) as Q
}

export interface ReportQueryState {
  rows: ReportRow[] | null
  total: number | null
  loading: boolean
  loadError: string | null
  hasMore: boolean
  loadMore: () => void
  /** Fetches the whole authorized result set, in bounded pages, for export. */
  fetchAllForExport: () => Promise<{ rows: ReportRow[]; truncated: boolean } | null>
}

export function useReportQuery(
  spec: ReportSpec,
  filters: ReportFilterValues,
): ReportQueryState {
  const supabase = useSupabaseClient()
  const [rows, setRows] = useState<ReportRow[] | null>(null)
  const [total, setTotal] = useState<number | null>(null)
  const [loading, setLoading] = useState(false)
  const [loadError, setLoadError] = useState<string | null>(null)

  const columns = useMemo(() => selectColumnsFor(spec).join(', '), [spec])
  // The page number is stored WITH the question it answers, so changing a
  // filter resets paging by derivation instead of by an effect that would
  // cascade a second render — and page 3 of one question never survives into
  // another.
  const key = useMemo(() => JSON.stringify([spec.id, filters]), [spec.id, filters])
  const [paging, setPaging] = useState({ key, pages: 1 })
  const pages = paging.key === key ? paging.pages : 1

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      setLoading(true)
      const limit = pages * PAGE_SIZE
      // `count: 'exact'` gives the real total for the summary and the pager.
      // It is computed by the database under the caller's RLS, so the total a
      // viewer sees is the total they are allowed to see.
      let query = supabase.from(spec.view).select(columns, { count: 'exact' })
      query = applyReportFilters(query as unknown as QueryBuilder, spec, filters) as never
      query = applyReportOrder(query as unknown as QueryBuilder, spec) as never
      const { data, error, count } = await (query as unknown as {
        range: (a: number, b: number) => Promise<{ data: unknown; error: { message: string } | null; count: number | null }>
      }).range(0, limit - 1)

      if (cancelled) return
      setLoading(false)
      if (error) { setLoadError(error.message); return }
      setLoadError(null)
      setRows((data ?? []) as ReportRow[])
      setTotal(count ?? null)
    }
    void load()
    return () => { cancelled = true }
  }, [supabase, spec, columns, key, pages, filters])

  const fetchAllForExport = useCallback(async () => {
    if (!supabase) return null
    const collected: ReportRow[] = []
    for (let offset = 0; offset < EXPORT_MAX_ROWS; offset += EXPORT_CHUNK) {
      // The SAME view, the SAME filters, the SAME order, under the SAME RLS —
      // just more pages of it. An export cannot see a row the table could not.
      let query = supabase.from(spec.view).select(columns)
      query = applyReportFilters(query as unknown as QueryBuilder, spec, filters) as never
      query = applyReportOrder(query as unknown as QueryBuilder, spec) as never
      const { data, error } = await (query as unknown as {
        range: (a: number, b: number) => Promise<{ data: unknown; error: { message: string } | null }>
      }).range(offset, offset + EXPORT_CHUNK - 1)
      if (error) { setLoadError(error.message); return null }
      const chunk = (data ?? []) as ReportRow[]
      collected.push(...chunk)
      if (chunk.length < EXPORT_CHUNK) {
        return { rows: collected, truncated: false }
      }
    }
    return { rows: collected, truncated: true }
  }, [supabase, spec, columns, filters])

  return {
    rows,
    total,
    loading,
    loadError,
    hasMore: total !== null && rows !== null && rows.length < total,
    loadMore: () => setPaging({ key, pages: pages + 1 }),
    fetchAllForExport,
  }
}
