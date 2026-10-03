import { formPressure } from '@/features/export/calibrationForm'
import { cairoBusinessDate } from '@/features/reports/csv'
import type { InstalledSrvRow } from '@/features/relief-valves/useSrvManagement'

/**
 * Installed SRVs in the owner's station sheet (owner request 2026-10-03, template "رصيد المحطات" of
 * Warehouse_Relief_Data.xlsx): title "Stations Safety Relief Valves Data", fourteen columns, banded rows, the
 * manufacturer cell coloured as in the template, and days left under 30 shown red.
 *
 * Every value comes from the record; nothing is filled in:
 *   Station          the Unit; Station-level storage (ruling 6y) and a valve with no Unit under the Station
 *   Location         as recorded, else Stage / Storage from the confirmed parent
 *   Dates            an exact date is a real date; a year-only date is written as its year and never as a day;
 *                    unknown stays empty
 *   Days Left        live in Excel (Next Calibration Date − TODAY()), with today's figure stored, and only for an
 *                    exact next date — principle 13, never a stale number
 *   Next Cal. Month  the exact next date shown as month-year
 *   Notes            the record's notes, then the source status text (e.g. "منتهي") when the source gave one
 */

const TITLE = 'Stations Safety Relief Valves Data'
const HEADERS = ['Area', 'Station', 'Location', 'Set Pressure', 'Manufacturer', 'Serial Number', 'Size Type', 'IN', 'OUT',
  'Last Calibration Date', 'Next Calibration Date', 'Number Of Days Left', 'Next Calibration Month', 'Notes']
const WIDTHS = [15.73, 21.45, 15.73, 15.73, 15.73, 21.18, 15.73, 15.73, 11.18, 15.73, 15.73, 15.73, 15.73, 26.54]
const FIRST = 6

/** The template's manufacturer colours (its conditional formats, highest priority first; case-insensitive). */
const MANUFACTURER_FILL: Record<string, string> = {
  'tyco anderson': 'FFFF0000', coi: 'FF548235', farinola: 'FF99CCFF', takei: 'FFF2B300', ekc: 'FFDA8EDC',
  taylor: 'FF66FF66', 'dk-lok': 'FFFF7C80', aspro: 'FFD9D9D9', technical: 'FF00B0F0', anderson: 'FFFFFF00', mercer: 'FFFBE4D5',
}
export function manufacturerFill(name: string | null): string | null {
  return name ? MANUFACTURER_FILL[name.trim().toLowerCase()] ?? null : null
}

export function installedPlace(r: Pick<InstalledSrvRow, 'unit_name' | 'station_display'>): string | null {
  return r.unit_name ?? r.station_display
}

export function installedLocation(r: Pick<InstalledSrvRow, 'location_raw' | 'parent_kind' | 'expected_parent_kind'>): string | null {
  const raw = r.location_raw?.trim()
  if (raw) return raw
  const kind = r.parent_kind ?? r.expected_parent_kind
  return kind === 'compressor' ? 'Stage' : kind === 'storage_vessel' ? 'Storage' : kind === 'dispenser' ? 'Dispenser' : null
}

/** A date cell's value: a Date for an exact date, the year for year-only, else nothing. */
export function sheetDateValue(iso: string | null, precision: string | null, display: string | null): Date | string | null {
  if (precision === 'exact_date' && iso) {
    const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
    return new Date(Date.UTC(y, m - 1, d))
  }
  if (precision === 'year_only') return display ?? (iso ? iso.slice(0, 4) : null)
  return null
}

export function installedNotes(r: Pick<InstalledSrvRow, 'notes' | 'source_status_raw'>): string | null {
  const parts = [r.notes?.trim(), r.source_status_raw?.trim()].filter((p): p is string => Boolean(p))
  return parts.length ? parts.join(' — ') : null
}

export async function buildInstalledWorkbook(rows: InstalledSrvRow[]): Promise<Blob> {
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  const ws = wb.addWorksheet('رصيد المحطات', {
    views: [{ state: 'frozen', ySplit: FIRST - 1 }],
    pageSetup: { paperSize: 9, orientation: 'landscape', fitToPage: true, fitToWidth: 1, fitToHeight: 0, horizontalCentered: true },
  })
  WIDTHS.forEach((w, i) => { ws.getColumn(i + 1).width = w })
  const center = { horizontal: 'center', vertical: 'middle', wrapText: true } as const

  ws.mergeCells('B1:L3')
  Object.assign(ws.getCell('B1'), {
    value: TITLE, font: { name: 'Calibri', size: 28, bold: true },
    fill: { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFA6A6A6' } }, alignment: center,
  })
  const head = ws.getRow(5)
  head.height = 48
  HEADERS.forEach((h, i) => Object.assign(head.getCell(i + 1), { value: h, font: { name: 'Calibri', size: 12, bold: true }, alignment: center }))

  rows.forEach((r, i) => {
    const n = FIRST + i
    const row = ws.getRow(n)
    row.height = 29.15
    const exactNext = r.next_calibration_precision === 'exact_date' && r.next_calibration_date
    const next = sheetDateValue(r.next_calibration_date, r.next_calibration_precision, r.next_calibration_display)
    const values: unknown[] = [
      r.region_name, installedPlace(r), installedLocation(r), formPressure(r), r.manufacturer, r.serial_number,
      r.size_type, r.inlet_size, r.outlet_size,
      sheetDateValue(r.last_calibration_date, r.last_calibration_precision, r.last_calibration_display),
      next,
      exactNext ? { formula: `K${n}-TODAY()`, result: r.days_left ?? undefined } : null,
      exactNext ? next : null,
      installedNotes(r),
    ]
    const band = i % 2 === 0 ? { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFDAE3F3' } } as const : undefined
    values.forEach((v, c) => {
      const cell = row.getCell(c + 1)
      cell.value = (v === '' || v === undefined ? null : v) as never
      cell.font = { name: 'Calibri', size: 11, bold: true }
      cell.alignment = center
      if (band) cell.fill = band
    })
    const mf = manufacturerFill(r.manufacturer)
    if (mf) row.getCell(5).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: mf } }
    row.getCell(10).numFmt = 'dd/mm/yyyy'
    row.getCell(11).numFmt = 'dd/mm/yyyy'
    row.getCell(12).numFmt = '0'
    row.getCell(13).numFmt = 'mmm-yy'
  })

  if (rows.length > 0) {
    const last = FIRST + rows.length - 1
    ws.addConditionalFormatting({
      ref: `L${FIRST}:L${last}`,
      rules: [{
        type: 'expression', priority: 1, formulae: [`AND(ISNUMBER(L${FIRST}),L${FIRST}<30)`],
        style: { fill: { type: 'pattern', pattern: 'solid', bgColor: { argb: 'FFFFC7CE' } }, font: { color: { argb: 'FF9C0006' }, bold: true } },
      }],
    })
    ws.autoFilter = { from: { row: 5, column: 1 }, to: { row: last, column: HEADERS.length } }
  }

  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

/** "Stations Safety Relief Valves Data 2026-10-03.xlsx" — the sheet's own title, never the template's file name. */
export function installedWorkbookName(today: string = cairoBusinessDate()): string {
  return `${TITLE} ${today}.xlsx`
}
