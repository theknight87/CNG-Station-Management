import { cn } from '@/lib/utils'

/**
 * How a missing value is shown (CLAUDE.md §11.5, principles #3, #14, #19).
 *
 * NULL is valid data. It is NOT an error, NOT an incomplete record, and NOT a
 * failed inspection. It is rendered quietly and never replaced by `N/A`,
 * `Unknown`, `-`, `0` or any other invented stand-in.
 *
 * The visible glyph is an em dash, which reads as "nothing recorded" to a
 * sighted user; screen readers get the real words through the accessible name,
 * because an unannounced dash is silence.
 */
export function NullValue({ label = 'not recorded', className }: { label?: string; className?: string }) {
  return (
    // NOT text-muted-foreground/60. Browser-measured, that came to 2.51:1
    // against the working ground - under the 4.5:1 AA floor for a marker that
    // carries meaning. The solid token is 5.17:1 and still reads as quiet.
    <span className={cn('select-none text-muted-foreground', className)} title={label}>
      <span aria-hidden="true">—</span>
      <span className="sr-only">{label}</span>
    </span>
  )
}

/**
 * Renders a value, or the quiet null marker when it is absent.
 *
 * An empty string counts as absent: a blank source cell and a NULL are the same
 * fact — the source said nothing.
 */
export function ValueOrNull({
  value,
  className,
  label,
}: {
  value: string | number | null | undefined
  className?: string
  label?: string
}) {
  if (value === null || value === undefined || (typeof value === 'string' && value.trim() === '')) {
    return <NullValue label={label} className={className} />
  }
  return <span className={className}>{value}</span>
}
