import type { SupabaseClient } from '@supabase/supabase-js'

import { cairoBusinessDate } from '@/features/reports/csv'
import { byValues, pressureBar } from '@/features/relief-valves/srvSort'
import type { CalibrationRow } from '@/features/relief-valves/useSrvWorkflow'

/**
 * The 3rd party calibration list as the owner's paper form (owner request 2026-09-29, template
 * "4-6-2026 ساناجاس"): "نموذج طلب قطع غيار للشئون الهندسية", form code NGV PC 2-1/23, Station and Date once at
 * the top, one row per valve, then the storekeeper / responsible-engineer signature block.
 *
 * The header and footer text is the owner's form, reproduced as supplied. The rows come from the database:
 *   Set Pressure  the valve's one set pressure with its unit (a legacy range stays as recorded)
 *   P/N           part number
 *   Model         the manufacturer — what the owner's form records in this column
 *   S/N           serial, kept as TEXT so leading zeros survive
 *   Stock Code    warehouse code, exactly as recorded
 *   Remarks       always empty, for hand-written notes
 *   Station       the station the valve came BACK from, taken from its SRV Log return record. A valve that never
 *                 came back through the SRV Log (e.g. stock from the source workbook) has no recorded origin and
 *                 the cell stays EMPTY — it is never filled from a destination or a guess.
 */

export type CalibrationFormRow = CalibrationRow & { origin_station: string | null }

const TITLE = '  نموذج طلب قطع غيار للشئون الهندسية'
const FORM_CODE = 'NGV PC 2-1/23'
const STATION_LINE = 'Station :__SANA GAS________________'
const HEADERS = ['Item N.o', 'Set Pressure', 'P/N', 'Model', 'S/N', 'Stock Code', 'Remarks', 'Station']
const WIDTHS = [9.45, 23.27, 21.45, 21.45, 26.18, 12.73, 15.18, 19.82]
const GREY = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFBFBFBF' } } as const
const THIN = { style: 'thin' } as const
const BOX = { top: THIN, left: THIN, bottom: THIN, right: THIN }
const CENTER = { horizontal: 'center', vertical: 'middle', wrapText: true } as const

/** `4/6/2026` — day/month/year without padding, as the form writes it. */
export function formDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  return `${d}/${m}/${y}`
}

/** The form's date: the common "sent" date of the rows when they share one, otherwise today (Cairo). */
export function formIsoDate(rows: Pick<CalibrationRow, 'sent_at'>[], today: string = cairoBusinessDate()): string {
  const days = new Set(rows.map((r) => (r.sent_at ?? '').slice(0, 10)).filter(Boolean))
  return days.size === 1 ? [...days][0] : today
}

export function formPressure(r: Pick<CalibrationRow, 'pressure_min' | 'pressure_max' | 'pressure_unit' | 'set_pressure_raw'>): string | null {
  const { pressure_min: min, pressure_max: max, pressure_unit: unit } = r
  const value = min === null && max === null ? null : min !== null && max !== null && min !== max ? `${min}-${max}` : String(min ?? max)
  if (value === null) return r.set_pressure_raw ?? null
  return unit ? `${value} ${unit}` : value
}

/** The station each valve last came back from (SRV Log return record), keyed by warehouse valve id. */
export async function loadOriginStations(supabase: SupabaseClient, valveIds: string[]): Promise<Map<string, string>> {
  const origin = new Map<string, string>()
  const ids = [...new Set(valveIds)]
  for (let i = 0; i < ids.length; i += 100) {
    const { data, error } = await supabase
      .from('v_srv_field_log')
      .select('returned_warehouse_valve_id, station_display, returned_at')
      .in('returned_warehouse_valve_id', ids.slice(i, i + 100))
      .order('returned_at', { ascending: false })
    if (error) throw new Error(error.message)
    for (const r of (data ?? []) as Array<{ returned_warehouse_valve_id: string; station_display: string | null }>) {
      if (r.station_display && !origin.has(r.returned_warehouse_valve_id)) origin.set(r.returned_warehouse_valve_id, r.station_display)
    }
  }
  return origin
}

