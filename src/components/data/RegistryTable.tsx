import { useState, type ReactNode } from 'react'
import { ChevronLeft, ChevronRight, Eye } from 'lucide-react'

import {
  DataTable, RowHeaderCell, SortableHeader, TableBody, TableCell, TableHead, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { EmptyState, ErrorState, LoadingState, NoResultsState, NotImplemented } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { pageCount } from '@/features/hierarchy/useHierarchy'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import { RecordDetailsDialog } from './RecordDetailsDialog'


/**
 * The dense registry table: server-sorted, server-paged, with expand-in-place
 * detail. Shared by every company-wide asset registry.
 *
 * One renderer so they never drift: the loading, empty, filtered-empty and
 * error states, the sort affordance, the detail disclosure and the pagination
 * behave identically on installed SRVs, warehouse stock, storage vessels and
 * recovery tanks. The COLUMNS differ, because the assets differ — warehouse
 * stock has no hierarchy, and a recovery tank has no SRV relationship, and
 * neither is given a fake column to make the tables look symmetrical.
 */

/** A page of rows plus the caller's RLS-scoped total. */
export interface RegistryPage<T> {
  rows: T[]
  total: number
  /** True when records exist for this caller but none match the filters. */
  filtered: boolean
}

export interface RegistryColumn<T> {
  key: string
  header: string
  align?: 'left' | 'right'
  numeric?: boolean
  rowHeader?: boolean
  /** Sort key understood by the query; omit for a non-sortable column. */
  sort?: string
  render: (row: T) => ReactNode
}

export function RegistryTable<T>({
  label,
  state,
  reload,
  columns,
  rowKey,
  detail,
  sort,
  direction,
  onSort,
  page,
  pageSize,
  onPage,
  onClearFilters,
  emptyTitle,
  emptyDescription,
  errorTitle,
  footnote,
}: {
  label: string
  state: Loadable<RegistryPage<T>>
  reload: () => void
  columns: RegistryColumn<T>[]
  rowKey: (row: T) => string
  detail: (row: T) => ReactNode
  sort: string
  direction: 'asc' | 'desc'
  onSort: (key: string) => void
  page: number
  pageSize: number
  onPage: (page: number) => void
  onClearFilters: () => void
  emptyTitle: string
  emptyDescription: string
  errorTitle: string
  footnote?: ReactNode
}) {
  const [selected, setSelected] = useState<T | null>(null)

  if (state.status === 'loading') return <LoadingState label={`Loading ${label}`} />
  if (state.status === 'unconfigured')
    return <NotImplemented feature={label} phase="waiting on database configuration" />
  // A query failure is never an empty table and never a zero count.
  if (state.status === 'error') return <ErrorState title={errorTitle} message={state.message} onRetry={reload} />

  const { rows, total, filtered } = state.data
  if (rows.length === 0 && filtered) return <NoResultsState onClear={onClearFilters} />
  if (rows.length === 0) return <EmptyState title={emptyTitle} description={emptyDescription} />

  const pages = pageCount(total, pageSize)
  const first = page * pageSize + 1
  // Registry rows are a scanning surface, not the entire record. Keep the
  // identifying columns plus the final operational state; the dialog owns the
  // complete technical record.
  const visibleColumns = columns.slice(0, 8)

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <TableScroll label={label}>
        <DataTable className="responsive-records compact-records" caption={`${label}, with mapping state and calibration status`}>
          <TableHead>
            <TableRow>
              <SortableHeader className="w-8">
                <span className="sr-only">Expand technical record</span>
              </SortableHeader>
              {columns.map((c) => (
                <SortableHeader
                  key={c.key}
                  className={visibleColumns.includes(c) ? undefined : 'hidden'}
                  align={c.align}
                  sort={c.sort ? (sort === c.sort ? direction : null) : undefined}
                  onSort={c.sort ? () => onSort(c.sort!) : undefined}
                >
                  {c.header}
                </SortableHeader>
              ))}
            </TableRow>
          </TableHead>
          <TableBody>
            {rows.map((row) => {
              const key = rowKey(row)
              return (
                  <TableRow key={key} onClick={() => setSelected(row)} className="cursor-pointer">
                    <TableCell className="w-8" dataLabel="Details">
                      <button
                        type="button"
                        onClick={(event) => {
                          event.stopPropagation()
                          setSelected((current) => current && rowKey(current) === key ? null : row)
                        }}
                        aria-expanded={selected !== null && rowKey(selected) === key}
                        className="flex h-5 w-5 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground"
                      >
                        <Eye className="h-3.5 w-3.5" aria-hidden="true" />
                        <span className="sr-only">
                          {selected !== null && rowKey(selected) === key
                            ? 'Hide the full technical record'
                            : 'Show the full technical record'}
                        </span>
                      </button>
                    </TableCell>
                    {columns.map((c) => {
                      const hidden = !visibleColumns.includes(c)
                      return c.rowHeader ? (
                        <RowHeaderCell key={c.key} className={hidden ? 'hidden' : undefined} dataLabel={c.header}>{c.render(row)}</RowHeaderCell>
                      ) : (
                        <TableCell key={c.key} className={hidden ? 'hidden' : undefined} align={c.align} numeric={c.numeric} dataLabel={c.header}>
                          {c.render(row)}
                        </TableCell>
                      )
                    })}
                  </TableRow>
              )
            })}
          </TableBody>
        </DataTable>
      </TableScroll>

      <nav aria-label={`${label} pagination`} className="flex flex-wrap items-center justify-between gap-2 text-sm">
        {/* The total is the caller's own, computed under RLS. */}
        <p className="text-muted-foreground" aria-live="polite">
          Showing{' '}
          <span className="tabular">
            {first.toLocaleString()}–{(first + rows.length - 1).toLocaleString()} of {total.toLocaleString()}
          </span>
        </p>
        <div className="flex items-center gap-1.5">
          <Button variant="outline" size="sm" className="h-7" disabled={page === 0} onClick={() => onPage(page - 1)}>
            <ChevronLeft className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Previous
          </Button>
          <label className="flex items-center gap-1 text-xs text-muted-foreground">
            <span>Page</span>
            <select
              aria-label="Page number"
              value={page}
              onChange={(event) => onPage(Number(event.target.value))}
              className="h-7 rounded border bg-background px-1.5 text-foreground"
            >
              {Array.from({ length: pages }, (_, index) => (
                <option key={index} value={index}>{index + 1}</option>
              ))}
            </select>
            <span>of {pages}</span>
          </label>
          <Button
            variant="outline"
            size="sm"
            className="h-7"
            disabled={page + 1 >= pages}
            onClick={() => onPage(page + 1)}
          >
            Next
            <ChevronRight className="ml-1 h-3.5 w-3.5" aria-hidden="true" />
          </Button>
        </div>
      </nav>
      {footnote ? <p className="text-sm text-muted-foreground">{footnote}</p> : null}
      <RecordDetailsDialog
        open={selected !== null}
        title={`${label} record`}
        description="Complete technical details"
        onClose={() => setSelected(null)}
      >
        {selected ? <FactGrid>{detail(selected)}</FactGrid> : null}
      </RecordDetailsDialog>
    </div>
  )
}
