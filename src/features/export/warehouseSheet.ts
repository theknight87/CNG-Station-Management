import { formPressure } from '@/features/export/calibrationForm'
import { manufacturerFill, sheetDateValue } from '@/features/export/installedSheet'
import { AVAILABILITY_LABEL } from '@/features/relief-valves/availabilityLabels'
import { cairoBusinessDate } from '@/features/reports/csv'
import type { WarehouseSrvRow } from '@/features/relief-valves/useSrvManagement'

/**
 * Warehouse SRVs in the owner's store sheet (owner request 2026-10-04, template "رصيد المخزن" of
 * Warehouse_Relief_Data.xlsx): title "Warehouse Relief Valves Data", the template's seventeen columns as an Excel
 * table (TableStyleMedium6, banded, filter buttons), its manufacturer and availability colours, repeated serials
 * marked, and days left under 30 shown red.
 *
 * Every value comes from the record; nothing is filled in:
 *   Availability     the store's own wording (owner ruling 2026-10-02, availabilityLabels.ts), coloured as in the template
 *   Dates            an exact date is a real date; a year-only date is written as its year; unknown stays empty
 *   Days Left        live in Excel (Next Calibration Date − TODAY()) for an exact next date only — principle 13
 *   Area / Station   the destination Region and Station; a destination no Station matches is written as the sheet
 *                    named it; unassigned stock leaves both empty
 *   Notes            the record's notes, then the source status text when the source gave one
 *   Set Pressure     coloured by value so equal pressures read as one group (the template colours them by hand)
 */

const TITLE = 'Warehouse Relief Valves Data'
const HEADERS = ['Set Pressure', 'Manufacturer', 'Availability Status', 'Serial Number', 'Size Type', 'IN', 'OUT', 'Part Number',
  'Last Calibration Date', 'Next Calibration Date', 'Days Left', 'Warehouse Code', 'Warehouse Issue Date', 'Area', 'Station',
  'Calibration Location', 'Notes']
const WIDTHS = [10.18, 19.45, 17.54, 17.82, 14.45, 14.45, 6.73, 18.54, 17.45, 17.45, 9.82, 13.82, 12.27, 12.82, 12, 13.54, 26.54]
const HEAD = 5
const FIRST = 6

/** The template's availability colours (its conditional formats on the status column). */
const AVAILABILITY_FILL: Record<string, string> = {
  available_new: 'FFB4C6E7', available_calibrated: 'FF00B0F0', available_in_store_uc: 'FFFFEB9C',
  sent_to_station_received: 'FFC6EFCE', sent_to_station_not_received: 'FFFFC7CE',
}
export function availabilityFill(status: string | null): string | null {
  return status ? AVAILABILITY_FILL[status] ?? null : null
}

/** Light colours from the template's Set Pressure column, handed out in order of first appearance. */
const PRESSURE_PALETTE = ['FFFFFF00', 'FF99CCFF', 'FF92D050', 'FFFF9933', 'FFFF99FF', 'FFFFC000', 'FFFFFF99', 'FF99FF66',
  'FFFFCCFF', 'FF00B0F0', 'FFFFFFCC', 'FFCCCC00']
export function pressureFills(labels: (string | null)[]): Map<string, string> {
  const fills = new Map<string, string>()
  for (const l of labels) if (l && !fills.has(l)) fills.set(l, PRESSURE_PALETTE[fills.size % PRESSURE_PALETTE.length])
  return fills
}

export function warehouseStation(r: Pick<WarehouseSrvRow, 'is_unassigned_stock' | 'target_station_name' | 'target_station_raw'>): string | null {
  return r.is_unassigned_stock ? null : r.target_station_name ?? r.target_station_raw ?? null
}

export function warehouseNotes(r: Pick<WarehouseSrvRow, 'notes' | 'source_status_raw'>): string | null {
  const parts = [r.notes?.trim(), r.source_status_raw?.trim()].filter((p): p is string => Boolean(p))
  return parts.length ? parts.join(' — ') : null
}

function exactDate(iso: string | null): Date | null {
  if (!iso) return null
  const [y, m, d] = iso.slice(0, 10).split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d))
}

