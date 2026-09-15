import { useCallback, useMemo, useState } from 'react'
import { ChevronLeft, ChevronRight, Search, X } from 'lucide-react'

import {
  DataTable,
  RowHeaderCell,
  SortableHeader,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TableScroll,
} from '@/components/data/DataTable'
import { EntityName } from '@/components/data/TechnicalText'
import { ValueOrNull } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState, NoResultsState, NotImplemented } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { AttentionBadge, Count, EntityLink } from '@/features/hierarchy/HierarchyPieces'
import {
  DEFAULT_STATION_QUERY,
  pageCount,
  useRangeLabel,
  useRegions,
  useStations,
  type StationQuery,
  type StationSort,
} from '@/features/hierarchy/useHierarchy'

/**
 * The Stations browser: search, filter, sort and pagination over
 * `v_station_summary`.
 *
 * Used by BOTH `/stations` and `/regions/:regionId` — a Region's station list
 * is the same browser with the Region locked, not a second implementation that
 * could drift from it.
 *
 * Every one of those operations runs in PostgreSQL, under the caller's RLS:
 *
 * - The rows are the caller's rows.
 * - The `count` behind "1–50 of 210" is the caller's count. A user authorized
 *   only for East cannot infer how many Stations exist in West by reading the
 *   pagination total, because the total was computed with West invisible.
 * - Search matches the stored name OR its folded form, so `الماظه` finds
 *   `الماظة`. Folding here is a SEARCH AID; it never resolves identity.
 *
 * This is a browsing surface, so it deliberately does not resolve data-quality
 * problems: an unresolved mapping is surfaced and counted, and mapping is done
 * in Admin → Data Quality where the decision is recorded with who and when.
 */
