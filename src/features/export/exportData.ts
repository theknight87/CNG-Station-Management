import type { SupabaseClient } from '@supabase/supabase-js'

import { cairoBusinessDate, toCsv, type CsvValueKind } from '@/features/reports/csv'
import { EXPORT_MAX_ROWS } from '@/features/reports/useReportQuery'

/**
 * Table export to Excel (.xlsx) or CSV (owner request 2026-09-29).
 *
 * WHAT IS EXPORTED IS WHAT THE CALLER MAY READ. Every export re-runs a query
 * through the caller's own Supabase session, so RLS bounds the file exactly as
 * it bounds the screen. Nothing here reads a table the screen does not.
 *
 * VALUES, NOT PIXELS. A NULL stays an empty cell (never "N/A", "-" or 0), a
 * year-only date is exported as its year, identifiers stay text so leading zeros
 * survive, and a genuine number is written as a number so it sorts as one.
 *
 * FORMULA INJECTION. CSV reuses the Reports encoder (apostrophe guard on text
 * cells). In .xlsx every text value is written as a STRING cell; ExcelJS only
 * writes a formula when handed a `{ formula }` object, which nothing here does,
 * so `=cmd|...` in a source note opens as the literal text it is.
 */

export { EXPORT_MAX_ROWS }
const CHUNK = 1_000

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export type AnyRow = Record<string, any>

export interface ExportColumn<T = AnyRow> {
  header: string
  value: (row: T) => unknown
  kind?: CsvValueKind
}

export interface ExportSheet {
  /** Sheet tab name (Excel) and file-name part (CSV). */
  name: string
  columns: ExportColumn[]
  rows: AnyRow[]
  /** True when more rows existed than the export ceiling allowed. */
  truncated?: boolean
}

type PageResult = { data: unknown[] | null; error: { message: string } | null }

/**
 * Every row of a query, in bounded 1,000-row pages, up to the documented ceiling.
 * `page(from, to)` must build a FRESH request each call (a PostgREST builder runs once).
 */
export async function fetchAllRows(
  page: (from: number, to: number) => PromiseLike<PageResult>,
  max: number = EXPORT_MAX_ROWS,
): Promise<{ rows: AnyRow[]; truncated: boolean }> {
  const rows: AnyRow[] = []
  for (let from = 0; from < max; from += CHUNK) {
    const to = Math.min(from + CHUNK, max) - 1
    const { data, error } = await page(from, to)
    if (error) throw new Error(error.message)
    const batch = (data ?? []) as AnyRow[]
    rows.push(...batch)
    if (batch.length < to - from + 1) return { rows, truncated: false }
  }
  // Exactly at the ceiling: one more row decides whether the file is complete.
  const { data, error } = await page(max, max)
  if (error) throw new Error(error.message)
  return { rows, truncated: (data ?? []).length > 0 }
}

/** A cell for Excel: numbers stay numbers, everything else is literal text, NULL is empty. */
export function xlsxCell(value: unknown, kind: CsvValueKind = 'text'): string | number | null {
  if (value === null || value === undefined || value === '') return null
  if (kind === 'number') {
    if (typeof value === 'number' && Number.isFinite(value)) return value
    if (typeof value === 'string' && /^-?\d+(\.\d+)?$/.test(value)) return Number(value)
  }
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  return String(value)
}

/** Excel sheet names: ≤31 characters, none of []:*?/\ , unique within the workbook. */
export function sheetName(name: string, used: Set<string>): string {
  const base = (name.replace(/[[\]:*?/\\]/g, ' ').trim() || 'Sheet').slice(0, 31)
  let candidate = base
  for (let n = 2; used.has(candidate.toLowerCase()); n += 1) candidate = `${base.slice(0, 31 - String(n).length - 1)} ${n}`
  used.add(candidate.toLowerCase())
  return candidate
}

