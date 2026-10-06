// @vitest-environment node
import ExcelJS from 'exceljs'
import { describe, expect, it } from 'vitest'

import {
  buildIssueWorkbook, groupSheets, issueWorkbookName, monthRange, pendingSheets, sheetName, sheetSize, type IssueSheetRow,
} from '@/features/export/issueSheet'

/**
 * The warehouse issue workbook (owner request 2026-10-03, templates "شرق" / "غرب" March 2026): one sheet per issue day,
 * a later export the same day is "<date> (2)", and sheets already sent are written again unchanged.
 */

const issue = (over: Partial<IssueSheetRow>): IssueSheetRow => ({
  id: 'i', issued_at: '2026-10-05T07:00:00Z', issue_day: '2026-10-05', region_id: 'r-east', region_name: 'East',
  sheet_id: null, sheet_seq: null, sheet_exported_at: null, is_emergency: false, station_name: 'شبرا', unit_name: 'شبرا 1',
  place_name: 'شبرا 1', location: 'Stage', warehouse_valve_id: 'w', issued_serial: null, issued_code: null,
  manufacturer: null, size_type: 'Male', inlet_size: '1/2"', outlet_size: '1"', set_pressure_raw: null, pressure_min: null,
  pressure_max: null, pressure_unit: null, replaced_installed_valve_id: null, replaced_serial: null, replaced_returned_at: null,
  is_cancelled: false, cancelled_at: null, cancelled_returned_at: null, transferred_to: null, transferred_at: null,
  ...over,
})

const month = [
  // 5 Oct, first export (sheet s1): storage at the Station, two stage valves at شبرا 1 out of pressure order.
  issue({ id: 'a', sheet_id: 's1', sheet_seq: 1, issued_at: '2026-10-05T07:00:00Z', issued_serial: '668281', issued_code: 'GCC 013',
    manufacturer: 'Mercer', pressure_min: 400, pressure_max: 400, pressure_unit: 'PSI', replaced_serial: '668282' }),
  issue({ id: 'b', sheet_id: 's1', sheet_seq: 1, issued_at: '2026-10-05T07:01:00Z', issued_serial: '60120', issued_code: 'ACC 191',
    manufacturer: 'Mercer', pressure_min: 275, pressure_max: 275, pressure_unit: 'PSI', replaced_serial: '00237062',
    replaced_returned_at: '2026-10-20T09:00:00Z' }),
  issue({ id: 'c', sheet_id: 's1', sheet_seq: 1, issued_at: '2026-10-05T06:59:00Z', place_name: 'شبرا', location: 'Storage',
    issued_serial: 'A79405', manufacturer: 'Mercer', size_type: 'flange', inlet_size: '1"', outlet_size: '1-1/4"',
    pressure_min: 5500, pressure_max: 5500, pressure_unit: 'PSI' }),
  // 5 Oct, second export (sheet s2), and 3 Oct (sheet s3).
  issue({ id: 'd', sheet_id: 's2', sheet_seq: 2, issued_at: '2026-10-05T10:00:00Z', issued_serial: '21-03063' }),
  issue({ id: 'e', sheet_id: 's3', sheet_seq: 1, issue_day: '2026-10-03', issued_at: '2026-10-03T09:00:00Z', issued_serial: '258248' }),
]

async function readBack(blob: Blob) {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(await blob.arrayBuffer())
  return wb
}

