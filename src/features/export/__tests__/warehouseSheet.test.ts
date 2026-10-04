// @vitest-environment node
import ExcelJS from 'exceljs'
import { describe, expect, it } from 'vitest'

import {
  availabilityFill, buildWarehouseWorkbook, pressureFills, warehouseStation, warehouseWorkbookName,
} from '@/features/export/warehouseSheet'
import type { WarehouseSrvRow } from '@/features/relief-valves/useSrvManagement'

/**
 * Warehouse SRVs in the owner's store sheet (template "رصيد المخزن", 2026-10-04): the template's title, seventeen
 * columns as an Excel table, its colours, every value from the record, nothing filled in.
 */

const valve = (over: Partial<WarehouseSrvRow>): WarehouseSrvRow => ({
  id: 'w', availability_status: null, warehouse_code: null, serial_number: null, serial_number_raw: null, serial_status: null,
  part_number: null, manufacturer: null, size_type: null, inlet_size: null, outlet_size: null, set_pressure_raw: null,
  pressure_min: null, pressure_max: null, pressure_unit: null, target_region_id: null, target_region_name: null,
  target_station_id: null, target_station_name: null, target_station_raw: null, is_unassigned_stock: false,
  updated_at: '2026-10-01T00:00:00Z', warehouse_issue_date: null, last_calibration_date: null, last_calibration_precision: 'unknown',
  last_calibration_display: null, next_calibration_date: null, next_calibration_precision: 'unknown', next_calibration_display: null,
  days_left: null, due_status: 'unknown', calibration_location: null, source_status_raw: null, needs_review: false, notes: null,
  ...over,
})

const rows = [
  valve({ id: 'a', availability_status: 'available_calibrated', serial_number: '0237062', part_number: 'SS-4R3A', manufacturer: 'Mercer',
    size_type: 'Male', inlet_size: '1/2"', outlet_size: '1"', pressure_min: 275, pressure_max: 275, pressure_unit: 'PSI',
    last_calibration_date: '2026-03-01', last_calibration_precision: 'exact_date', last_calibration_display: '2026-03-01',
    next_calibration_date: '2027-03-01', next_calibration_precision: 'exact_date', next_calibration_display: '2027-03-01', days_left: 148,
    warehouse_code: 'ACC 191', warehouse_issue_date: '2026-03-05', target_region_name: 'East', target_station_name: 'شبرا 1',
    calibration_location: 'Cargas', notes: 'checked', source_status_raw: 'منتهي' }),
  valve({ id: 'b', availability_status: 'sent_to_station_not_received', serial_number: '0237062', manufacturer: 'ekc',
    pressure_min: 300, pressure_max: 300, pressure_unit: 'BAR', target_region_name: 'Delta', target_station_raw: 'طنطا الجديدة',
    last_calibration_date: '2023-01-01', last_calibration_precision: 'year_only', last_calibration_display: '2023' }),
  valve({ id: 'c', is_unassigned_stock: true, target_station_name: 'ignored', pressure_min: 275, pressure_max: 275, pressure_unit: 'PSI' }),
]

async function sheet(input = rows) {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(await (await buildWarehouseWorkbook(input)).arrayBuffer())
  return wb.worksheets[0]
}
const cells = (ws: ExcelJS.Worksheet, n: number) => Array.from({ length: 17 }, (_, c) => ws.getRow(n).getCell(c + 1).value)

