import type { ReactNode, ThHTMLAttributes } from 'react'
import { ArrowDown, ArrowUp, ChevronsUpDown } from 'lucide-react'

import { cn } from '@/lib/utils'

/**
 * Technical table foundation (prompt §13).
 *
 * Not a data grid — the real asset tables arrive in Prompts 8-20. These are the
 * primitives they will be built from, so density, sticky headers, overflow and
 * keyboard behaviour are decided once, here.
 *
 * Deliberate decisions:
 *
 * - **Rows do not become cards on mobile.** An engineering table compared across
 *   columns loses its meaning as a stack of cards. It scrolls horizontally
 *   instead, inside its own container, so the PAGE never scrolls sideways.
 * - **34px rows.** Dense enough to scan a station's worth of valves without
 *   scrolling; tall enough to hit with a mouse.
 * - **A real `<table>`.** Semantics carry the row/column relationship to screen
 *   readers; a div grid does not.
 */

/**
 * Owns the horizontal overflow so the page itself never scrolls sideways.
 *
 * `label` is required rather than defaulted: two scroll regions on one page
 * both announced as "Data table" is no better than none, and a screen-reader
 * user navigating by landmark needs to know WHICH table they have landed in.
 */
export function TableScroll({
  children,
  label,
  className,
}: {
  children: ReactNode
  label: string
  className?: string
}) {
  return (
    <div
      className={cn('relative w-full overflow-auto rounded border bg-card', className)}
      // A scrollable region must be reachable by keyboard, or its content is
      // unreachable for anyone not using a mouse.
      tabIndex={0}
      role="region"
      aria-label={`${label} — scrollable`}
    >
      {children}
    </div>
  )
}

export function DataTable({
  children,
  caption,
  className,
}: {
  children: ReactNode
  /** Describes the table for assistive technology. Visually hidden. */
  caption: string
  className?: string
}) {
  return (
    // `w-max min-w-full` is what keeps rows dense: the table takes its NATURAL
    // width and overflows into TableScroll, instead of compressing columns
    // until cells wrap and a 34px row becomes a 137px one. Browser-verified at
    // 1024px and 390px, where the squeezed version measured 137px.
    <table className={cn('w-max min-w-full border-collapse text-sm', className)}>
      <caption className="sr-only">{caption}</caption>
      {children}
    </table>
  )
}

/** Sticky so column meaning survives a long scroll. */
export function TableHead({ children }: { children: ReactNode }) {
  // Opaque, deliberately. A translucent or blurred sticky header is
  // glassmorphism (§11.4) and, worse, leaves column names unreadable over the
  // rows scrolling beneath them.
  return <thead className="sticky top-0 z-10 bg-muted shadow-[inset_0_-1px_0_hsl(var(--border))]">{children}</thead>
}

export function TableBody({ children }: { children: ReactNode }) {
  return <tbody>{children}</tbody>
}

export type SortDirection = 'asc' | 'desc' | null

/**
 * A sortable column header.
 *
 * `aria-sort` carries the state to assistive technology, and the arrow carries
 * it visually — the direction is never conveyed by styling alone.
 */
export function SortableHeader({
  children,
  sort,
  onSort,
  align = 'left',
  className,
  ...rest
}: {
  children: ReactNode
  sort?: SortDirection
  onSort?: () => void
  align?: 'left' | 'right'
} & ThHTMLAttributes<HTMLTableCellElement>) {
  const ariaSort = sort === 'asc' ? 'ascending' : sort === 'desc' ? 'descending' : 'none'
  const Arrow = sort === 'asc' ? ArrowUp : sort === 'desc' ? ArrowDown : ChevronsUpDown

  return (
    <th
      scope="col"
      aria-sort={onSort ? ariaSort : undefined}
      className={cn(
        'whitespace-nowrap border-b px-[--table-cell-x] py-[--table-cell-y] text-xs font-semibold uppercase tracking-wide text-muted-foreground',
        align === 'right' ? 'text-right' : 'text-left',
        className,
      )}
      {...rest}
    >
      {onSort ? (
        <button
          type="button"
          onClick={onSort}
          className={cn(
            'flex w-full items-center gap-1 rounded hover:text-foreground',
            align === 'right' && 'justify-end',
          )}
        >
          <span>{children}</span>
          <Arrow className={cn('h-3 w-3 shrink-0', sort ? 'opacity-100' : 'opacity-40')} aria-hidden="true" />
        </button>
      ) : (
        children
      )}
    </th>
  )
}

export function TableHeader({
  children,
  align = 'left',
  className,
  ...rest
}: { children: ReactNode; align?: 'left' | 'right' } & ThHTMLAttributes<HTMLTableCellElement>) {
  return (
    <SortableHeader align={align} className={className} {...rest}>
      {children}
    </SortableHeader>
  )
}

export function TableRow({
  children,
  selected = false,
  onClick,
  className,
}: {
  children: ReactNode
  selected?: boolean
  onClick?: () => void
  className?: string
}) {
  return (
    <tr
      // Selection is announced, not merely tinted.
      aria-selected={onClick ? selected : undefined}
      onClick={onClick}
      className={cn(
        'border-b last:border-b-0',
        onClick && 'cursor-pointer',
        selected ? 'bg-accent' : 'hover:bg-muted/50',
        className,
      )}
    >
      {children}
    </tr>
  )
}

export function TableCell({
  children,
  align = 'left',
  /** Numbers, pressures and dates line up when they share a tabular figure. */
  numeric = false,
  wrap = false,
  className,
}: {
  children: ReactNode
  align?: 'left' | 'right'
  numeric?: boolean
  /** Opt in to wrapping, for a genuinely long free-text column such as notes. */
  wrap?: boolean
  className?: string
}) {
  return (
    <td
      className={cn(
        'h-[--table-row-height] whitespace-nowrap px-[--table-cell-x] py-[--table-cell-y] align-middle',
        align === 'right' ? 'text-right' : 'text-left',
        numeric && 'tabular',
        wrap && 'whitespace-normal',
        className,
      )}
    >
      {children}
    </td>
  )
}

/** A row header — the identifying cell of a row, for screen-reader navigation. */
export function RowHeaderCell({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <th
      scope="row"
      className={cn(
        'h-[--table-row-height] whitespace-nowrap px-[--table-cell-x] py-[--table-cell-y] text-left align-middle font-normal',
        className,
      )}
    >
      {children}
    </th>
  )
}
