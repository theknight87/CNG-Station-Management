// @vitest-environment node
import ExcelJS from 'exceljs'
import { describe, expect, it } from 'vitest'

import {
  buildInstalledWorkbook, installedLocation, installedWorkbookName, manufacturerFill,
} from '@/features/export/installedSheet'
import type { InstalledSrvRow } from '@/features/relief-valves/useSrvManagement'

/**
 * Installed SRVs in the owner's station sheet (template "رصيد المحطات", 2026-10-03): the template's title, columns and
 * look, every value from the record, nothing filled in.
 */

const valve = (over: Partial<InstalledSrvRow>): InstalledSrvRow => ({
  id: 'v', region_id: 'r', region_name: 'East', station_id: 's', station_name: 'شبرا', source_station_name_raw: null,
  station_display: 'شبرا', needs_station_mapping: false, unit_id: null, unit_name: null, mapping_status: 'resolved',
  needs_mapping: false, mapping_label: null, expected_parent_kind: null, location_raw: null, parent_kind: null, parent_id: null,
  parent_label: null, tag_number: null, serial_number: null, serial_number_raw: null, serial_status: null, part_number: null,
  manufacturer: null, size_type: null, inlet_size: null, outlet_size: null, set_pressure_raw: null, pressure_min: null,
  pressure_max: null, pressure_unit: null, last_calibration_date: null, last_calibration_precision: 'unknown',
  last_calibration_display: null, next_calibration_date: null, next_calibration_precision: 'unknown',
  next_calibration_display: null, days_left: null, due_status: 'unknown', source_status_raw: null, needs_review: false,
  notes: null, source_file: null, source_sheet: null, source_row: null, warehouse_code: null, warehouse_code_source: null,
  ...over,
})

const rows = [
  valve({ id: 'a', unit_id: 'u', unit_name: 'شبرا 1', location_raw: 'Stage', pressure_min: 275, pressure_max: 275, pressure_unit: 'PSI',
    manufacturer: 'Mercer', serial_number: '0237062', size_type: 'Male', inlet_size: '3/4"', outlet_size: '1"',
    last_calibration_date: '2025-10-01', last_calibration_precision: 'exact_date', last_calibration_display: '2025-10-01',
    next_calibration_date: '2026-10-20', next_calibration_precision: 'exact_date', next_calibration_display: '2026-10-20', days_left: 17 }),
  valve({ id: 'b', parent_kind: 'storage_vessel', pressure_min: 300, pressure_max: 300, pressure_unit: 'BAR', manufacturer: 'technical',
    last_calibration_date: '2023-01-01', last_calibration_precision: 'year_only', last_calibration_display: '2023',
    next_calibration_date: '2024-01-01', next_calibration_precision: 'year_only', next_calibration_display: '2024',
    notes: 'replaced flange', source_status_raw: 'منتهي' }),
]

async function sheet() {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(await (await buildInstalledWorkbook(rows)).arrayBuffer())
  return wb.worksheets[0]
}
const cells = (ws: ExcelJS.Worksheet, n: number) => Array.from({ length: 14 }, (_, c) => ws.getRow(n).getCell(c + 1).value)

describe('installed SRVs station sheet', () => {
  it('INS-1 the template: sheet "رصيد المحطات", the title over B1:L3 and the fourteen headers on row 5', async () => {
    const ws = await sheet()
    expect(ws.name).toBe('رصيد المحطات')
    expect(ws.getCell('B1').value).toBe('Stations Safety Relief Valves Data')
    expect(ws.getCell('L3').isMerged).toBe(true)
    expect(cells(ws, 5)).toEqual(['Area', 'Station', 'Location', 'Set Pressure', 'Manufacturer', 'Serial Number', 'Size Type', 'IN',
      'OUT', 'Last Calibration Date', 'Next Calibration Date', 'Number Of Days Left', 'Next Calibration Month', 'Notes'])
  })

  it('INS-2 a row from the record: the Unit, exact dates as dates, days left live in Excel with today\'s figure', async () => {
    const ws = await sheet()
    const r = cells(ws, 6)
    expect(r.slice(0, 9)).toEqual(['East', 'شبرا 1', 'Stage', '275 PSI', 'Mercer', '0237062', 'Male', '3/4"', '1"'])
    expect((r[9] as Date).toISOString().slice(0, 10)).toBe('2025-10-01')
    expect((r[10] as Date).toISOString().slice(0, 10)).toBe('2026-10-20')
    expect(r[11]).toEqual({ formula: 'K6-TODAY()', result: 17 })
    expect((r[12] as Date).toISOString().slice(0, 10)).toBe('2026-10-20')
    expect(ws.getRow(6).getCell(13).numFmt).toBe('mmm-yy')
    expect(r[13]).toBeNull()
  })

  it('INS-3 year-only dates stay a year, with no days left or month; Station-level storage reads the Station; notes keep the source status', async () => {
    const r = cells(await sheet(), 7)
    expect(r.slice(0, 3)).toEqual(['East', 'شبرا', 'Storage'])
    expect(r.slice(9, 14)).toEqual(['2023', '2024', null, null, 'replaced flange — منتهي'])
  })

  it('INS-4 the look: manufacturer colours as the template (any case), banded rows, red under 30 days', async () => {
    const ws = await sheet()
    expect(manufacturerFill('TECHNICAL')).toBe('FF00B0F0')
    expect(manufacturerFill('Unknown maker')).toBeNull()
    expect((ws.getRow(6).getCell(5).fill as ExcelJS.FillPattern).fgColor?.argb).toBe('FFFBE4D5')
    expect((ws.getRow(7).getCell(5).fill as ExcelJS.FillPattern).fgColor?.argb).toBe('FF00B0F0')
    expect((ws.getRow(6).getCell(1).fill as ExcelJS.FillPattern).fgColor?.argb).toBe('FFDAE3F3')
    expect((ws.getRow(7).getCell(1).fill as ExcelJS.FillPattern | undefined)?.pattern ?? 'none').not.toBe('solid')
    const cf = (ws as unknown as { conditionalFormattings: { ref: string; rules: { formulae: string[] }[] }[] }).conditionalFormattings
    expect(cf[0].ref).toBe('L6:L7')
    expect(cf[0].rules[0].formulae[0]).toBe('AND(ISNUMBER(L6),L6<30)')
  })

  it('INS-5 location falls back to the parent only when none was recorded; the file is named after the sheet', () => {
    expect(installedLocation({ location_raw: ' Storage ', parent_kind: 'compressor', expected_parent_kind: null })).toBe('Storage')
    expect(installedLocation({ location_raw: null, parent_kind: null, expected_parent_kind: 'compressor' })).toBe('Stage')
    expect(installedLocation({ location_raw: null, parent_kind: null, expected_parent_kind: null })).toBeNull()
    expect(installedWorkbookName('2026-10-03')).toBe('Stations Safety Relief Valves Data 2026-10-03.xlsx')
  })
})