describe('warehouse SRVs workbook', () => {
  it('WHS-1 the template: sheet "رصيد المخزن", title C1:O3, seventeen headers on row 5 as a TableStyleMedium6 table', async () => {
    const ws = await sheet()
    expect(ws.name).toBe('رصيد المخزن')
    expect(ws.getCell('C1').value).toBe('Warehouse Relief Valves Data')
    expect(ws.getCell('C1').isMerged && ws.getCell('O3').isMerged).toBe(true)
    expect(cells(ws, 5)).toEqual(['Set Pressure', 'Manufacturer', 'Availability Status', 'Serial Number', 'Size Type', 'IN', 'OUT',
      'Part Number', 'Last Calibration Date', 'Next Calibration Date', 'Days Left', 'Warehouse Code', 'Warehouse Issue Date', 'Area',
      'Station', 'Calibration Location', 'Notes'])
    const table = (ws as unknown as { model: { tables: { tableRef: string; style: { theme: string } }[] } }).model.tables[0]
    expect(table.tableRef).toBe('A5:Q8')
    expect(table.style.theme).toBe('TableStyleMedium6')
  })

  it('WHS-2 values from the record: serial stays text, store wording, real dates, live days left, notes with source status', async () => {
    const ws = await sheet()
    const a = cells(ws, 6)
    expect(a.slice(0, 8)).toEqual(['275 PSI', 'Mercer', 'CALIBRATED', '0237062', 'Male', '1/2"', '1"', 'SS-4R3A'])
    expect((a[8] as Date).toISOString().slice(0, 10)).toBe('2026-03-01')
    expect((a[9] as Date).toISOString().slice(0, 10)).toBe('2027-03-01')
    expect(a[10]).toMatchObject({ formula: 'J6-TODAY()' })
    expect((a[12] as Date).toISOString().slice(0, 10)).toBe('2026-03-05')
    expect(a.slice(11, 12).concat(a.slice(13))).toEqual(['ACC 191', 'East', 'شبرا 1', 'Cargas', 'checked — منتهي'])
    expect(ws.getRow(6).getCell(9).numFmt).toBe('dd/mm/yyyy')
  })

  it('WHS-3 nothing filled in: a year-only date is its year, no days left without an exact date, unassigned stock has no destination', async () => {
    const ws = await sheet()
    const b = cells(ws, 7)
    expect(b[2]).toBe('IN TRANSIT')
    expect(b[8]).toBe('2023')
    expect(b[9]).toBeNull()
    expect(b[10]).toBeNull()
    expect(b[14]).toBe('طنطا الجديدة')
    const c = cells(ws, 8)
    expect(c[13]).toBeNull()
    expect(c[14]).toBeNull()
    expect(warehouseStation({ is_unassigned_stock: false, target_station_name: null, target_station_raw: null })).toBeNull()
  })

  it('WHS-4 colours: manufacturer and availability as in the template; equal pressures share one colour', async () => {
    const ws = await sheet()
    const fg = (r: number, c: number) => (ws.getRow(r).getCell(c).fill as ExcelJS.FillPattern | undefined)?.fgColor?.argb
    expect(fg(6, 2)).toBe('FFFBE4D5')
    expect(fg(7, 2)).toBe('FFDA8EDC')
    expect(fg(6, 3)).toBe(availabilityFill('available_calibrated'))
    expect(fg(7, 3)).toBe('FFFFC7CE')
    expect(fg(6, 1)).toBe(fg(8, 1))
    expect(fg(6, 1)).not.toBe(fg(7, 1))
    expect(pressureFills(['1 BAR', null, '2 BAR', '1 BAR']).size).toBe(2)
  })

  it('WHS-5 days left under 30 and a repeated serial are marked red; the file is named after the sheet, not the template', async () => {
    const ws = await sheet()
    const cf = (ws as unknown as { conditionalFormattings: { ref: string; rules: { formulae: string[] }[] }[] }).conditionalFormattings
    expect(cf.map((f) => f.ref)).toEqual(['K6:K8', 'D6:D8'])
    expect(cf[0].rules[0].formulae[0]).toBe('AND(ISNUMBER(K6),K6<30)')
    expect(cf[1].rules[0].formulae[0]).toContain('COUNTIF($D$6:$D$8,D6)>1')
    expect(warehouseWorkbookName('2026-10-04')).toBe('Warehouse Relief Valves Data 2026-10-04.xlsx')
  })

  it('WHS-6 an empty selection still writes the headers and no table', async () => {
    const ws = await sheet([])
    expect(ws.getRow(5).getCell(1).value).toBe('Set Pressure')
    expect(ws.getRow(6).getCell(1).value).toBeNull()
  })
})
