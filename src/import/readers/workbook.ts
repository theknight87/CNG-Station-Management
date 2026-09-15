import ExcelJS from 'exceljs'

import type { Provenance } from '../types'

/**
 * READ-ONLY workbook access.
 *
 * Nothing in this module writes, saves, or re-serializes a workbook. The source
 * files are opened, read and closed; their checksums are asserted unchanged by
 * the dry-run harness before and after every run.
 */

export interface SheetRow {
  provenance: Provenance
  /** The ENTIRE row, verbatim, keyed by header. Never mutated afterwards. */
  raw: Record<string, unknown>
}

export interface SheetReadResult {
  file: string
  sheet: string
  headerRow: number
  headers: string[]
  rows: SheetRow[]
}

/** Raw cell value, with ExcelJS wrappers unwrapped but NO coercion applied. */
function rawCellValue(cell: ExcelJS.Cell): unknown {
  const v = cell.value
  if (v === null || v === undefined) return null
  if (v instanceof Date) return v
  if (typeof v === 'object') {
    const o = v as { richText?: Array<{ text: string }>; text?: unknown; result?: unknown; error?: unknown }
    if (Array.isArray(o.richText)) return o.richText.map((r) => r.text).join('')
    if (o.error !== undefined) return String(o.error)
    if (o.result !== undefined) return o.result
    if (o.text !== undefined) return o.text
    return null
  }
  return v
}

/**
 * Reads one sheet.
 *
 * @param headerRow 1-based, ASSERTED by the caller from the Prompt 2 analysis
 *   rather than detected. Header detection that guesses would silently shift
 *   every column mapping.
 */
export async function readSheet(
  filePath: string,
  fileLabel: string,
  sheetName: string,
  headerRow: number,
): Promise<SheetReadResult> {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.readFile(filePath)

  const ws = wb.getWorksheet(sheetName)
  if (!ws) {
    throw new Error(`sheet not found: ${sheetName} in ${fileLabel}`)
  }

  const headerCells = ws.getRow(headerRow)
  const headers: string[] = []
  headerCells.eachCell({ includeEmpty: true }, (cell, col) => {
    const text = rawCellValue(cell)
    headers[col] = text === null ? `__col${col}` : String(text)
  })

  const rows: SheetRow[] = []
  ws.eachRow({ includeEmpty: false }, (row, rowNumber) => {
    if (rowNumber <= headerRow) return

    const raw: Record<string, unknown> = {}
    let hasAnyValue = false
    row.eachCell({ includeEmpty: true }, (cell, col) => {
      const header = headers[col] ?? `__col${col}`
      const value = rawCellValue(cell)
      raw[header] = value
      if (value !== null && String(value).trim() !== '') hasAnyValue = true
    })

    // A wholly empty row is formatting, not a record. It is not an issue.
    if (!hasAnyValue) return

    rows.push({
      provenance: { file: fileLabel, sheet: sheetName, row: rowNumber },
      raw,
    })
  })

  return {
    file: fileLabel,
    sheet: sheetName,
    headerRow,
    headers: headers.filter((h): h is string => typeof h === 'string'),
    rows,
  }
}

export async function listSheets(filePath: string): Promise<string[]> {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.readFile(filePath)
  return wb.worksheets.map((w) => w.name)
}