export function StationsBrowser({
  lockedRegionId,
  /** Shown instead of the region filter when the region is fixed. */
  lockedRegionName,
}: {
  lockedRegionId?: string
  lockedRegionName?: string
}) {
  const [query, setQuery] = useState<StationQuery>(() => ({
    ...DEFAULT_STATION_QUERY,
    regionId: lockedRegionId ?? null,
  }))

  // A locked region wins over whatever is in state, so a Region page can never
  // be talked into listing another Region's Stations by a stale filter.
  const effective = useMemo<StationQuery>(
    () => (lockedRegionId ? { ...query, regionId: lockedRegionId } : query),
    [query, lockedRegionId],
  )

  const { state, reload } = useStations(effective)
  const regions = useRegions()

  // Any change to the result set returns to page 1. Staying on page 5 of a
  // newly-filtered list shows an empty table that looks like "no results".
  const update = useCallback((patch: Partial<StationQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const toggleSort = useCallback(
    (sort: StationSort) =>
      setQuery((prev) => ({
        ...prev,
        sort,
        // A new column starts ascending; the same column flips.
        direction: prev.sort === sort && prev.direction === 'asc' ? 'desc' : 'asc',
        page: 0,
      })),
    [],
  )

  const sortFor = (key: StationSort) => (effective.sort === key ? effective.direction : null)

  const hasFilters = Boolean(
    effective.search.trim() || effective.attention !== 'all' || (!lockedRegionId && effective.regionId),
  )
  const clearFilters = useCallback(
    () =>
      setQuery({
        ...DEFAULT_STATION_QUERY,
        regionId: lockedRegionId ?? null,
      }),
    [lockedRegionId],
  )

  const rows = state.status === 'ready' ? state.data.rows : []
  const total = state.status === 'ready' ? state.data.total : 0
  const range = useRangeLabel(effective.page, effective.pageSize, rows.length, total)
  const pages = pageCount(total, effective.pageSize)

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <DataToolbar label="Search and filter Stations">
        <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="sr-only">Search Stations by name</span>
          <input
            type="search"
            value={query.search}
            onChange={(e) => update({ search: e.target.value })}
            placeholder="Search Station name"
            // dir="auto" so an Arabic query renders right-to-left as it is
            // typed, inside an otherwise left-to-right toolbar.
            dir="auto"
            className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
          />
        </label>

        {lockedRegionId ? (
          <span className="rounded border bg-muted px-2 py-0.5 text-xs text-muted-foreground">
            Region: {lockedRegionName ?? '—'}
          </span>
        ) : (
          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Region</span>
            <select
              value={query.regionId ?? ''}
              onChange={(e) => update({ regionId: e.target.value || null })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* Only Regions the caller can read are offered. The option list
                * is built from the same RLS-scoped query as the table. */}
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
        )}

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Show</span>
          <select
            value={query.attention}
            onChange={(e) => update({ attention: e.target.value as StationQuery['attention'] })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All Stations</option>
            <option value="overdue">With overdue assets</option>
            <option value="unresolved">With unresolved mapping</option>
          </select>
        </label>

        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
      </DataToolbar>

      {state.status === 'loading' ? <LoadingState label="Loading Stations" /> : null}
      {state.status === 'unconfigured' ? (
        <NotImplemented feature="Stations" phase="waiting on database configuration" />
      ) : null}
      {state.status === 'error' ? <ErrorState message={state.message} onRetry={reload} /> : null}

      {/* The three zero-row answers are genuinely different and never share a
        * rendering: nothing exists, nothing matches, or the query failed. */}
      {state.status === 'ready' && rows.length === 0 && state.data.filtered ? (
        <NoResultsState onClear={clearFilters} />
      ) : null}
      {state.status === 'ready' && rows.length === 0 && !state.data.filtered ? (
        <EmptyState
          title="No Stations recorded yet"
          description="Stations appear here once the source workbooks have been imported. Nothing has been imported yet."
        />
      ) : null}

      {state.status === 'ready' && rows.length > 0 ? (
        <>
          <TableScroll label="Stations">
            <DataTable caption="Stations with their Region, Unit counts and compliance state">
              <TableHead>
                <TableRow>
                  <SortableHeader sort={sortFor('name')} onSort={() => toggleSort('name')}>
                    Station
                  </SortableHeader>
                  <SortableHeader sort={sortFor('region')} onSort={() => toggleSort('region')}>
                    Region
                  </SortableHeader>
                  <SortableHeader align="right" sort={sortFor('units')} onSort={() => toggleSort('units')}>
                    Units
                  </SortableHeader>
                  <SortableHeader align="right" sort={sortFor('assets')} onSort={() => toggleSort('assets')}>
                    Assets
                  </SortableHeader>
                  <SortableHeader align="right" sort={sortFor('overdue')} onSort={() => toggleSort('overdue')}>
                    Overdue
                  </SortableHeader>
                  <SortableHeader
                    align="right"
                    sort={sortFor('approaching_due')}
                    onSort={() => toggleSort('approaching_due')}
                  >
                    Due ≤60d
                  </SortableHeader>
                  <SortableHeader
                    align="right"
                    sort={sortFor('unresolved_mapping')}
                    onSort={() => toggleSort('unresolved_mapping')}
                  >
                    Unresolved
                  </SortableHeader>
                  <SortableHeader>Bay status</SortableHeader>
                  <SortableHeader>Attention</SortableHeader>
                </TableRow>
              </TableHead>
              <TableBody>
                {rows.map((station) => (
                  <TableRow key={station.station_id}>
                    <RowHeaderCell>
                      <EntityLink to={`/stations/${station.station_id}`}>
                        {/* Arabic names render direction-aware and are never
                          * truncated into ambiguity — the table scrolls. */}
                        <EntityName name={station.station_name} />
                      </EntityLink>
                    </RowHeaderCell>
                    <TableCell>{station.region_name}</TableCell>
                    <TableCell align="right" numeric><Count value={station.units} /></TableCell>
                    <TableCell align="right" numeric><Count value={station.assets} /></TableCell>
                    <TableCell align="right" numeric><Count value={station.overdue} tone="overdue" /></TableCell>
                    <TableCell align="right" numeric>
                      <Count value={station.approaching_due} tone="due" />
                    </TableCell>
                    <TableCell align="right" numeric>
                      <Count value={station.unresolved_mapping} tone="unmapped" />
                    </TableCell>
                    {/* A NULL bay status is shown as "not recorded", never as
                      * "N/A", "Unknown", "-" or 0 (§11.5). */}
                    <TableCell><ValueOrNull value={station.bay_status} /></TableCell>
                    <TableCell>
                      <AttentionBadge overdue={station.overdue} unresolved={station.unresolved_mapping} />
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </DataTable>
          </TableScroll>

          <nav
            aria-label="Stations pagination"
            className="flex flex-wrap items-center justify-between gap-2 text-sm"
          >
            {/* The total is the caller's own total, computed under RLS. */}
            <p className="text-muted-foreground" aria-live="polite">
              Showing <span className="tabular">{range}</span> Stations
            </p>
            <div className="flex items-center gap-1.5">
              <Button
                variant="outline"
                size="sm"
                className="h-7"
                disabled={effective.page === 0}
                onClick={() => setQuery((p) => ({ ...p, page: Math.max(0, p.page - 1) }))}
              >
                <ChevronLeft className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
                Previous
              </Button>
              <span className="tabular px-1 text-xs text-muted-foreground">
                Page {effective.page + 1} of {pages}
              </span>
              <Button
                variant="outline"
                size="sm"
                className="h-7"
                disabled={effective.page + 1 >= pages}
                onClick={() => setQuery((p) => ({ ...p, page: p.page + 1 }))}
              >
                Next
                <ChevronRight className="ml-1 h-3.5 w-3.5" aria-hidden="true" />
              </Button>
            </div>
          </nav>
        </>
      ) : null}
    </div>
  )
}
