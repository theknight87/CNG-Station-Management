import { cairoBusinessDate } from '@/features/reports/csv'

/**
 * The date filter every registry and workflow tab offers (owner request 2026-09-29): pick which date (next
 * calibration, sent, issued, …), then From and/or To. Both ends are inclusive calendar days.
 *
 * A date recorded at year-only (or unknown) precision is never matched by a day range — principle #17: only an
 * exact date is a calendar day. Where the dataset carries a precision column the filter requires `exact_date`.
 */
export interface DateRange {
  /** The chosen date column; '' means the first option offered. */
  dateField: string
  /** `YYYY-MM-DD` or ''. */
  dateFrom: string
  dateTo: string
}

export interface DateOption {
  column: string
  label: string
  /** The precision column beside it, when the dataset has one. */
  precision?: string
}

export const EMPTY_DATE_RANGE: DateRange = { dateField: '', dateFrom: '', dateTo: '' }

const ISO_DAY = /^\d{4}-\d{2}-\d{2}$/

export function hasDateRange(f: Partial<DateRange>): boolean {
  return Boolean((f.dateFrom && ISO_DAY.test(f.dateFrom)) || (f.dateTo && ISO_DAY.test(f.dateTo)))
}

export function addDays(iso: string, days: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const t = new Date(Date.UTC(y, m - 1, d + days))
  return t.toISOString().slice(0, 10)
}

/** The option a range applies to: the chosen one, or the first offered. */
export function dateOptionFor(f: Partial<DateRange>, options: DateOption[]): DateOption | null {
  return options.find((o) => o.column === f.dateField) ?? options[0] ?? null
}

/**
 * Narrows a PostgREST builder to the range. The upper bound is "before the next day", so a timestamp anywhere on
 * the To day is included as well as a plain date. A reversed range is read the right way round.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function applyDateRange<B extends { gte: any; lt: any; eq: any }>(b: B, f: Partial<DateRange>, options: DateOption[] | undefined): B {
  if (!options?.length || !hasDateRange(f)) return b
  const opt = dateOptionFor(f, options)
  if (!opt) return b
  let from = f.dateFrom && ISO_DAY.test(f.dateFrom) ? f.dateFrom : ''
  let to = f.dateTo && ISO_DAY.test(f.dateTo) ? f.dateTo : ''
  if (from && to && from > to) [from, to] = [to, from]
  if (from) b = b.gte(opt.column, from)
  if (to) b = b.lt(opt.column, addDays(to, 1))
  if (opt.precision) b = b.eq(opt.precision, 'exact_date')
  return b
}

/** The same test for rows already in memory. */
export function inDateRange(row: Record<string, unknown>, f: Partial<DateRange>, options: DateOption[] | undefined): boolean {
  if (!options?.length || !hasDateRange(f)) return true
  const opt = dateOptionFor(f, options)
  if (!opt) return true
  const raw = row[opt.column]
  if (typeof raw !== 'string' || raw.length < 10) return false
  if (opt.precision && row[opt.precision] !== 'exact_date') return false
  const day = raw.slice(0, 10)
  let from = f.dateFrom ?? '', to = f.dateTo ?? ''
  if (from && to && from > to) [from, to] = [to, from]
  return (!from || day >= from) && (!to || day <= to)
}

export type DatePreset = 'past' | 'last30' | 'next30' | 'next60' | 'thisMonth' | 'thisYear'

export const DATE_PRESETS: { value: DatePreset; label: string }[] = [
  { value: 'past', label: 'Before today' },
  { value: 'last30', label: 'Last 30 days' },
  { value: 'next30', label: 'Next 30 days' },
  { value: 'next60', label: 'Next 60 days' },
  { value: 'thisMonth', label: 'This month' },
  { value: 'thisYear', label: 'This year' },
]

/** A quick range, counted from today's Cairo business date. */
export function presetRange(preset: DatePreset, today: string = cairoBusinessDate()): Pick<DateRange, 'dateFrom' | 'dateTo'> {
  const [y, m] = today.split('-').map(Number)
  switch (preset) {
    case 'past': return { dateFrom: '', dateTo: addDays(today, -1) }
    case 'last30': return { dateFrom: addDays(today, -30), dateTo: today }
    case 'next30': return { dateFrom: today, dateTo: addDays(today, 30) }
    case 'next60': return { dateFrom: today, dateTo: addDays(today, 60) }
    case 'thisMonth': {
      const first = `${y}-${String(m).padStart(2, '0')}-01`
      const nextFirst = m === 12 ? `${y + 1}-01-01` : `${y}-${String(m + 1).padStart(2, '0')}-01`
      return { dateFrom: first, dateTo: addDays(nextFirst, -1) }
    }
    case 'thisYear': return { dateFrom: `${y}-01-01`, dateTo: `${y}-12-31` }
  }
}
