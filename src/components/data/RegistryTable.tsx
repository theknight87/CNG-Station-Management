import { useState, type ReactNode } from 'react'
import { Eye } from 'lucide-react'

import { cn } from '@/lib/utils'
import {
  DataTable, RowHeaderCell, SortableHeader, TableBody, TableCell, TableHead, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { EmptyState, ErrorState, LoadingState, NoResultsState, NotImplemented } from '@/components/states/AppStates'
import { FactGrid } from '@/features/hierarchy/HierarchyPieces'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import { RecordDetailsDialog } from './RecordDetailsDialog'
import { RecordAdminTools } from '@/features/record-tools/RecordAdminTools'
import type { RecordRef } from '@/features/record-tools/recordTools'
import { PaginationControls } from './PaginationControls'


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
  align?: 'left' | 'center' | 'right'
  numeric?: boolean
  rowHeader?: boolean
  /** Sort key understood by the query; omit for a non-sortable column. */
  sort?: string
  render: (row: T) => ReactNode
}

/** Row tick boxes for bulk actions. The caller owns the set; ticks cover the rows on this page. */
export interface RegistrySelection<T> {
  selected: Set<string>
  onChange: (next: Set<string>) => void
  /** A row that cannot take part in any bulk action shows no box. */
  selectable?: (row: T) => boolean
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
  record,
  extra,
  selection,
  openKey,
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
  /** The editable record behind a row, for admin editing and photos. Omit for read-only registries. */
  record?: (row: T) => RecordRef | null
  /** Extra dialog content (workflow actions, history). `done` closes the dialog and reloads. */
  extra?: (row: T, done: () => void) => ReactNode
  /** Present = a tick-box column for bulk actions. */
  selection?: RegistrySelection<T>
  /** Open this row's details once it is on screen (a deep link from the global SRV search). */
  openKey?: string | null
}) {
  const [selected, setSelected] = useState<T | null>(null)
  const [autoOpened, setAutoOpened] = useState<string | null>(null)
  if (openKey && openKey !== autoOpened && state.status === 'ready') {
    const hit = state.data.rows.find((r) => rowKey(r) === openKey)
    if (hit) { setAutoOpened(openKey); setSelected(hit) }
  }
  // The last result shown. While the next one loads (a tile, filter, sort or page change) the table keeps it on
  // screen, dimmed and marked busy, instead of blanking to a loading screen (owner report 2026-10-02).
  const [shown, setShown] = useState<RegistryPage<T> | null>(state.status === 'ready' ? state.data : null)
  if (state.status === 'ready' && state.data !== shown) setShown(state.data)
  const refreshing = state.status === 'loading' && shown !== null

  if (state.status === 'loading' && !refreshing) return <LoadingState label={`Loading ${label}`} />
  if (state.status === 'unconfigured')
    return <NotImplemented feature={label} phase="waiting on database configuration" />
  // A query failure is never an empty table and never a zero count.
  if (state.status === 'error') return <ErrorState title={errorTitle} message={state.message} onRetry={reload} />

  const { rows, total, filtered } = state.status === 'ready' ? state.data : shown!
  if (rows.length === 0 && filtered) return <NoResultsState onClear={onClearFilters} />
  if (rows.length === 0) return <EmptyState title={emptyTitle} description={emptyDescription} />

  // Registry rows are a scanning surface, not the entire record. Keep the
  // identifying columns plus the final operational state; the dialog owns the
  // complete technical record.
  const visibleColumns = columns.slice(0, 8)
  const canPick = (row: T) => selection !== undefined && (selection.selectable ? selection.selectable(row) : true)
  const pickable = rows.filter(canPick).map(rowKey)
  const allPicked = pickable.length > 0 && pickable.every((k) => selection!.selected.has(k))
  const toggle = (key: string) => {
    if (!selection) return
    const next = new Set(selection.selected)
    if (next.has(key)) next.delete(key)
    else next.add(key)
    selection.onChange(next)
  }

  return (
    <div className="flex min-w-0 flex-col gap-2" aria-busy={refreshing}>
      {refreshing ? <p role="status" className="sr-only">Updating {label}…</p> : null}
      <div className={cn('transition-opacity', refreshing && 'pointer-events-none opacity-60')}>
      <TableScroll label={label}>
        <DataTable className="responsive-records compact-records" caption={`${label}, with mapping state and calibration status`}>
          <TableHead>
            <TableRow>
              {selection ? (
                <SortableHeader className="w-8">
                  <input type="checkbox" aria-label="Select all on this page" checked={allPicked} disabled={pickable.length === 0}
                         onChange={() => selection.onChange(allPicked ? new Set() : new Set(pickable))} />
                </SortableHeader>
              ) : null}
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
                    {selection ? (
                      <TableCell className="w-8" dataLabel="Select">
                        {canPick(row) ? (
                          // The whole cell toggles the box and never opens the record.
                          <label className="flex items-center" onClick={(event) => event.stopPropagation()}>
                            <input type="checkbox" aria-label="Select row" checked={selection.selected.has(key)} onChange={() => toggle(key)} />
                          </label>
                        ) : null}
                      </TableCell>
                    ) : null}
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
      </div>

      <PaginationControls label={label} page={page} pageSize={pageSize} total={total} visibleRows={rows.length} onPage={onPage} />
      <RecordDetailsDialog
        open={selected !== null}
        title={`${label} record`}
        description="Complete technical details"
        onClose={() => setSelected(null)}
      >
        {selected ? <FactGrid>{detail(selected)}</FactGrid> : null}
        {selected && extra ? <div key={rowKey(selected)}>{extra(selected, () => { setSelected(null); reload() })}</div> : null}
        {selected && record && record(selected) ? (
          <RecordAdminTools key={record(selected)!.id} record={record(selected)!} onSaved={reload} />
        ) : null}
      </RecordDetailsDialog>
    </div>
  )
}
