import type { ReactNode } from 'react'
import { AlertCircle, Construction, Inbox, Loader2, SearchX, ShieldAlert } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

/**
 * The five states every screen must handle (CLAUDE.md §11.3, prompt §20).
 *
 * They are deliberately distinguishable from one another. The failure this
 * guards against is the common one: an unimplemented feature, a permission
 * refusal and a genuinely empty table all rendering as the same blank panel,
 * so a user cannot tell "nothing here" from "not allowed" from "not built".
 */

function Frame({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div
      className={cn(
        'flex flex-col items-center justify-center gap-2 rounded border border-dashed px-6 py-10 text-center',
        className,
      )}
    >
      {children}
    </div>
  )
}

/** Restrained, and sized to the region it replaces so layout does not shift. */
export function LoadingState({ label = 'Loading', className }: { label?: string; className?: string }) {
  return (
    <div
      role="status"
      aria-live="polite"
      className={cn('flex items-center justify-center gap-2 py-10 text-sm text-muted-foreground', className)}
    >
      <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
      <span>{label}…</span>
    </div>
  )
}

/**
 * No records exist. DISTINCT from "no results match your filters" — conflating
 * them sends an engineer hunting for data that was merely filtered out.
 */
export function EmptyState({
  title = 'No records',
  description,
  action,
}: {
  title?: string
  description?: string
  action?: ReactNode
}) {
  return (
    <Frame className="border-border text-muted-foreground">
      <Inbox className="h-5 w-5" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">{title}</p>
      {description ? <p className="max-w-md text-sm">{description}</p> : null}
      {action}
    </Frame>
  )
}

/** Records exist; the current filters exclude them all. */
export function NoResultsState({ onClear }: { onClear?: () => void }) {
  return (
    <Frame className="border-border text-muted-foreground">
      <SearchX className="h-5 w-5" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">No results match these filters</p>
      <p className="max-w-md text-sm">Records exist, but none match the current filter and search terms.</p>
      {onClear ? (
        <Button variant="outline" size="sm" onClick={onClear}>
          Clear filters
        </Button>
      ) : null}
    </Frame>
  )
}

/** A real failure. `onRetry` appears ONLY when a retry genuinely exists. */
export function ErrorState({
  title = 'Could not load this data',
  message,
  onRetry,
}: {
  title?: string
  message?: string
  onRetry?: () => void
}) {
  return (
    <Frame className="border-destructive/30 bg-destructive/5">
      <AlertCircle className="h-5 w-5 text-destructive" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">{title}</p>
      {message ? <p className="max-w-md text-sm text-muted-foreground">{message}</p> : null}
      {onRetry ? (
        <Button variant="outline" size="sm" onClick={onRetry}>
          Try again
        </Button>
      ) : null}
    </Frame>
  )
}

/**
 * Refused by authorization. Visually and semantically unlike empty data.
 *
 * This is UX only. The database refused, or would refuse, the read regardless
 * of what is rendered here (CLAUDE.md §10).
 */
export function PermissionDenied({
  what = 'this area',
  detail,
}: {
  what?: string
  detail?: string
}) {
  return (
    <Frame className="border-border bg-muted/40">
      <ShieldAlert className="h-5 w-5 text-muted-foreground" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">You do not have access to {what}</p>
      <p className="max-w-md text-sm text-muted-foreground">
        {detail ?? 'Access is granted by an administrator. Ask one to review your role or region access.'}
      </p>
    </Frame>
  )
}

/**
 * An entity that is not there.
 *
 * Deliberately says "does not exist, OR is outside your access" and does not
 * distinguish the two. Telling an unauthorized caller that a Station exists
 * but is forbidden confirms its existence, which is precisely what the
 * row-level policy is there to withhold (CLAUDE.md §10). PermissionDenied is
 * for a whole AREA the role cannot use; this is for one record.
 */
export function NotFound({ what, detail }: { what: string; detail?: string }) {
  return (
    <Frame className="border-border bg-muted/30">
      <SearchX className="h-5 w-5 text-muted-foreground" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">{what} not found</p>
      <p className="max-w-md text-sm text-muted-foreground">
        {detail ?? `This ${what} does not exist, or it is outside the records you are authorized for.`}
      </p>
    </Frame>
  )
}

/**
 * A route that exists but whose feature is not built yet.
 *
 * It must NOT look like a successful empty result. It names the phase that will
 * build it, and it shows no fabricated counts, charts or records.
 */
export function NotImplemented({
  feature,
  phase,
  children,
}: {
  feature: string
  phase: string
  children?: ReactNode
}) {
  return (
    <Frame className="border-border bg-muted/30">
      <Construction className="h-5 w-5 text-muted-foreground" aria-hidden="true" />
      <p className="text-sm font-medium text-foreground">{feature} is not built yet</p>
      <p className="max-w-lg text-sm text-muted-foreground">
        This route and its navigation exist so the shell is complete. {feature} itself is {phase}.
        Nothing is shown here because there is no real data to show — no placeholder figures are
        invented to fill the space.
      </p>
      {children}
    </Frame>
  )
}
