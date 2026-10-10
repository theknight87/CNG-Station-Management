import { byValues } from '@/features/relief-valves/srvSort'
import type { EquipmentKind } from '@/features/equipment/equipmentKinds'
import { regionArabic, sheetDate, sheetName } from './issueSheet'

/**
 * The warehouse issue workbook for hoses and gas detectors (owner request 2026-10-10: what the relief valves have, every
 * section has). Same shape as the SRV sheet (issueSheet.ts): one workbook per kind, Region and month, one sheet per
 * issue day, a later export the same day a NEW sheet "<date> (2)"; which issues each sheet carries is stored
 * (equipment_issue_sheets, placed by cng_equipment_issue_sheet_assign), so a sheet already sent is written again
 * unchanged. A moved item reads as issued straight to where it ended up; an issue undone after it left the warehouse
 * stays on its sheet marked "ملغي". The owner has sent no template for these, so the layout follows the SRV sheet.
 */

export interface EquipmentIssueSheetRow {
  id: string
  kind: EquipmentKind
  issued_at: string
  issue_day: string
  region_id: string
  region_name: string
  sheet_id: string | null
  sheet_seq: number | null
  is_emergency: boolean
  station_name: string
  unit_name: string | null
  place_name: string
  issued_serial: string | null
  issued_code: string | null
  manufacturer: string | null
  model: string | null
  description: string | null
  working_pressure_value: number | null
  working_pressure_unit: string | null
  replaced_serial: string | null
  replaced_returned_at: string | null
  is_cancelled: boolean
  cancelled_returned_at: string | null
}

export const EQUIPMENT_ISSUE_SHEET_COLUMNS =
  'id, kind, issued_at, issue_day, region_id, region_name, sheet_id, sheet_seq, is_emergency, station_name, unit_name, ' +
  'place_name, issued_serial, issued_code, manufacturer, model, description, working_pressure_value, working_pressure_unit, ' +
  'replaced_serial, replaced_returned_at, is_cancelled, cancelled_returned_at'

const NOUN: Record<EquipmentKind, { title: string; file: string; one: string }> = {
  hose: { title: 'بيانات صرف خراطيم', file: 'خراطيم', one: 'الخرطوم' },
  gas_detector: { title: 'بيانات صرف كواشف غاز', file: 'كواشف غاز', one: 'الكاشف' },
}

export function equipmentHeaders(kind: EquipmentKind): string[] {
  const n = NOUN[kind].one
  return kind === 'hose'
    ? ['', 'المحطة', 'الوصف', 'ضغط التشغيل', `رقم ${n} في المحطة`, `رقم ${n} في المخزن`, 'الكود المخزني', 'تاريخ الرجوع للمخزن']
    : ['', 'المحطة', 'الشركة المصنعة', 'الموديل', `رقم ${n} في المحطة`, `رقم ${n} في المخزن`, 'الكود المخزني', 'تاريخ الرجوع للمخزن']
}

/** As on the SRV sheet: "ملغي" for an issue undone after it left, with the date once its own item is back. */
export function equipmentReturnCell(r: Pick<EquipmentIssueSheetRow, 'is_cancelled' | 'cancelled_returned_at' | 'replaced_returned_at'>): string | null {
  if (r.is_cancelled) return r.cancelled_returned_at ? `ملغي - ${sheetDate(r.cancelled_returned_at)}` : 'ملغي'
  return r.replaced_returned_at ? sheetDate(r.replaced_returned_at) : null
}

export function equipmentSheetCells(kind: EquipmentKind, r: EquipmentIssueSheetRow, n: number): (string | number | null)[] {
  const pressure = r.working_pressure_value != null ? `${r.working_pressure_value} ${r.working_pressure_unit ?? ''}`.trim() : null
  const what = kind === 'hose' ? [r.description, pressure] : [r.manufacturer, r.model]
  return [n, r.place_name, ...what, r.replaced_serial, r.issued_serial, r.issued_code, equipmentReturnCell(r)]
}

export interface EquipmentIssueSheet { day: string; seq: number; name: string; rows: EquipmentIssueSheetRow[] }

/** Places in the order they were issued to, then by issue time. */
function orderRows(rows: EquipmentIssueSheetRow[]): EquipmentIssueSheetRow[] {
  const firstAt = new Map<string, string>()
  for (const r of rows) {
    const seen = firstAt.get(r.place_name)
    if (seen === undefined || r.issued_at < seen) firstAt.set(r.place_name, r.issued_at)
  }
  return [...rows].sort(byValues<EquipmentIssueSheetRow>((r) => firstAt.get(r.place_name) ?? null, (r) => r.place_name, (r) => r.issued_at))
}

