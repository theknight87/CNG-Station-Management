import { formPressure } from '@/features/export/calibrationForm'
import { byValues, pressureBar } from '@/features/relief-valves/srvSort'
import type { PressureUnit } from '@/features/units/useUnitWorkspace'

/**
 * The warehouse issue workbook (owner request 2026-10-03; templates "شرق" / "غرب", March 2026): one workbook per Region
 * and month, one sheet per issue day, titled "بيانات صرف صمامات أمان معايرة". A second export the same day for the same
 * Region is a new sheet "<date> (2)", then "(3)" — the sheets already sent never change, because which issues each
 * sheet carries is stored in the database (srv_issue_sheets, placed by cng_srv_issue_sheet_assign).
 *
 * Columns, as on the owner's sheets:
 *   الضغط                     the issued valve's set pressure with its unit
 *   الموقع                    Stage / Storage, from the position the valve was fitted in (empty when not recorded)
 *   المحطة                    the Unit; Station-level storage (ruling 6y) is written under the Station
 *   المقاس                    inlet X outlet ("Flange" first for a flanged valve)
 *   الموديل                   manufacturer — what the owner's sheet records in this column
 *   رقم الصمام في المحطة       the valve it replaced (empty when it replaced none)
 *   رقم الصمام المعاير في المخزن the issued valve's serial
 *   الكود المخزني              the issued valve's warehouse code, exactly as recorded
 *   تاريخ الرجوع للمخزن         when the replaced valve came back, once it has; empty until then
 */

export interface IssueSheetRow {
  id: string
  issued_at: string
  issue_day: string
  region_id: string
  region_name: string
  sheet_id: string | null
  sheet_seq: number | null
  sheet_exported_at: string | null
  is_emergency: boolean
  station_name: string
  unit_name: string
  place_name: string
  location: string | null
  warehouse_valve_id: string
  issued_serial: string | null
  issued_code: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  replaced_installed_valve_id: string | null
  replaced_serial: string | null
  replaced_returned_at: string | null
}

export const ISSUE_SHEET_COLUMNS =
  'id, issued_at, issue_day, region_id, region_name, sheet_id, sheet_seq, sheet_exported_at, is_emergency, station_name, ' +
  'unit_name, place_name, location, warehouse_valve_id, issued_serial, issued_code, manufacturer, size_type, inlet_size, ' +
  'outlet_size, set_pressure_raw, pressure_min, pressure_max, pressure_unit, replaced_installed_valve_id, replaced_serial, ' +
  'replaced_returned_at'

/** The Region as the owner writes it on the sheet ("المنطقة : شرق"). */
const REGION_AR: Record<string, string> = {
  East: 'شرق', West: 'غرب', Delta: 'دلتا', Canal: 'القناة', Alex: 'الإسكندرية', Upper: 'الصعيد',
}
export function regionArabic(name: string): string {
  return REGION_AR[name] ?? name
}

/** `5-10-2026` — day-month-year without padding, as the owner names the sheets. */
export function sheetDay(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  return `${d}-${m}-${y}`
}
/** `05/10/2026` — the date written inside the sheet. */
export function sheetDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split('-')
  return `${d}/${m}/${y}`
}
/** "East 5-10-2026", "East 5-10-2026 (2)" … (Excel caps sheet names at 31 characters). */
export function sheetName(region: string, day: string, seq: number): string {
  return `${region} ${sheetDay(day)}${seq > 1 ? ` (${seq})` : ''}`.slice(0, 31)
}

