import { Fragment, useCallback, useState, type ReactNode } from 'react'
import { ChevronDown, ChevronLeft, ChevronRight } from 'lucide-react'

import {
  DataTable, RowHeaderCell, SortableHeader, TableBody, TableCell, TableHead, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { EmptyState, ErrorState, LoadingState, NoResultsState, NotImplemented } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import { FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { pageCount } from '@/features/hierarchy/useHierarchy'
import type { Loadable } from '@/features/hierarchy/useHierarchy'


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
  const [open, setOpen] = useState<Set<string>>(() => new Set())
  const toggle = useCallback((key: string) => {
    setOpen((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      return next
    })
  }, [])

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

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <TableScroll label={label}>
        <DataTable className="responsive-records" caption={`${label}, with mapping state and calibration status`}>
          <TableHead>
            <TableRow>
              <SortableHeader className="w-8">
                <span className="sr-only">Expand technical record</span>
              </SortableHeader>
              {columns.map((c) => (
                <SortableHeader
                  key={c.key}
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
              const isOpen = open.has(key)
              return (
                <Fragment key={key}>
                  <TableRow>
                    <TableCell className="w-8" dataLabel="Details">
                      <button
                        type="button"
                        onClick={() => toggle(key)}
                        aria-expanded={isOpen}
                        aria-controls={`srv-detail-${key}`}
                        className="flex h-5 w-5 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground"
                      >
                        {isOpen ? (
                          <ChevronDown className="h-3.5 w-3.5" aria-hidden="true" />
                        ) : (
                          <ChevronRight className="h-3.5 w-3.5" aria-hidden="true" />
                        )}
                        <span className="sr-only">
                          {isOpen ? 'Hide' : 'Show'} the full technical record
                        </span>
                      </button>
                    </TableCell>
                    {columns.map((c) =>
                      c.rowHeader ? (
                        <RowHeaderCell key={c.key} dataLabel={c.header}>{c.render(row)}</RowHeaderCell>
                      ) : (
                        <TableCell key={c.key} align={c.align} numeric={c.numeric} dataLabel={c.header}>
                          {c.render(row)}
                        </TableCell>
                      ),
                    )}
                  </TableRow>
                  {isOpen ? (
                    <tr id={`srv-detail-${key}`} className="border-b bg-muted/30">
                      <td colSpan={columns.length + 1} className="px-[--table-cell-x] py-2.5">
                        <FactGrid>{detail(row)}</FactGrid>
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
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
          <span className="tabular px-1 text-xs text-muted-foreground">
            Page {page + 1} of {pages}
          </span>
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
    </div>
  )
}

