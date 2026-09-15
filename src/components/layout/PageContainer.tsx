import type { ReactNode } from 'react'

import { EntityName } from '@/components/data/TechnicalText'
import { cn } from '@/lib/utils'

/**
 * Page primitives (prompt §12).
 *
 * Padding is deliberately modest — 16px, not 32px. Whitespace that costs a row
 * of data is whitespace this product cannot afford (§11.4).
 */

export function PageContainer({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('flex min-h-full flex-col gap-3 p-3 sm:p-4', className)}>{children}</div>
}

/**
 * Page title row. `title` may be an Arabic entity name, so it is rendered
 * direction-aware when `isEntity` is set.
 */
export function PageHeader({
  title,
  description,
  isEntity = false,
  actions,
}: {
  title: string
  description?: string
  isEntity?: boolean
  actions?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-2">
      <div className="min-w-0">
        <h1 className="truncate text-base font-semibold tracking-tight">
          {isEntity ? <EntityName name={title} /> : title}
        </h1>
        {description ? <p className="mt-0.5 text-sm text-muted-foreground">{description}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
    </div>
  )
}

export function PageActions({ children }: { children: ReactNode }) {
  return <div className="flex flex-wrap items-center gap-2">{children}</div>
}

export function SectionHeader({
  title,
  description,
  actions,
}: {
  title: string
  description?: string
  actions?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-b pb-1.5">
      <div className="min-w-0">
        <h2 className="truncate text-sm font-semibold tracking-tight">{title}</h2>
        {description ? <p className="text-xs text-muted-foreground">{description}</p> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-2">{actions}</div> : null}
    </div>
  )
}

/**
 * The filter/search bar that sits above a technical table.
 *
 * It is a first-class element, not an afterthought: filtering by Region,
 * Station, status and due window is how this product is actually used
 * (§11.3), and ui-ux-pro-max flags "no filtering" as an anti-pattern for
 * operations software.
 */
export function DataToolbar({
  children,
  trailing,
  label,
  className,
}: {
  children?: ReactNode
  trailing?: ReactNode
  /** Names the search landmark. Required: two unnamed `search` landmarks on a
   * page are indistinguishable to anyone navigating by landmark. */
  label: string
  className?: string
}) {
  return (
    <div
      role="search"
      aria-label={label}
      className={cn(
        'flex flex-wrap items-center gap-2 rounded border bg-card px-2 py-1.5',
        className,
      )}
    >
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-2">{children}</div>
      {trailing ? <div className="flex shrink-0 items-center gap-2">{trailing}</div> : null}
    </div>
  )
}