export async function buildWarehouseWorkbook(rows: WarehouseSrvRow[]): Promise<Blob> {
  const { default: ExcelJS } = await import('exceljs')
  const wb = new ExcelJS.Workbook()
  wb.creator = 'CNG Station Management'
  const ws = wb.addWorksheet('رصيد المخزن', {
    views: [{ state: 'frozen', ySplit: HEAD, zoomScale: 70 }],
    pageSetup: { paperSize: 9, orientation: 'landscape', fitToPage: true, fitToWidth: 1, fitToHeight: 0, horizontalCentered: true },
  })
  WIDTHS.forEach((w, i) => { ws.getColumn(i + 1).width = w })
  const center = { horizontal: 'center', vertical: 'middle', wrapText: true } as const
  const solid = (argb: string) => ({ type: 'pattern', pattern: 'solid', fgColor: { argb } }) as const

  ws.mergeCells('C1:O3')
  Object.assign(ws.getCell('C1'), { value: TITLE, font: { name: 'Calibri', size: 28, bold: true }, fill: solid('FFA6A6A6'), alignment: center })
  ws.getRow(4).height = 18.5
  ws.getRow(HEAD).height = 48

  const labels = rows.map((r) => formPressure(r))
  const pressureFill = pressureFills(labels)
  const values = rows.map((r, i) => {
    const n = FIRST + i
    const exactNext = r.next_calibration_precision === 'exact_date' && r.next_calibration_date
    return [
      labels[i], r.manufacturer, r.availability_status ? AVAILABILITY_LABEL[r.availability_status] ?? r.availability_status : null,
      r.serial_number, r.size_type, r.inlet_size, r.outlet_size, r.part_number,
      sheetDateValue(r.last_calibration_date, r.last_calibration_precision, r.last_calibration_display),
      sheetDateValue(r.next_calibration_date, r.next_calibration_precision, r.next_calibration_display),
      exactNext ? { formula: `J${n}-TODAY()`, result: r.days_left ?? undefined } : null,
      r.warehouse_code, exactDate(r.warehouse_issue_date), r.target_region_name, warehouseStation(r), r.calibration_location,
      warehouseNotes(r),
    ].map((v) => (v === '' || v === undefined ? null : v))
  })

  const headFont = { name: 'Calibri', size: 12, bold: true }
  if (rows.length > 0) {
    ws.addTable({
      name: 'WarehouseReliefValves', ref: `A${HEAD}`, headerRow: true, totalsRow: false,
      style: { theme: 'TableStyleMedium6', showRowStripes: true },
      columns: HEADERS.map((name) => ({ name, filterButton: true })),
      rows: values as never,
    })
  } else {
    HEADERS.forEach((h, i) => { ws.getRow(HEAD).getCell(i + 1).value = h })
  }
  HEADERS.forEach((_, i) => Object.assign(ws.getRow(HEAD).getCell(i + 1), { font: headFont, alignment: center }))

  rows.forEach((r, i) => {
    const row = ws.getRow(FIRST + i)
    row.height = 29.15
    for (let c = 1; c <= HEADERS.length; c++) {
      const cell = row.getCell(c)
      cell.font = { name: 'Calibri', size: 11, bold: true }
      cell.alignment = center
    }
    const pf = labels[i] ? pressureFill.get(labels[i] as string) : undefined
    if (pf) row.getCell(1).fill = solid(pf)
    const mf = manufacturerFill(r.manufacturer)
    if (mf) row.getCell(2).fill = solid(mf)
    const af = availabilityFill(r.availability_status)
    if (af) row.getCell(3).fill = solid(af)
    for (const c of [9, 10, 13]) row.getCell(c).numFmt = 'dd/mm/yyyy'
    row.getCell(11).numFmt = '0'
  })

  if (rows.length > 0) {
    const last = FIRST + rows.length - 1
    const red = { fill: { type: 'pattern', pattern: 'solid', bgColor: { argb: 'FFFFC7CE' } }, font: { color: { argb: 'FF9C0006' }, bold: true } } as const
    ws.addConditionalFormatting({
      ref: `K${FIRST}:K${last}`,
      rules: [{ type: 'expression', priority: 1, formulae: [`AND(ISNUMBER(K${FIRST}),K${FIRST}<30)`], style: red }],
    })
    // A serial recorded more than once is shown, never merged (principle 16) — as the template marks it.
    ws.addConditionalFormatting({
      ref: `D${FIRST}:D${last}`,
      rules: [{ type: 'expression', priority: 2, formulae: [`AND(D${FIRST}<>"",COUNTIF($D$${FIRST}:$D$${last},D${FIRST})>1)`], style: red }],
    })
  }

  const buffer = await wb.xlsx.writeBuffer()
  return new Blob([buffer], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' })
}

/** "Warehouse Relief Valves Data 2026-10-04.xlsx" — the sheet's own title and the day, never the template's file name. */
export function warehouseWorkbookName(today: string = cairoBusinessDate()): string {
  return `${TITLE} ${today}.xlsx`
}
