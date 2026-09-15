import type { NormalizedDate } from '../types'
import { cellToText } from './identifiers'

/**
 * Date normalization with EXPLICIT precision (CLAUDE.md principle #17).
 *
 * Only `exact_date` may drive Days Left, Due Today, 7/15/30/60-day alerts or
 * Overdue. A year-only source value is NEVER expanded to 1 January, 31
 * December, mid-year, the row's date, or the import date.
 */

/**
 * Source status words kept verbatim rather than converted (decision D6).
 * `منتهي`/`منتهية` means "expired" — a real compliance signal — but it is not a
 * date and must not become one, nor a computed status.
 */
const STATUS_WORDS = new Set(['منتهي', 'منتهية', 'شهادة المنشأ'])

const YEAR_MIN = 1970
const YEAR_MAX = 2100

function empty(raw: string | null): NormalizedDate {
  return { value: null, precision: 'unknown', raw, year: null }
}

function invalid(raw: string | null, sourceStatusRaw?: string): NormalizedDate {
  return { value: null, precision: 'invalid', raw, year: null, sourceStatusRaw: sourceStatusRaw ?? null }
}

function yearOnly(raw: string | null, year: number): NormalizedDate {
  // value stays NULL. The year is kept so the source information survives
  // without a fabricated day ever existing.
  return { value: null, precision: 'year_only', raw, year }
}

function exact(raw: string | null, iso: string): NormalizedDate {
  return { value: iso, precision: 'exact_date', raw, year: Number(iso.slice(0, 4)) }
}

function iso(y: number, m: number, d: number): string | null {
  if (m < 1 || m > 12 || d < 1 || d > 31) return null
  const dt = new Date(Date.UTC(y, m - 1, d))
  // Rejects 31 February and friends: a rolled-over date is not the source date.
  if (dt.getUTCFullYear() !== y || dt.getUTCMonth() !== m - 1 || dt.getUTCDate() !== d) return null
  if (y < YEAR_MIN || y > YEAR_MAX) return null
  return `${String(y).padStart(4, '0')}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`
}

/**
 * @param dayFirst the column's asserted order. Source columns are d/m/y, which
 *   import-mapping.md §10 requires to be asserted per column rather than
 *   sniffed per value — sniffing silently swaps 3/4 and 4/3.
 */
export function normalizeDate(raw: unknown, dayFirst = true): NormalizedDate {
  if (raw === null || raw === undefined) return empty(null)

  // A real Excel date cell: the only unambiguous shape there is.
  if (raw instanceof Date) {
    const value = iso(raw.getUTCFullYear(), raw.getUTCMonth() + 1, raw.getUTCDate())
    const rawText = raw.toISOString()
    return value ? exact(rawText, value) : invalid(rawText)
  }

  if (typeof raw === 'number') {
    // A bare year stored as a number: 2021. Year-only, NOT 2021-01-01.
    if (Number.isInteger(raw) && raw >= YEAR_MIN && raw <= YEAR_MAX) {
      return yearOnly(String(raw), raw)
    }
    return invalid(String(raw))
  }

  let text: string | null
  try {
    text = cellToText(raw)
  } catch {
    return invalid(String(raw))
  }
  if (text === null) return empty(null)

  const trimmed = text.trim()

  // Status text is preserved beside the missing date, never turned into one.
  if (STATUS_WORDS.has(trimmed)) return invalid(trimmed, trimmed)

  // A bare year as text: '2022'.
  if (/^\d{4}$/.test(trimmed)) {
    const y = Number(trimmed)
    if (y >= YEAR_MIN && y <= YEAR_MAX) return yearOnly(trimmed, y)
    return invalid(trimmed)
  }

  // d/m/y, d-m-y, d.m.y — with a 2- or 4-digit year.
  const m = trimmed.match(/^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{2,4})$/)
  if (m) {
    const a = Number(m[1])
    const b = Number(m[2])
    let y = Number(m[3])
    if (m[3].length === 2) y += y < 70 ? 2000 : 1900

    const day = dayFirst ? a : b
    const month = dayFirst ? b : a
    const value = iso(y, month, day)
    // '209/2021' and '16/8/3033' land here and stay invalid: not repaired.
    return value ? exact(trimmed, value) : invalid(trimmed)
  }

  // ISO yyyy-mm-dd.
  const isoMatch = trimmed.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
  if (isoMatch) {
    const value = iso(Number(isoMatch[1]), Number(isoMatch[2]), Number(isoMatch[3]))
    return value ? exact(trimmed, value) : invalid(trimmed)
  }

  return invalid(trimmed)
}

/** True only for a date that may drive an alert. Used to keep that rule in one place. */
export function drivesAlerts(date: NormalizedDate): boolean {
  return date.precision === 'exact_date' && date.value !== null
}
