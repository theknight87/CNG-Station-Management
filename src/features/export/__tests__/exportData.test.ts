// @vitest-environment node
import ExcelJS from 'exceljs'
import { describe, expect, it } from 'vitest'

import { INSTALLED_SRV_COLUMNS, pressureValue } from '@/features/export/exportColumns'
import { exportFileName, fetchAllRows, sheetName, toXlsx, xlsxCell } from '@/features/export/exportData'

/**
 * Table export (owner request 2026-09-29): what goes into the file, and how it is fetched.
 * The Excel file is generated and READ BACK, so the assertions are about the bytes a user opens.
 */

describe('export data', () => {
  it('EXP-1 fetches every page in 1,000-row chunks and stops at the first short page', async () => {
    const all = Array.from({ length: 2345 }, (_, i) => ({ id: i }))
    const asked: Array<[number, number]> = []
    const { rows, truncated } = await fetchAllRows(async (from, to) => { asked.push([from, to]); return { data: all.slice(from, to + 1), error: null } })
    expect(rows).toHaveLength(2345)
    expect(truncated).toBe(false)
    expect(asked).toEqual([[0, 999], [1000, 1999], [2000, 2999]])
  })

  it('EXP-2 stops at the ceiling and says so when more rows exist; a query error is thrown, never an empty file', async () => {
    const all = Array.from({ length: 30 }, (_, i) => ({ id: i }))
    const cut = await fetchAllRows(async (from, to) => ({ data: all.slice(from, to + 1), error: null }), 20)
    expect(cut.rows).toHaveLength(20)
    expect(cut.truncated).toBe(true)
    const exact = await fetchAllRows(async (from, to) => ({ data: all.slice(0, 20).slice(from, to + 1), error: null }), 20)
    expect(exact.truncated).toBe(false)
    await expect(fetchAllRows(async () => ({ data: null, error: { message: 'permission denied' } }))).rejects.toThrow('permission denied')
  })

  it('EXP-3 cells: NULL empty, numbers numeric, identifiers and formula-looking text stay text', () => {
    expect(xlsxCell(null)).toBeNull()
    expect(xlsxCell('')).toBeNull()
    expect(xlsxCell(-12, 'number')).toBe(-12)
    expect(xlsxCell('275', 'number')).toBe(275)
    expect(xlsxCell('270-280', 'number')).toBe('270-280')
    expect(xlsxCell('000123')).toBe('000123')
    expect(xlsxCell("=cmd|' /C calc'!A0")).toBe("=cmd|' /C calc'!A0")
  })

  it('EXP-4 set pressure: one value is a number, a legacy range stays as recorded, none falls back to the raw text', () => {
    expect(pressureValue({ pressure_min: 275, pressure_max: 275 })).toBe(275)
    expect(pressureValue({ pressure_min: 270, pressure_max: 280 })).toBe('270-280')
    expect(pressureValue({ pressure_min: null, pressure_max: null, set_pressure_raw: 'see plate' })).toBe('see plate')
    expect(pressureValue({ pressure_min: null, pressure_max: null, set_pressure_raw: null })).toBeNull()
  })

  it('EXP-5 file names are ASCII (Arabic transliterated) and sheet names are valid and unique', () => {
    expect(exportFileName('station-شبرا 1', 'xlsx', '2026-09-29')).toBe('cng-station-shbra-1-2026-09-29.xlsx')
    expect(exportFileName('unit-الماظة 2', 'csv', '2026-09-29')).toBe('cng-unit-almaza-2-2026-09-29.csv')
    expect(exportFileName('installed-srvs', 'csv', '2026-09-29')).toBe('cng-installed-srvs-2026-09-29.csv')
    const used = new Set<string>()
    expect(sheetName('Calibration (3rd party)', used)).toBe('Calibration (3rd party)')
    expect(sheetName('a/b:c', used)).toBe('a b c')
    expect(sheetName('Calibration (3rd party)', used)).toBe('Calibration (3rd party) 2')
    expect(sheetName('x'.repeat(40), used)).toHaveLength(31)
  })

  it('EXP-6 the Excel file reads back: Arabic intact, leading zeros kept, numbers numeric, no formula cells', async () => {
    const rows = [{
      region_name: 'Delta', station_name: 'شبرا', unit_name: 'شبرا 1', mapping_status: 'resolved', serial_number: '000123',
      pressure_min: 275, pressure_max: 275, pressure_unit: 'BAR', last_calibration_display: '2025', next_calibration_display: null,
      days_left: -12, due_status: 'overdue', notes: "=cmd|' /C calc'!A0",
    }]
    const blob = await toXlsx([{ name: 'Installed SRVs', columns: INSTALLED_SRV_COLUMNS, rows }, { name: 'Empty', columns: INSTALLED_SRV_COLUMNS, rows: [] }])
    const wb = new ExcelJS.Workbook()
    await wb.xlsx.load(await blob.arrayBuffer())
    expect(wb.worksheets.map((w) => w.name)).toEqual(['Installed SRVs', 'Empty'])
    const ws = wb.getWorksheet('Installed SRVs')!
    const header = ws.getRow(1).values as unknown[]
    const cell = (h: string) => ws.getRow(2).getCell(header.indexOf(h))
    expect(cell('Station').value).toBe('شبرا')
    expect(cell('Serial').value).toBe('000123')
    expect(cell('Set pressure').value).toBe(275)
    expect(cell('Days left').value).toBe(-12)
    expect(cell('Due status').value).toBe('Overdue')
    expect(cell('Last calibration').value).toBe('2025')
    expect(cell('Next calibration').value).toBeNull()
    expect(cell('Notes').type).toBe(ExcelJS.ValueType.String)
    expect(cell('Notes').formula).toBeUndefined()
    expect(wb.getWorksheet('Empty')!.rowCount).toBe(1)
  })
})
