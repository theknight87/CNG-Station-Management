import { useId, useState, type ReactNode } from 'react'
import { SlidersHorizontal } from 'lucide-react'

import { EntityName } from '@/components/data/TechnicalText'
import { InfoTip } from '@/components/ui/InfoTip'
import { cn } from '@/lib/utils'

/**
 * Page primitives (prompt §12).
 *
 * Padding is deliberately modest — 16px, not 32px. Whitespace that costs a row
 * of data is whitespace this product cannot afford (§11.4).
 */

export function PageContainer({ children, className }: { children: ReactNode; className?: string }) {
  return <div className={cn('flex min-h-0 flex-col gap-3 p-3 sm:p-4', className)}>{children}</div>
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
  leading,
}: {
  title: string
  description?: ReactNode
  isEntity?: boolean
  /** Shown before the title, e.g. the Region's colour mark. */
  leading?: ReactNode
  actions?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-start justify-between gap-2">
      <div className="min-w-0">
        <div className="flex items-center gap-1.5">
          <h1 className="flex items-center gap-2 text-balance break-words text-xl font-semibold tracking-tight">
            {leading}
            {isEntity ? <EntityName name={title} /> : title}
          </h1>
          {/* A written explanation stays behind an (i) (owner request 2026-09-29); anything else (e.g. a Region chip)
            * is content and shows under the title. */}
          {typeof description === 'string' ? <InfoTip label={`About ${title}`}>{description}</InfoTip> : null}
        </div>
        {description && typeof description !== 'string' ? <div className="mt-0.5 text-sm text-muted-foreground">{description}</div> : null}
      </div>
      {actions ? <div className="flex min-w-0 max-w-full flex-wrap items-center gap-2">{actions}</div> : null}
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
  id,
}: {
  title: string
  description?: string
  actions?: ReactNode
  /** Lets an enclosing `section` use `aria-labelledby` on the VISIBLE heading,
   * rather than duplicating it in a screen-reader-only one. */
  id?: string
}) {
  return (
    <div className="flex flex-wrap items-center justify-between gap-2 border-b pb-1.5">
      <div className="min-w-0">
        <h2 id={id} className="text-balance truncate text-base font-semibold tracking-tight">{title}</h2>
        {description ? <p className="text-sm text-muted-foreground">{description}</p> : null}
      </div>
      {actions ? <div className="flex min-w-0 max-w-full flex-wrap items-center gap-2">{actions}</div> : null}
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
  filtersActive,
}: {
  children?: ReactNode
  trailing?: ReactNode
  /** Names the search landmark. Required: two unnamed `search` landmarks on a
   * page are indistinguishable to anyone navigating by landmark. */
  label: string
  className?: string
  /** Opts the toolbar into the PHONE layout: below `md` only its first control
   * (the search box) shows, and the rest sit behind a Filters toggle — at 390px
   * a full filter row fills the first screen before a single record does. The
   * flag says whether any filter is applied, so a closed panel still tells the
   * user the table is narrowed. Omit it and the toolbar never collapses. */
  filtersActive?: boolean
}) {
  const panelId = useId()
  const [open, setOpen] = useState(false)
  const collapsible = filtersActive !== undefined
  const collapsed = collapsible && !open

  return (
    <div
      role="search"
      aria-label={label}
      className={cn(
        'flex flex-wrap items-center gap-2 rounded border bg-card px-2 py-1.5',
        className,
      )}
    >
      <div
        id={panelId}
        className={cn(
          'flex min-w-0 flex-1 flex-wrap items-center gap-2',
          // Every control except the first (search) and the toggle itself.
          // Written out in full: Tailwind only generates classes it finds as literals.
          collapsible && 'max-md:[&>*:not(:first-child):not([data-filter-toggle])]:order-2',
          collapsed && 'max-md:[&>*:not(:first-child):not([data-filter-toggle])]:hidden',
        )}
      >
        {children}
        {collapsible ? (
          <button
            type="button"
            data-filter-toggle=""
            onClick={() => setOpen((v) => !v)}
            aria-expanded={open}
            aria-controls={panelId}
            className="order-1 inline-flex h-7 shrink-0 items-center gap-1.5 rounded border bg-background px-2 text-sm text-foreground hover:bg-accent/60 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring md:hidden"
          >
            <SlidersHorizontal className="h-3.5 w-3.5" aria-hidden="true" />
            {open ? 'Hide filters' : 'Filters'}
            {filtersActive ? (
              <span className="rounded bg-brand-strong/10 px-1 text-xs font-medium text-brand-strong">applied</span>
            ) : null}
          </button>
        ) : null}
      </div>
      {trailing ? (
        <div className={cn('flex shrink-0 items-center gap-2', collapsed && 'max-md:hidden')}>{trailing}</div>
      ) : null}
    </div>
  )
}

