import { cn } from '@/lib/utils'
import { STATUS_SPECS, type StatusKind } from './statusSemantics'

/**
 * Renders a status. The vocabulary itself lives in `statusSemantics.ts`; this
 * file only draws it.
 *
 * The icon and the visually-hidden description are not decoration: they are
 * what makes the status readable without colour.
 */
export function StatusBadge({
  kind,
  label,
  description,
  className,
}: {
  kind: StatusKind
  /** Override the wording; the icon and semantics are unchanged. */
  label?: string
  /**
   * Override the screen-reader description.
   *
   * Required when a badge borrows a KIND for its colour and icon but means
   * something else. A mapping state rendered with the `ok` kind would
   * otherwise be announced as "within its calibration or inspection date" -
   * describing a compliance state to someone reading a mapping state.
   */
  description?: string
  className?: string
}) {
  const spec = STATUS_SPECS[kind]
  const { Icon } = spec

  return (
    <span
      className={cn(
        'inline-flex items-center gap-1 whitespace-nowrap rounded border px-1.5 py-0.5 text-xs font-medium',
        spec.className,
        className,
      )}
    >
      <Icon className="h-3 w-3 shrink-0" aria-hidden="true" />
      <span>{label ?? spec.label}</span>
      <span className="sr-only"> — {description ?? spec.description}</span>
    </span>
  )
}
