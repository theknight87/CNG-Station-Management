/**
 * The six authoritative source workbooks, and the sheets the pipeline reads.
 *
 * Header rows are ASSERTED from the Prompt 2 analysis (docs/data-dictionary.md),
 * never detected: a guessed header row silently shifts every column mapping.
 *
 * The `Repair Kit` sheet is deliberately absent and is asserted excluded by the
 * test suite. It is out of scope by instruction and is not read at all.
 */

export type TargetTable =
  | 'stations_units'
  | 'unit_attributes'
  | 'dispensers_storage'
  | 'storage_vessels'
  | 'recovery_tanks'
  | 'gas_detectors'
  | 'installed_relief_valves'
  | 'warehouse_relief_valves'
  | 'hoses'

export interface SheetSpec {
  sheet: string
  headerRow: number
  target: TargetTable
  /** Present only for sheets that split into two tables by a column value. */
  splitColumn?: string
}

export interface WorkbookSpec {
  /** File name exactly as delivered. */
  file: string
  sheets: SheetSpec[]
  /** Sheets present in the file that are deliberately NOT read, and why. */
  excludedSheets: Array<{ sheet: string; reason: string }>
}

export const WORKBOOKS: ReadonlyArray<WorkbookSpec> = [
  {
    file: 'Station data base.xlsx',
    sheets: [{ sheet: 'Sheet1', headerRow: 1, target: 'unit_attributes' }],
    excludedSheets: [{ sheet: 'Sheet2', reason: 'stray lookup cells, no records' }],
  },
  {
    file: 'Assets DataBase - East, west and Delta Completed.xlsx',
    sheets: [{ sheet: 'Sheet1', headerRow: 1, target: 'stations_units' }],
    excludedSheets: [],
  },
  {
    file: 'Warehouse Relief Data.xlsx',
    sheets: [
      { sheet: 'رصيد المحطات', headerRow: 5, target: 'installed_relief_valves' },
      { sheet: 'رصيد المخزن', headerRow: 5, target: 'warehouse_relief_valves' },
    ],
    excludedSheets: [
      { sheet: 'Repair Kit ', reason: 'OUT OF SCOPE by instruction; never read' },
      { sheet: 'Sheet2', reason: 'stray lookup cells, no records' },
    ],
  },
  {
    file: 'شهادات الفحص والمعايرة للمناطق .xlsx',
    sheets: [
      {
        // Verified against the delivered file: this workbook's data sheet
        // carries the same Arabic name as the installed-SRV sheet in file 3.
        // They are DIFFERENT sheets in different workbooks; the file is part of
        // the identity, which is why provenance always carries both.
        sheet: 'رصيد المحطات',
        headerRow: 5,
        target: 'storage_vessels',
        // Location splits this sheet into two DIFFERENT equipment tables:
        // Storage -> storage_vessel, Recovery -> recovery_tank.
        splitColumn: 'Location',
      },
    ],
    excludedSheets: [{ sheet: 'Sheet2', reason: 'stray lookup cells, no records' }],
  },
  {
    file: 'Gas detector.xlsx',
    sheets: [{ sheet: 'Sheet1', headerRow: 1, target: 'gas_detectors' }],
    excludedSheets: [{ sheet: 'Sheet2', reason: 'stray lookup cells, no records' }],
  },
  {
    file: 'HOSES.xlsx',
    sheets: [{ sheet: 'Sheet1', headerRow: 1, target: 'hoses' }],
    excludedSheets: [],
  },
]

/** Sheet names that must NEVER be read, whatever else changes. */
export const FORBIDDEN_SHEETS: ReadonlyArray<string> = ['Repair Kit', 'Repair Kit ']

export function isForbiddenSheet(name: string): boolean {
  return FORBIDDEN_SHEETS.some((f) => f.trim() === name.trim())
}

/** Columns never imported, with the reason (import-mapping.md §13). */
export const NEVER_IMPORTED_COLUMNS: ReadonlyArray<{ column: string; reason: string }> = [
  { column: 'Number Of Days Left', reason: 'stale snapshot; derived at read time' },
  { column: 'Days Left', reason: 'stale snapshot; derived at read time' },
  { column: 'Next Calibration Month', reason: 'derived from the next calibration date' },
  { column: '#', reason: 'row counter, not an identifier' },
  { column: 'Column1', reason: 'empty artefact column' },
]

const NEVER_IMPORTED = new Set(NEVER_IMPORTED_COLUMNS.map((c) => c.column.trim().toLowerCase()))

export function isNeverImported(column: string): boolean {
  return NEVER_IMPORTED.has(column.trim().toLowerCase())
}
