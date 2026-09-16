/**
 * CSV serialization for report export.
 *
 * TWO THREATS, HANDLED SEPARATELY.
 *
 * 1. CSV INJECTION. A spreadsheet treats a cell beginning with `=`, `+`, `-`,
 *    `@`, a tab or a carriage return as a FORMULA. A source workbook in this
 *    project is operator-entered text, so a Station note or a serial could
 *    legitimately begin with one of those characters — and `=cmd|...` in a
 *    downloaded report is a real attack on whoever opens it.
 *
 *    The guard is applied to TEXT cells only, and a genuine number is emitted
 *    as a number. `-5` days remaining is the integer -5 and no spreadsheet
 *    evaluates it as a formula; quoting it would make a numeric column sort as
 *    text, which is its own defect. So the column spec's type decides, and a
 *    "numeric" value that is not actually numeric falls back to the text guard
 *    rather than being trusted.
 *
 * 2. DATA CORRUPTION. Identifiers in this system are TEXT and leading zeros are
 *    meaningful (data principle #11). Nothing here strips, pads or re-formats a
 *    value; the guard PREFIXES, it never edits. The database value is untouched
 *    and the raw cell is still whatever the workbook said.
 *
 * The prefix is a single apostrophe, the OWASP mitigation: a spreadsheet reads
 * the rest of the cell as literal text. It is visible, which is the point — a
 * silent neutralizer that looked like the original value would be worse.
 */

/** Characters a spreadsheet may treat as the start of a formula. */
const FORMULA_LEAD = /^[=+\-@\t\r]/

/** A value we are willing to emit unquoted as a number. */
const PLAIN_NUMBER = /^-?\d+(\.\d+)?$/

export type CsvValueKind = 'text' | 'number' | 'date'

/**
 * UTF-8 BOM. Arabic Station and Unit names are ordinary data in this product,
 * and Excel misreads a BOM-less UTF-8 CSV as the local 8-bit codepage, which
 * turns every Arabic name into mojibake. The BOM is part of "UTF-8 that a
 * person can actually open".
 */
export const CSV_BOM = '﻿'

export function escapeCsvCell(value: unknown, kind: CsvValueKind = 'text'): string {
  // NULL stays blank. Not "N/A", not "-", not 0 (§11.5 and data principle #3).
  if (value === null || value === undefined) return ''

  if (kind === 'number') {
    const asText = String(value)
    // Only a value that really is a number is emitted bare. Anything else is
    // text wearing a numeric column, and gets the text treatment.
    if (PLAIN_NUMBER.test(asText)) return asText
    return escapeCsvCell(asText, 'text')
  }

  let text = String(value)
  if (FORMULA_LEAD.test(text)) text = `'${text}`

  // Quote whenever the field could otherwise break the row, and always once a
  // guard has been applied, so the apostrophe cannot be mistaken for structure.
  const mustQuote = /[",\n\r\t]/.test(text) || text.startsWith("'")
  return mustQuote ? `"${text.replace(/"/g, '""')}"` : text
}

export interface CsvColumn<Row> {
  /** The header, in a fixed position. Column order is part of the contract. */
  header: string
  kind?: CsvValueKind
  value: (row: Row) => unknown
}

export function toCsv<Row>(columns: CsvColumn<Row>[], rows: Row[]): string {
  const head = columns.map((c) => escapeCsvCell(c.header, 'text')).join(',')
  const body = rows.map((row) =>
    columns.map((c) => escapeCsvCell(c.value(row), c.kind ?? 'text')).join(','),
  )
  // CRLF: the line ending every spreadsheet on every platform reads correctly.
  return CSV_BOM + [head, ...body].join('\r\n') + '\r\n'
}

/**
 * `cng-<report>-<YYYY-MM-DD>.csv`.
 *
 * The date is the Africa/Cairo business date, the same day the rest of the
 * product means by "today" — a report exported at 01:00 Cairo must not be
 * filed under yesterday because the browser happens to be in UTC.
 */
export function exportFilename(reportId: string, businessDate: string): string {
  const safe = reportId.replace(/[^a-z0-9-]/gi, '-').toLowerCase()
  return `cng-${safe}-${businessDate}.csv`
}

/** The Africa/Cairo calendar date, matching `cng_business_date()` in SQL. */
export function cairoBusinessDate(now: Date = new Date()): string {
  // `en-CA` renders ISO-8601, and the timeZone option does the conversion the
  // database does with `now() AT TIME ZONE 'Africa/Cairo'`.
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Africa/Cairo',
    year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(now)
}

/** Triggers the browser download. Separated so `toCsv` stays pure and testable. */
export function downloadCsv(filename: string, csv: string): void {
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}
