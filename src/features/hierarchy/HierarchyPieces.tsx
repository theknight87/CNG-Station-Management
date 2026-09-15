import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

import { StatusBadge } from '@/components/data/StatusBadge'
import { cn } from '@/lib/utils'

/**
 * Small pieces shared by the Region, Station and Unit screens, so the same
 * fact is drawn the same way on all three.
 */

/**
 * A count in a table cell.
 *
 * A zero is rendered in muted grey rather than black. That is NOT the
 * "unknown data" treatment (§11.5) — zero here is a measured fact, not a gap,
 * and it is still shown as a real `0`. It is muted only so that a column of
 * mostly-zeros does not out-shout the handful of non-zero numbers an engineer
 * is actually scanning for.
 */
export function Count({ value, tone = 'plain' }: { value: number; tone?: 'plain' | 'overdue' | 'due' | 'unmapped' }) {
  // Solid, not /60: a zero is a measured fact an engineer reads, and at 60%
  // opacity it measured 2.51:1 in the browser, below the AA floor. The solid
  // muted token is 5.17:1 and still recedes behind the non-zero numbers.
  if (value === 0) return <span className="tabular text-muted-foreground">0</span>
  const toneClass =
    tone === 'overdue'
      ? 'font-semibold text-status-overdue'
      : tone === 'due'
        ? 'font-medium text-status-due-soon'
        : tone === 'unmapped'
          ? 'text-status-unmapped'
          : ''
  return <span className={cn('tabular', toneClass)}>{value.toLocaleString()}</span>
}

/**
 * A station's or region's attention state, as one badge.
 *
 * Overdue outranks unresolved mapping: an overdue safety-critical valve is an
 * operational fact, while an unresolved mapping is missing evidence about
 * where an asset sits. Both are shown, but only one can lead.
 *
 * Note what this deliberately does NOT do: it never reports "healthy" in
 * Cargas green. Brand colour and compliance colour are separate systems, and
 * `ok` is a teal status token for exactly that reason.
 */
export function AttentionBadge({
  overdue,
  unresolved,
}: {
  overdue: number
  unresolved: number
}) {
  if (overdue > 0) return <StatusBadge kind="overdue" label={`${overdue.toLocaleString()} overdue`} />
  if (unresolved > 0) return <StatusBadge kind="unmapped" label={`${unresolved.toLocaleString()} unresolved`} />
  return <StatusBadge kind="ok" label="Nothing overdue" />
}

/** A labelled fact in a detail panel. Children render their own NULL state. */
export function Fact({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs uppercase tracking-wide text-muted-foreground">{label}</dt>
      <dd className="mt-0.5 truncate text-sm">{children}</dd>
    </div>
  )
}

export function FactGrid({ children }: { children: ReactNode }) {
  return <dl className="grid grid-cols-2 gap-x-4 gap-y-2.5 sm:grid-cols-3 lg:grid-cols-4">{children}</dl>
}

/**
 * A link that opens an entity. Styled with the brand's accessible derivative
 * (--brand-strong, 4.64:1 on the working ground) rather than the raw logo
 * green, which measures 3.46:1 and fails AA for body text.
 */
export function EntityLink({ to, children }: { to: string; children: ReactNode }) {
  return (
    <Link
      to={to}
      className="rounded font-medium text-brand-strong underline-offset-4 hover:underline"
    >
      {children}
    </Link>
  )
}
