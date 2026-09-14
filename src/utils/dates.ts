/**
 * Days Left is always derived from the next valid due date and never read from
 * a source spreadsheet (CLAUDE.md, data principles #12 and #13).
 *
 * A missing due date yields null — never 0, and never "overdue".
 */

export type DueStatus = 'unknown' | 'overdue' | 'due_soon' | 'ok'

const MS_PER_DAY = 86_400_000

function toUtcMidnight(date: Date): number {
  return Date.UTC(date.getFullYear(), date.getMonth(), date.getDate())
}

/** Whole days from `today` until `nextDueDate`. Negative means overdue. */
export function daysLeft(
  nextDueDate: Date | string | null | undefined,
  today: Date = new Date(),
): number | null {
  if (nextDueDate === null || nextDueDate === undefined || nextDueDate === '') {
    return null
  }

  const due = typeof nextDueDate === 'string' ? new Date(nextDueDate) : nextDueDate
  if (Number.isNaN(due.getTime())) return null

  return Math.round((toUtcMidnight(due) - toUtcMidnight(today)) / MS_PER_DAY)
}

/** `dueSoonThreshold` is the number of days before the due date to warn. */
export function dueStatus(days: number | null, dueSoonThreshold = 30): DueStatus {
  if (days === null) return 'unknown'
  if (days < 0) return 'overdue'
  if (days <= dueSoonThreshold) return 'due_soon'
  return 'ok'
}