/** Rows in the table's own default order: set pressure, smallest first (BAR and PSI on one scale). */
export function orderForForm<T extends CalibrationRow>(rows: T[]): T[] {
  return [...rows].sort(byValues<T>(pressureBar))
}

export async function buildCalibrationForm(rows: CalibrationFormRow[], isoDate: string): Promise<Blob> {
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  const ws = wb.addWorksheet(`${formDate(isoDate).replace(/\//g, '-')} ساناجاس`.slice(0, 31))
  WIDTHS.forEach((w, i) => { ws.getColumn(i + 1).width = w })

  const heading = (range: string, text: string, font: object, alignment: object = CENTER) => {
    ws.mergeCells(range)
    const cell = ws.getCell(range.split(':')[0])
    cell.value = text
    cell.font = font
    cell.alignment = alignment
  }

  // Header, as on the owner's form.
  heading('A1:H2', TITLE, { bold: true, size: 16 })
  ws.getRow(1).height = 21
  ws.getRow(2).height = 18.65
  ws.getRow(3).height = 18.65
  // Centred across the whole form (owner request 2026-09-29).
  heading('A3:H3', FORM_CODE, { bold: true, size: 16 })
  ws.getRow(4).height = 14.5
  ws.getRow(5).height = 15
  heading('A4:C5', STATION_LINE, { size: 16 })
  heading('E4:G5', `Date : ${formDate(isoDate)}`, { size: 16 })

  // Table.
  const head = ws.getRow(6)
  head.height = 30
  HEADERS.forEach((h, i) => {
    const c = head.getCell(i + 1)
    c.value = h
    c.font = { bold: true, size: 11 }
    c.fill = GREY
    c.alignment = CENTER
    c.border = BOX
  })
  rows.forEach((r, i) => {
    const row = ws.getRow(7 + i)
    row.height = 35.15
    const values = [i + 1, formPressure(r), r.part_number, r.manufacturer, r.serial_number, r.warehouse_code, null, r.origin_station]
    values.forEach((v, n) => {
      const c = row.getCell(n + 1)
      c.value = v === null || v === undefined || v === '' ? null : v
      c.font = { bold: true, size: n === 0 ? 11 : 12 }
      c.alignment = CENTER
      c.border = BOX
      if (n === 0) c.fill = GREY
    })
  })

  // Footer (signatures), one empty row below the table.
  const f = 7 + rows.length + 1
  // Rows taller than the template's so the titles and names are never clipped (owner request 2026-09-29).
  const MID = { horizontal: 'center', vertical: 'middle' } as const
  heading(`A${f}:C${f}`, 'أمين المخزن', { bold: true, size: 18 }, MID)
  heading(`F${f}:H${f}`, 'المهندس المسئول', { bold: true, size: 18 }, MID)
  ws.getRow(f).height = 36
  ws.getRow(f + 1).height = 12
  heading(`A${f + 2}:C${f + 2}`, ' الاســم  : ________________________', { size: 14 }, MID)
  heading(`F${f + 2}:H${f + 2}`, '        الإسم :    إسلام فارس سعيد', { size: 16 }, { horizontal: 'right', vertical: 'middle' })
  ws.getRow(f + 2).height = 32
  for (const [offset, text] of [[4, ' التوقيع : ________________________'], [6, ' التاريخ : ________________________']] as const) {
    heading(`A${f + offset}:C${f + offset}`, text, { size: 14 }, MID)
    heading(`F${f + offset}:H${f + offset}`, text, { size: 14 }, MID)
    ws.getRow(f + offset - 1).height = 12
    ws.getRow(f + offset).height = 32
  }

  // Print like the original: A4 portrait, one page wide, header rows repeated, centred.
  ws.pageSetup = {
    paperSize: 9, orientation: 'portrait', fitToPage: true, fitToWidth: 1, fitToHeight: 0, horizontalCentered: true,
    margins: { left: 0.25, right: 0.25, top: 0.5, bottom: 0.5, header: 0, footer: 0 },
    printArea: `A1:H${f + 6}`, printTitlesRow: '1:6',
  }

  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}