export async function toXlsx(sheets: ExportSheet[]): Promise<Blob> {
  // Loaded only when someone exports: ExcelJS is large and most visits never need it.
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  wb.created = new Date()
  const used = new Set<string>()
  for (const sheet of sheets) {
    const ws = wb.addWorksheet(sheetName(sheet.name, used), { views: [{ state: 'frozen', ySplit: 1 }] })
    ws.addRow(sheet.columns.map((c) => c.header))
    ws.getRow(1).font = { bold: true }
    for (const row of sheet.rows) ws.addRow(sheet.columns.map((c) => xlsxCell(c.value(row), c.kind)))
    if (sheet.columns.length > 0) {
      ws.autoFilter = { from: { row: 1, column: 1 }, to: { row: 1, column: sheet.columns.length } }
    }
    sheet.columns.forEach((c, i) => {
      let width = c.header.length
      for (const row of sheet.rows.slice(0, 500)) {
        const v = c.value(row)
        if (v !== null && v !== undefined) width = Math.max(width, String(v).length)
      }
      ws.getColumn(i + 1).width = Math.min(Math.max(width + 2, 8), 60)
    })
  }
  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

export function sheetToCsv(sheet: ExportSheet): string {
  return toCsv(sheet.columns, sheet.rows)
}

/** Arabic letters to Latin, for FILE NAMES only (never for data): a browser may drop a non-ASCII download name. */
const AR_LATIN: Record<string, string> = {
  'ا': 'a', 'أ': 'a', 'إ': 'e', 'آ': 'a', 'ب': 'b', 'ت': 't', 'ث': 'th', 'ج': 'g', 'ح': 'h', 'خ': 'kh', 'د': 'd', 'ذ': 'z',
  'ر': 'r', 'ز': 'z', 'س': 's', 'ش': 'sh', 'ص': 's', 'ض': 'd', 'ط': 't', 'ظ': 'z', 'ع': 'a', 'غ': 'gh', 'ف': 'f', 'ق': 'k',
  'ك': 'k', 'ل': 'l', 'م': 'm', 'ن': 'n', 'ه': 'h', 'ة': 'a', 'و': 'w', 'ؤ': 'o', 'ي': 'y', 'ى': 'a', 'ئ': 'e', 'ء': '',
  '٠': '0', '١': '1', '٢': '2', '٣': '3', '٤': '4', '٥': '5', '٦': '6', '٧': '7', '٨': '8', '٩': '9',
}

/**
 * `cng-<name>-<Cairo business date>.<ext>`, ASCII only. Chromium was observed saving a download whose name held any
 * non-ASCII character as plain "download" (no extension), so Arabic is transliterated here. The FILE CONTENT keeps
 * every name exactly as recorded; only the file name is simplified.
 */
export function exportFileName(name: string, ext: 'xlsx' | 'csv', date: string = cairoBusinessDate()): string {
  const latin = [...name.normalize('NFC')].map((ch) => AR_LATIN[ch] ?? ch).join('').normalize('NFD')
  // Drop accents and Arabic vowel marks, then anything that is not a plain file-name character.
  const safe = latin.replace(/[\u0300-\u036f\u064b-\u065f\u0670]/g, '').replace(/[^A-Za-z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').toLowerCase() || 'export'
  return `cng-${safe}-${date}.${ext}`
}

export function downloadBlob(filename: string, blob: Blob): void {
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  document.body.appendChild(link)
  link.click()
  document.body.removeChild(link)
  URL.revokeObjectURL(url)
}

/**
 * A loader for a registry export: the registry's own request (filters and sort, no paging), read whole in pages.
 * `request` must build a fresh query each call.
 */
export function queryLoader(
  supabase: SupabaseClient | null,
  sheet: string,
  columns: ExportColumn[],
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  request: (client: SupabaseClient) => { range: (from: number, to: number) => PromiseLike<any> },
): () => Promise<ExportSheet[]> {
  return async () => {
    if (!supabase) throw new Error('the database is not configured')
    const { rows, truncated } = await fetchAllRows((from, to) => request(supabase).range(from, to))
    return [{ name: sheet, columns, rows, truncated }]
  }
}

/** Rows already on screen (a bounded workflow list) as one sheet. */
export function rowsLoader(sheet: string, columns: ExportColumn[], rows: AnyRow[], truncated = false): () => Promise<ExportSheet[]> {
  return async () => [{ name: sheet, columns, rows, truncated }]
}
