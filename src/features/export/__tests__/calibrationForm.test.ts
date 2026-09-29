// @vitest-environment node
import { writeFileSync } from 'node:fs'
import ExcelJS from 'exceljs'
import { describe, expect, it } from 'vitest'

import {
  buildCalibrationForm, formDate, formIsoDate, formPressure, orderForForm, type CalibrationFormRow,
} from '@/features/export/calibrationForm'

/**
 * 3rd party calibration export in the owner's form (template "4-6-2026 ساناجاس", 2026-09-29): header and footer text
 * reproduced, one row per valve, Remarks empty, Station = where the valve came back from or EMPTY when unrecorded.
 */

const valve = (over: Partial<CalibrationFormRow>): CalibrationFormRow => ({
  id: 'j', status: 'sent', warehouse_valve_id: 'w', sent_at: '2026-06-04T08:00:00Z', returned_at: null, certified_at: null,
  certificate_date: null, certificate_number: null, next_calibration_date: null, serial_number: null, manufacturer: null,
  part_number: null, warehouse_code: null, size_type: null, inlet_size: null, outlet_size: null, set_pressure_raw: null,
  pressure_min: null, pressure_max: null, pressure_unit: null, origin_station: null, ...over,
})

const rows = [
  valve({ id: 'j1', serial_number: '1646858', part_number: '91-M1C61P1541', manufacturer: 'Mercer', warehouse_code: 'MBU 9',
    pressure_min: 4000, pressure_max: 4000, pressure_unit: 'PSI', origin_station: 'الشهداء 1 الدلتا' }),
  valve({ id: 'j2', serial_number: '000123', part_number: 'V64-MF-16N-4-C', manufacturer: 'DK-LOK', warehouse_code: 'QBU 0049',
    pressure_min: 17.7, pressure_max: 17.7, pressure_unit: 'BAR', origin_station: null }),
]

async function readBack(blob: Blob) {
  const wb = new ExcelJS.Workbook()
  await wb.xlsx.load(await blob.arrayBuffer())
  return wb.worksheets[0]
}

describe('calibration request form', () => {
  it('CALF-1 header: title, form code, Station and the date once, in the template cells', async () => {
    const ws = await readBack(await buildCalibrationForm(rows, '2026-06-04'))
    expect(ws.getCell('A1').value).toBe('  نموذج طلب قطع غيار للشئون الهندسية')
    expect(ws.getCell('E3').value).toBe('NGV PC 2-1/23')
    expect(ws.getCell('A4').value).toBe('Station :__SANA GAS________________')
    expect(ws.getCell('E4').value).toBe('Date : 4/6/2026')
    expect(ws.model.merges).toEqual(expect.arrayContaining(['A1:H2', 'A4:C5', 'E4:G5']))
    expect((ws.getRow(6).values as unknown[]).slice(1)).toEqual(['Item N.o', 'Set Pressure', 'P/N', 'Model', 'S/N', 'Stock Code', 'Remarks', 'Station'])
  })

  it('CALF-2 rows: numbered, pressure with unit, maker under Model, S/N as text, Remarks empty, Station from the return record or empty', async () => {
    const ws = await readBack(await buildCalibrationForm(rows, '2026-06-04'))
    expect((ws.getRow(7).values as unknown[]).slice(1)).toEqual([1, '4000 PSI', '91-M1C61P1541', 'Mercer', '1646858', 'MBU 9', undefined, 'الشهداء 1 الدلتا'])
    expect(ws.getCell('E8').value).toBe('000123')
    expect(ws.getCell('B8').value).toBe('17.7 BAR')
    expect(ws.getCell('G8').value).toBeNull()
    expect(ws.getCell('H8').value).toBeNull()
  })

  it('CALF-3 footer below the table: storekeeper and responsible engineer, name, signature and date lines', async () => {
    const ws = await readBack(await buildCalibrationForm(rows, '2026-06-04'))
    const f = 7 + rows.length + 1
    expect(ws.getCell(`A${f}`).value).toBe('أمين المخزن')
    expect(ws.getCell(`F${f}`).value).toBe('المهندس المسئول')
    expect(ws.getCell(`A${f + 2}`).value).toBe(' الاســم  : ________________________')
    expect(ws.getCell(`F${f + 2}`).value).toBe('        الإسم :    إسلام فارس سعيد')
    expect(ws.getCell(`A${f + 4}`).value).toBe(' التوقيع : ________________________')
    expect(ws.getCell(`F${f + 6}`).value).toBe(' التاريخ : ________________________')
    expect(ws.pageSetup.printTitlesRow).toBe('1:6')
    if (process.env.CALF_SAMPLE) writeFileSync(process.env.CALF_SAMPLE, Buffer.from(await (await buildCalibrationForm(rows, '2026-06-04')).arrayBuffer()))
  })

  it('CALF-4 date: the common sent date, otherwise today; d/m/yyyy; pressure falls back to the raw text; ordered by pressure', () => {
    expect(formIsoDate([{ sent_at: '2026-06-04T08:00:00Z' }, { sent_at: '2026-06-04T13:00:00Z' }], '2026-09-29')).toBe('2026-06-04')
    expect(formIsoDate([{ sent_at: '2026-06-04T08:00:00Z' }, { sent_at: '2026-06-05T08:00:00Z' }], '2026-09-29')).toBe('2026-09-29')
    expect(formDate('2026-12-25')).toBe('25/12/2026')
    expect(formPressure({ pressure_min: 270, pressure_max: 280, pressure_unit: 'BAR', set_pressure_raw: null })).toBe('270-280 BAR')
    expect(formPressure({ pressure_min: null, pressure_max: null, pressure_unit: null, set_pressure_raw: 'see plate' })).toBe('see plate')
    expect(orderForForm(rows).map((r) => r.id)).toEqual(['j2', 'j1'])
  })
})