describe('warehouse issue workbook', () => {
  it('ISH-1 sheet names: "East 5-10-2026", a later export the same day "(2)", newest day and latest export first', () => {
    expect(sheetName('East', '2026-10-05', 1)).toBe('East 5-10-2026')
    expect(sheetName('West', '2026-03-02', 3)).toBe('West 2-3-2026 (3)')
    expect(groupSheets(month, 'East').map((s) => s.name)).toEqual(['East 5-10-2026 (2)', 'East 5-10-2026', 'East 3-10-2026'])
  })

  it('ISH-2 a new export of a day that already has a sheet becomes the next number; other days start at 1', () => {
    const later = [...month,
      issue({ id: 'f', issued_at: '2026-10-05T13:00:00Z' }), issue({ id: 'g', issued_at: '2026-10-05T13:05:00Z' }),
      issue({ id: 'h', issue_day: '2026-10-07', issued_at: '2026-10-07T08:00:00Z' })]
    expect(pendingSheets(later, 'East')).toEqual([
      { day: '2026-10-05', name: 'East 5-10-2026 (3)', count: 2 },
      { day: '2026-10-07', name: 'East 7-10-2026', count: 1 },
    ])
    expect(pendingSheets(month, 'East')).toEqual([])
  })

  it('ISH-3 rows: places in the order issued to, Stage before Storage, lowest set pressure first', () => {
    const [, first] = groupSheets(month, 'East')
    expect(first.rows.map((r) => r.id)).toEqual(['c', 'b', 'a'])
    const mixed = groupSheets([
      issue({ id: 'st', sheet_id: 'x', sheet_seq: 1, location: 'Storage', pressure_min: 300, pressure_max: 300, pressure_unit: 'BAR' }),
      issue({ id: 'hi', sheet_id: 'x', sheet_seq: 1, pressure_min: 275, pressure_max: 275, pressure_unit: 'BAR' }),
      issue({ id: 'lo', sheet_id: 'x', sheet_seq: 1, pressure_min: 600, pressure_max: 600, pressure_unit: 'PSI' }),
    ], 'East')[0]
    expect(mixed.rows.map((r) => r.id)).toEqual(['lo', 'hi', 'st'])
  })

  it('ISH-4 the sheet as the owner keeps it: title, date, Region in Arabic, headers, and the columns from the record', async () => {
    const wb = await readBack(await buildIssueWorkbook('East', groupSheets(month, 'East')))
    expect(wb.worksheets.map((w) => w.name)).toEqual(['East 5-10-2026 (2)', 'East 5-10-2026', 'East 3-10-2026'])
    const ws = wb.getWorksheet('East 5-10-2026')!
    expect(ws.getCell('A1').value).toBe('بيانات صرف صمامات أمان معايرة')
    expect(ws.getCell('A2').value).toBe('تاريخ الصرف من المخزن : 05/10/2026')
    expect(ws.getCell('H2').value).toBe('المنطقة : شرق')
    expect([2, 3, 4, 5, 6, 7, 8, 9, 10].map((c) => ws.getRow(3).getCell(c).value)).toEqual([
      'الضغط', 'الموقع', 'المحطة', 'المقاس', 'الموديل', 'رقم الصمام في المحطة', 'رقم الصمام المعاير في المخزن', 'الكود المخزني', 'تاريخ الرجوع للمخزن'])
    const cells = (n: number) => Array.from({ length: 10 }, (_, c) => ws.getRow(n).getCell(c + 1).value)
    expect(cells(4)).toEqual([1, '5500 PSI', 'Storage', 'شبرا', 'Flange 1 X 1-1/4', 'Mercer', null, 'A79405', null, null])
    // Serials stay text (the leading zeros survive); the return date is written once the replaced valve is back.
    expect(cells(5)).toEqual([2, '275 PSI', 'Stage', 'شبرا 1', '1/2 X 1', 'Mercer', '00237062', '60120', 'ACC 191', '20/10/2026'])
    expect(ws.getRow(6).getCell(7).value).toBe('668282')
    expect(ws.getCell('A1').isMerged && ws.getCell('J1').isMerged).toBe(true)
  })

  it('ISH-5 unrecorded values stay empty: no location, no replaced valve, no size', async () => {
    expect(sheetSize({ size_type: null, inlet_size: null, outlet_size: null })).toBeNull()
    const rows = groupSheets([issue({ id: 'z', sheet_id: 'x', sheet_seq: 1, location: null, size_type: null, inlet_size: null, outlet_size: null })], 'Delta')
    const ws = (await readBack(await buildIssueWorkbook('Delta', rows))).worksheets[0]
    expect([2, 3, 5, 6, 7, 8, 9, 10].map((c) => ws.getRow(4).getCell(c).value)).toEqual([null, null, null, null, null, null, null, null])
    expect(ws.getCell('H2').value).toBe('المنطقة : دلتا')
  })

  it('ISH-7 an issue undone after it left the warehouse stays on its sheet, "ملغي" in red in the return column; no Notes column', async () => {
    const rows = groupSheets([
      issue({ id: 'k', sheet_id: 'x', sheet_seq: 1, issued_serial: 'LIVE' }),
      issue({ id: 'c', sheet_id: 'x', sheet_seq: 1, issued_at: '2026-10-05T08:00:00Z', issued_serial: 'UNDONE', replaced_serial: 'OLD',
        replaced_returned_at: null, is_cancelled: true, cancelled_at: '2026-10-06T21:30:00Z', cancelled_returned_at: '2026-10-08T09:00:00Z' }),
      issue({ id: 'w', sheet_id: 'x', sheet_seq: 1, issued_at: '2026-10-05T09:00:00Z', issued_serial: 'WAIT', is_cancelled: true,
        cancelled_at: '2026-10-06T08:00:00Z', replaced_returned_at: '2026-10-07T09:00:00Z' }),
    ], 'East')
    const ws = (await readBack(await buildIssueWorkbook('East', rows))).worksheets[0]
    expect(ws.getRow(3).getCell(11).value).toBeNull()
    expect(ws.getRow(3).getCell(10).value).toBe('تاريخ الرجوع للمخزن')
    expect(ws.getRow(4).getCell(10).value).toBeNull()
    expect(ws.getRow(5).getCell(10).value).toBe('ملغي - 08/10/2026')
    expect(ws.getRow(5).getCell(10).font?.color?.argb).toBe('FFC00000')
    // Not back yet: "ملغي" alone (the replaced valve's return date belongs to a cancelled issue no more).
    expect(ws.getRow(6).getCell(10).value).toBe('ملغي')
    expect(ws.getRow(5).getCell(11).value).toBeNull()
    expect(ws.getCell('J1').isMerged).toBe(true)
    expect(ws.getCell('K1').isMerged).toBe(false)
  })

  it('ISH-8 a valve moved on to another Station reads as issued straight there: no "محول إلى" note (owner 2026-10-06)', async () => {
    // The view gives the final Station, position and the valve it replaced there; the row writes them as any issue.
    const rows = groupSheets([
      issue({ id: 't', sheet_id: 'x', sheet_seq: 1, issued_serial: '21-00483', place_name: 'شطا', replaced_serial: '22-00091',
        replaced_returned_at: null, transferred_to: 'شطا', transferred_at: '2026-10-06T10:00:00Z' }),
    ], 'Canal')
    const ws = (await readBack(await buildIssueWorkbook('Canal', rows))).worksheets[0]
    expect(ws.getRow(4).getCell(4).value).toBe('شطا')
    expect(ws.getRow(4).getCell(7).value).toBe('22-00091')
    expect(ws.getRow(4).getCell(8).value).toBe('21-00483')
    expect(ws.getRow(4).getCell(10).value).toBeNull()
  })

  it('ISH-6 month range and file name', () => {
    expect(monthRange('2026-10')).toEqual({ from: '2026-10-01', to: '2026-11-01' })
    expect(monthRange('2026-12')).toEqual({ from: '2026-12-01', to: '2027-01-01' })
    expect(issueWorkbookName('West', '2026-03')).toBe('صرف غرب 3-2026.xlsx')
  })
})
