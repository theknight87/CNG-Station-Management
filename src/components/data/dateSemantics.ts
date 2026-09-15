/**
 * Date precision vocabulary (CLAUDE.md principle #17, §11.5).
 *
 * Precision is explicit, and only `exact_date` may ever drive Days Left, Due
 * Today, a 7/15/30/60-day alert, or Overdue. A `year_only` value has no `value`
 * at all, so no component can render it as a calendar date even by accident.
 */

export type DatePrecision = 'exact_date' | 'year_only' | 'unknown' | 'invalid'

export interface PrecisionDate {
  /** ISO yyyy-mm-dd. Present ONLY when precision is exact_date. */
  value: string | null
  precision: DatePrecision
  /** The source cell, verbatim. Shown for year_only and invalid. */
  raw?: string | null
  year?: number | null
  /** Source status text such as منتهي, preserved rather than converted (D6). */
  sourceStatusRaw?: string | null
}


/** Only an exact date may ever drive an alert or a Days Left figure. */
export function drivesAlerts(date: PrecisionDate | null | undefined): boolean {
  return date?.precision === 'exact_date' && date.value !== null
}