/** First and day-after-last of the month `YYYY-MM`. */
export function monthRange(month: string): { from: string; to: string } {
  const [y, m] = month.split('-').map(Number)
  const next = m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, '0')}`
  return { from: `${month}-01`, to: `${next}-01` }
}

export function sheetSize(r: Pick<IssueSheetRow, 'size_type' | 'inlet_size' | 'outlet_size'>): string | null {
  const clean = (v: string | null) => (v ? v.replace(/["”]/g, '').trim() : '')
  const io = [clean(r.inlet_size), clean(r.outlet_size)].filter(Boolean).join(' X ')
  const flange = (r.size_type ?? '').trim().toLowerCase() === 'flange'
  if (!io) return r.size_type?.trim() || null
  return flange ? `Flange ${io}` : io
}

const LOCATION_RANK: Record<string, number> = { stage: 0, storage: 1 }

/** A sheet's rows: places in the order they were issued to, Stage before Storage, lowest set pressure first. */
export function orderSheetRows(rows: IssueSheetRow[]): IssueSheetRow[] {
  const firstAt = new Map<string, string>()
  for (const r of rows) {
    const seen = firstAt.get(r.place_name)
    if (seen === undefined || r.issued_at < seen) firstAt.set(r.place_name, r.issued_at)
  }
  return [...rows].sort(byValues<IssueSheetRow>(
    (r) => firstAt.get(r.place_name) ?? null, (r) => r.place_name,
    (r) => LOCATION_RANK[(r.location ?? '').toLowerCase()] ?? 2, pressureBar, (r) => r.issued_at,
  ))
}

export interface IssueSheet { day: string; seq: number; name: string; rows: IssueSheetRow[] }

/** The sheets already exported, newest day first and, within a day, the latest export first (as the owner keeps them). */
export function groupSheets(rows: IssueSheetRow[], region: string): IssueSheet[] {
  const by = new Map<string, IssueSheet>()
  for (const r of rows) {
    if (r.sheet_id === null || r.sheet_seq === null) continue
    let s = by.get(r.sheet_id)
    if (!s) { s = { day: r.issue_day, seq: r.sheet_seq, name: sheetName(region, r.issue_day, r.sheet_seq), rows: [] }; by.set(r.sheet_id, s) }
    s.rows.push(r)
  }
  return [...by.values()]
    .map((s) => ({ ...s, rows: orderSheetRows(s.rows) }))
    .sort((a, b) => (a.day === b.day ? b.seq - a.seq : b.day.localeCompare(a.day)))
}

/** What an export would add: the days whose issues are in no sheet yet, and the sheet each would become. */
export function pendingSheets(rows: IssueSheetRow[], region: string): { day: string; name: string; count: number }[] {
  const lastSeq = new Map<string, number>()
  const pending = new Map<string, number>()
  for (const r of rows) {
    if (r.sheet_seq !== null) lastSeq.set(r.issue_day, Math.max(lastSeq.get(r.issue_day) ?? 0, r.sheet_seq))
    else pending.set(r.issue_day, (pending.get(r.issue_day) ?? 0) + 1)
  }
  return [...pending.entries()].sort(([a], [b]) => a.localeCompare(b))
    .map(([day, count]) => ({ day, count, name: sheetName(region, day, (lastSeq.get(day) ?? 0) + 1) }))
}

const TITLE = 'بيانات صرف صمامات أمان معايرة'
const HEADERS = ['', 'الضغط', 'الموقع', 'المحطة', 'المقاس', 'الموديل', 'رقم الصمام في المحطة', 'رقم الصمام المعاير في المخزن',
  'الكود المخزني', 'تاريخ الرجوع للمخزن']
const WIDTHS = [3.73, 12.82, 10.63, 14.18, 10.82, 15.36, 15.82, 16.54, 11.91, 12.54]
const GREY = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFA6A6A6' } } as const
const THIN = { style: 'thin' } as const
const BOX = { top: THIN, left: THIN, bottom: THIN, right: THIN }
const CENTER = { horizontal: 'center', vertical: 'middle', wrapText: true } as const

export function sheetCells(r: IssueSheetRow, n: number): (string | number | null)[] {
  return [
    n, formPressure(r), r.location, r.place_name, sheetSize(r), r.manufacturer, r.replaced_serial, r.issued_serial,
    r.issued_code, r.replaced_returned_at ? sheetDate(r.replaced_returned_at) : null,
  ]
}

export async function buildIssueWorkbook(region: string, sheets: IssueSheet[]): Promise<Blob> {
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  for (const sheet of sheets) {
    const ws = wb.addWorksheet(sheet.name)
    WIDTHS.forEach((w, i) => { ws.getColumn(i + 1).width = w })
    ws.mergeCells('A1:J1')
    Object.assign(ws.getCell('A1'), { value: TITLE, font: { bold: true, size: 18 }, alignment: CENTER })
    ws.mergeCells('A2:D2')
    Object.assign(ws.getCell('A2'), { value: `تاريخ الصرف من المخزن : ${sheetDate(sheet.day)}`, font: { size: 11 }, alignment: CENTER })
    ws.mergeCells('H2:J2')
    Object.assign(ws.getCell('H2'), { value: `المنطقة : ${regionArabic(region)}`, font: { size: 11 }, alignment: CENTER })
    ws.getRow(1).height = 40
    ws.getRow(2).height = 45
    const head = ws.getRow(3)
    head.height = 29
    HEADERS.forEach((h, i) => {
      Object.assign(head.getCell(i + 1), { value: h || null, font: { bold: true, size: 11 }, fill: GREY, alignment: CENTER, border: BOX })
    })
    sheet.rows.forEach((r, i) => {
      const row = ws.getRow(4 + i)
      row.height = 23.5
      // Serials and codes stay TEXT, so leading zeros and dashes survive.
      sheetCells(r, i + 1).forEach((v, n) => {
        Object.assign(row.getCell(n + 1), { value: v === '' ? null : v, font: { size: 11 }, alignment: CENTER, border: BOX })
      })
    })
    ws.pageSetup = {
      paperSize: 9, orientation: 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0, horizontalCentered: true,
      margins: { left: 0.25, right: 0.25, top: 0.5, bottom: 0.5, header: 0, footer: 0 },
      printArea: `A1:J${3 + Math.max(sheet.rows.length, 1)}`, printTitlesRow: '1:3',
    }
  }
  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

/** "صرف شرق 10-2026.xlsx" */
export function issueWorkbookName(region: string, month: string): string {
  const [y, m] = month.split('-').map(Number)
  return `صرف ${regionArabic(region)} ${m}-${y}.xlsx`
}
