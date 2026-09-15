import { cn } from '@/lib/utils'

import { NullValue } from './NullValue'

/**
 * Arabic and mixed-direction display (CLAUDE.md §11.3, prompt §18).
 *
 * The application chrome stays LTR. Individual VALUES decide their own
 * direction: `dir="auto"` makes the browser read the first strong character, so
 * `الماظة 1` lays out right-to-left inside an otherwise left-to-right table
 * cell, and `EKC/DXB/MGNC/275` stays left-to-right beside it.
 *
 * `unicode-bidi: isolate` is what stops a mixed value from reordering the text
 * around it — without it an Arabic station name can visually swallow the comma
 * or identifier that follows it.
 */
export function EntityName({
  name,
  className,
  label,
}: {
  name: string | null | undefined
  className?: string
  label?: string
}) {
  if (name === null || name === undefined || name.trim() === '') {
    return <NullValue label={label ?? 'name not recorded'} />
  }
  return (
    <span dir="auto" className={cn('[unicode-bidi:isolate]', className)}>
      {name}
    </span>
  )
}

/**
 * A technical identifier: serial, part number, job number, warehouse code.
 *
 * Monospaced and tabular so a transposed digit is visible and columns align.
 * Never truncated into ambiguity — a half-shown serial is worse than a wrapped
 * one, so it wraps on the boundary instead of ellipsing.
 */
export function Identifier({
  value,
  className,
  label,
}: {
  value: string | null | undefined
  className?: string
  label?: string
}) {
  if (value === null || value === undefined || value.trim() === '') {
    return <NullValue label={label ?? 'no identifier recorded'} />
  }
  return (
    // No `break-all`: inside a table the cell is nowrap and the identifier
    // extends the column, so the region scrolls rather than the row growing.
    // It is never ellipsed — half a serial is worse than a wide column.
    <span dir="ltr" className={cn('font-technical [unicode-bidi:isolate]', className)}>
      {value}
    </span>
  )
}
