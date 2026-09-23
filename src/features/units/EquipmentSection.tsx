import { Fragment, useCallback, useState, type ReactNode } from 'react'
import { ChevronDown, ChevronRight } from 'lucide-react'
import { RecordAdminTools } from '@/features/record-tools/RecordAdminTools'
import type { RecordRef } from '@/features/record-tools/recordTools'

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
import { EmptyState, ErrorState, LoadingState, NotImplemented } from '@/components/states/AppStates'
import { Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { cn } from '@/lib/utils'
import type { Loadable } from '@/features/hierarchy/useHierarchy'

/**
 * One equipment section of the Unit workspace.
 *
 * WHY A SHARED RENDERER. Seven tabs showing seven asset types would otherwise
 * be seven chances for "overdue" to look different, for a NULL to be drawn
 * differently, or for one tab to quietly render a failed query as an empty
 * list. The per-tab files supply columns and detail fields; the states and the
 * table behaviour are decided once, here.
 *
 * MASTER-DETAIL. A row expands IN PLACE rather than opening a drawer or a
 * modal. §22 requires that no verified source field becomes unreachable just
 * because it is not in the compact table, and §23 asks for the technical record
 * without losing Unit context — an inline disclosure does both, keeps working
 * at 390px, and avoids modal proliferation entirely.
 */

export interface Column<T> {
  header: string
  align?: 'left' | 'right'
  numeric?: boolean
  /** The identifying cell. Exactly one column should set this. */
  rowHeader?: boolean
  render: (row: T) => ReactNode
}

export function EquipmentSection<T>({
  title,
  state,
  reload,
  rowKey,
  columns,
  detail,
  emptyTitle,
  emptyDescription,
  errorTitle,
  footnote,
  record,
}: {
  title: string
  state: Loadable<T[]>
  reload: () => void
  rowKey: (row: T) => string
  columns: Column<T>[]
  /** The full technical record, shown when a row is expanded. */
  detail: (row: T) => ReactNode
  emptyTitle: string
  emptyDescription: string
  errorTitle: string
  footnote?: ReactNode
  /** The editable record behind a row, for admin editing and photos. */
  record?: (row: T) => RecordRef | null
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

  if (state.status === 'loading') return <LoadingState label={`Loading ${title}`} />
  if (state.status === 'unconfigured')
    return <NotImplemented feature={title} phase="waiting on database configuration" />
  // A failure is a failure. It is never an empty list, and never a zero.
  if (state.status === 'error') return <ErrorState title={errorTitle} message={state.message} onRetry={reload} />

  const rows = state.data
  if (rows.length === 0) {
    // Absence of a record is not missing data: a Unit with no Recovery Tank is
    // a complete record (principle #19). No empty slot is drawn for equipment
    // the schema does not say must exist.
    return <EmptyState title={emptyTitle} description={emptyDescription} />
  }

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <TableScroll label={title}>
        <DataTable caption={`${title} recorded for this Unit`}>
          <TableHead>
            <TableRow>
              <TableHeader className="w-8">
                <span className="sr-only">Expand technical record</span>
              </TableHeader>
              {columns.map((c) => (
                <TableHeader key={c.header} align={c.align}>
                  {c.header}
                </TableHeader>
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
                    <TableCell className="w-8">
                      <button
                        type="button"
                        onClick={() => toggle(key)}
                        aria-expanded={isOpen}
                        aria-controls={`detail-${key}`}
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
                        <RowHeaderCell key={c.header}>{c.render(row)}</RowHeaderCell>
                      ) : (
                        <TableCell key={c.header} align={c.align} numeric={c.numeric}>
                          {c.render(row)}
                        </TableCell>
                      ),
                    )}
                  </TableRow>
                  {isOpen ? (
                    <tr id={`detail-${key}`} className="border-b bg-muted/30">
                      <td colSpan={columns.length + 1} className="px-[--table-cell-x] py-2.5">
                        <FactGrid>{detail(row)}</FactGrid>
                        {record && record(row) ? <RecordAdminTools key={record(row)!.id} record={record(row)!} onSaved={reload} /> : null}
                      </td>
                    </tr>
                  ) : null}
                </Fragment>
              )
            })}
          </TableBody>
        </DataTable>
      </TableScroll>
      {footnote ? <p className={cn('text-sm text-muted-foreground')}>{footnote}</p> : null}
    </div>
  )
}

export { Fact }