/** The sheets already exported, newest day first and, within a day, the latest export first. */
export function groupEquipmentSheets(rows: EquipmentIssueSheetRow[], region: string): EquipmentIssueSheet[] {
  const by = new Map<string, EquipmentIssueSheet>()
  for (const r of rows) {
    if (r.sheet_id === null || r.sheet_seq === null) continue
    let s = by.get(r.sheet_id)
    if (!s) { s = { day: r.issue_day, seq: r.sheet_seq, name: sheetName(region, r.issue_day, r.sheet_seq), rows: [] }; by.set(r.sheet_id, s) }
    s.rows.push(r)
  }
  return [...by.values()]
    .map((s) => ({ ...s, rows: orderRows(s.rows) }))
    .sort((a, b) => (a.day === b.day ? b.seq - a.seq : b.day.localeCompare(a.day)))
}

/** The days whose issues are on no sheet yet, and the sheet each would become. */
export function pendingEquipmentSheets(rows: EquipmentIssueSheetRow[], region: string): { day: string; name: string; count: number }[] {
  const lastSeq = new Map<string, number>()
  const pending = new Map<string, number>()
  for (const r of rows) {
    if (r.sheet_seq !== null) lastSeq.set(r.issue_day, Math.max(lastSeq.get(r.issue_day) ?? 0, r.sheet_seq))
    else pending.set(r.issue_day, (pending.get(r.issue_day) ?? 0) + 1)
  }
  return [...pending.entries()].sort(([a], [b]) => a.localeCompare(b))
    .map(([day, count]) => ({ day, count, name: sheetName(region, day, (lastSeq.get(day) ?? 0) + 1) }))
}

const WIDTHS = [3.73, 16, 18, 14, 16, 16, 12, 14.5]
const GREY = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFA6A6A6' } } as const
const THIN = { style: 'thin' } as const
const BOX = { top: THIN, left: THIN, bottom: THIN, right: THIN }
const CENTER = { horizontal: 'center', vertical: 'middle', wrapText: true } as const

export async function buildEquipmentIssueWorkbook(kind: EquipmentKind, region: string, sheets: EquipmentIssueSheet[]): Promise<Blob> {
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  const headers = equipmentHeaders(kind)
  for (const sheet of sheets) {
    const ws = wb.addWorksheet(sheet.name)
    WIDTHS.forEach((w, i) => { ws.getColumn(i + 1).width = w })
    ws.mergeCells('A1:H1')
    Object.assign(ws.getCell('A1'), { value: NOUN[kind].title, font: { bold: true, size: 18 }, alignment: CENTER })
    ws.mergeCells('A2:D2')
    Object.assign(ws.getCell('A2'), { value: `تاريخ الصرف من المخزن : ${sheetDate(sheet.day)}`, font: { size: 11 }, alignment: CENTER })
    ws.mergeCells('F2:H2')
    Object.assign(ws.getCell('F2'), { value: `المنطقة : ${regionArabic(region)}`, font: { size: 11 }, alignment: CENTER })
    ws.getRow(1).height = 40
    ws.getRow(2).height = 45
    const head = ws.getRow(3)
    head.height = 29
    headers.forEach((h, i) => {
      Object.assign(head.getCell(i + 1), { value: h || null, font: { bold: true, size: 11 }, fill: GREY, alignment: CENTER, border: BOX })
    })
    sheet.rows.forEach((r, i) => {
      const row = ws.getRow(4 + i)
      row.height = 23.5
      // Serials and codes stay TEXT, so leading zeros and dashes survive.
      equipmentSheetCells(kind, r, i + 1).forEach((v, n) => {
        Object.assign(row.getCell(n + 1), { value: v === '' ? null : v, font: { size: 11 }, alignment: CENTER, border: BOX })
      })
      if (r.is_cancelled) row.getCell(8).font = { size: 11, bold: true, color: { argb: 'FFC00000' } }
    })
    ws.pageSetup = {
      paperSize: 9, orientation: 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0, horizontalCentered: true,
      margins: { left: 0.25, right: 0.25, top: 0.5, bottom: 0.5, header: 0, footer: 0 },
      printArea: `A1:H${3 + Math.max(sheet.rows.length, 1)}`, printTitlesRow: '1:3',
    }
  }
  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

/** "صرف خراطيم شرق 10-2026.xlsx" */
export function equipmentIssueWorkbookName(kind: EquipmentKind, region: string, month: string): string {
  const [y, m] = month.split('-').map(Number)
  return `صرف ${NOUN[kind].file} ${regionArabic(region)} ${m}-${y}.xlsx`
}
