import { describe, expect, it } from 'vitest'

import {
  parsePressure,
  transformGasDetector,
  transformHose,
  transformInstalledSrv,
  transformVessel,
  transformWarehouseSrv,
  type PipelineContext,
} from '../pipeline'
import { StationResolver, type CanonicalStation, type CanonicalUnit } from '../resolve/stations'
import { isForbiddenSheet, isNeverImported, WORKBOOKS } from '../sources'
import { buildCanonicalModel } from '../buildCanonical'
import type { SheetRow } from '../readers/workbook'

const stations: CanonicalStation[] = [
  { id: 'st-abnoub', name: 'ابنوب', region: 'Upper', unitIds: ['u-ab-1'] },
  { id: 'st-shobra', name: 'شبرا', region: 'East', unitIds: ['u-s1', 'u-s2'] },
]
const units: CanonicalUnit[] = [
  { id: 'u-ab-1', name: 'ابنوب 1', stationId: 'st-abnoub' },
  { id: 'u-s1', name: 'شبرا 1', stationId: 'st-shobra' },
  { id: 'u-s2', name: 'شبرا 2', stationId: 'st-shobra' },
]

function ctx(): PipelineContext {
  return {
    resolver: new StationResolver(stations, units, []),
    stationsById: new Map(stations.map((s) => [s.id, s])),
    priorByKey: new Map(),
  }
}
const p = (row = 6) => ({ file: 'Warehouse Relief Data.xlsx', sheet: 'رصيد المحطات', row })

describe('installed SRV rows', () => {
  it('SRVROW-1 an unmatched station is STILL imported, never dropped', () => {
    const r = transformInstalledSrv(p(), {
      Area: 'Delta', Station: '  طاليــا / أشــمون 2', Location: 'Storage',
      'Serial Number': null, 'Last Calibration Date': 2021, 'Next Calibration Date': '2022',
    }, ctx())

    expect(r.outcome).toBe('ready_unresolved')
    expect(r.mappingStatus).toBe('needs_station_mapping')
    expect(r.normalized['station_id']).toBeNull()
    // The raw station name survives, which is what makes later mapping possible.
    expect(r.normalized['source_station_name_raw']).toBe('طاليــا / أشــمون 2')
    expect(r.issues.some((i) => i.issueType === 'unmatched_station' && !i.blocking)).toBe(true)
  })

  it('SRVROW-2 provenance is complete enough to find the source cell again', () => {
    const r = transformInstalledSrv(p(41), { Area: 'East', Station: 'شبرا' }, ctx())
    expect(r.provenance).toEqual({ file: 'Warehouse Relief Data.xlsx', sheet: 'رصيد المحطات', row: 41 })
    expect(r.sourceRowKey).toBe('Warehouse Relief Data.xlsx::رصيد المحطات::41')
  })

  it('SRVROW-3 raw and normalized stay distinguishable', () => {
    const raw = { Area: 'East', Station: 'شبرا', 'Serial Number': 21586, Location: 'Stage' }
    const r = transformInstalledSrv(p(), raw, ctx())
    expect(r.sourceRaw).toEqual(raw)
    expect(r.sourceRaw['Serial Number']).toBe(21586)     // raw: still a number
    expect(r.normalized['serial_number']).toBe('21586')  // normalized: text
  })

  it('SRVROW-4 the Days Left columns are never imported', () => {
    const r = transformInstalledSrv(p(), {
      Area: 'East', Station: 'شبرا', 'Number Of Days Left': 120, 'Next Calibration Month': '2027',
    }, ctx())
    expect(Object.keys(r.normalized)).not.toContain('days_left')
    expect(JSON.stringify(r.normalized)).not.toContain('Days Left')
    expect(r.resolution['droppedColumns']).toContain('Number Of Days Left')
  })

  it('SRVROW-5 the owner-confirmed station alias is applied and reported', () => {
    const r = transformInstalledSrv(p(), { Area: 'Upper', Station: 'ابنوب اسيوط', Location: 'Stage' }, ctx())
    expect(r.mappingStatus).toBe('needs_equipment_mapping')
    expect(r.normalized['station_id']).toBe('st-abnoub')
    const station = r.resolution['station'] as { rule: string }
    expect(station.rule).toContain('owner_confirmed_station_alias')
  })

  it('SRVROW-6 an unknown region is an issue, not a new Region', () => {
    const r = transformInstalledSrv(p(), { Area: 'Sinai', Station: 'شبرا' }, ctx())
    expect(r.normalized['region']).toBeNull()
    expect(r.normalized['region_raw']).toBe('Sinai')
    expect(r.issues.some((i) => i.issueType === 'unknown_region')).toBe(true)
  })

  it('SRVROW-7 a missing serial is non-blocking and stays NULL', () => {
    const r = transformInstalledSrv(p(), { Area: 'East', Station: 'شبرا', 'Serial Number': null }, ctx())
    expect(r.normalized['serial_number']).toBeNull()
    const issue = r.issues.find((i) => i.issueType === 'missing_serial')
    expect(issue?.blocking).toBe(false)
    expect(r.outcome).not.toBe('rejected')
  })
})

describe('warehouse SRVs are a separate concept', () => {
  it('WH-1 a warehouse row NEVER receives an installed mapping status', () => {
    const r = transformWarehouseSrv(
      { file: 'Warehouse Relief Data.xlsx', sheet: 'رصيد المخزن', row: 6 },
      { 'Serial Number': 1154389, 'Availability Status': 'Available Calibrated', Area: null, Station: null },
      ctx(),
    )
    expect(r.targetTable).toBe('warehouse_relief_valves')
    expect(r.mappingStatus).toBeNull()
  })

  it('WH-2 unassigned stock is valid, not a defect', () => {
    const r = transformWarehouseSrv(
      { file: 'Warehouse Relief Data.xlsx', sheet: 'رصيد المخزن', row: 7 },
      { 'Serial Number': '999', Area: null, Station: null },
      ctx(),
    )
    expect(r.outcome).toBe('ready')
    expect(r.normalized['assigned_region']).toBeNull()
    expect(r.issues.filter((i) => i.blocking)).toHaveLength(0)
  })

  it('WH-3 installed and warehouse rows are never merged on serial', () => {
    const serial = '1154389'
    const installed = transformInstalledSrv(p(), { Area: 'East', Station: 'شبرا', 'Serial Number': serial }, ctx())
    const warehouse = transformWarehouseSrv(
      { file: 'Warehouse Relief Data.xlsx', sheet: 'رصيد المخزن', row: 6 },
      { 'Serial Number': serial }, ctx(),
    )
    expect(installed.targetTable).not.toBe(warehouse.targetTable)
    expect(installed.sourceRowKey).not.toBe(warehouse.sourceRowKey)
  })
})

describe('vessels split by Location', () => {
  const vp = (row = 6) => ({ file: 'شهادات الفحص والمعايرة للمناطق .xlsx', sheet: 'رصيد المحطات', row })

  it('VESSEL-1 Storage selects storage_vessels, Recovery selects recovery_tanks', () => {
    expect(transformVessel(vp(), { Area: 'East', Station: 'ابنوب', Location: 'Storage' }, ctx()).targetTable).toBe('storage_vessels')
    expect(transformVessel(vp(), { Area: 'East', Station: 'ابنوب', Location: 'Recovery' }, ctx()).targetTable).toBe('recovery_tanks')
  })

  it('VESSEL-2 Type OF Compressor is descriptive text, never a foreign key', () => {
    const r = transformVessel(vp(), { Area: 'East', Station: 'ابنوب', Location: 'Storage', 'Type OF Compressor': 'Fornovo (3)' }, ctx())
    expect(r.normalized['compressor_context_raw']).toBe('Fornovo (3)')
    expect(Object.keys(r.normalized)).not.toContain('compressor_id')
  })

  it('VESSEL-3 a row naming neither table is rejected as structurally invalid', () => {
    const r = transformVessel(vp(), { Area: 'East', Station: 'ابنوب', Location: 'Nonsense' }, ctx())
    expect(r.outcome).toBe('rejected')
    expect(r.issues.some((i) => i.blocking)).toBe(true)
  })

  it('VESSEL-4 no overdue status is stored at import', () => {
    const r = transformVessel(vp(), { Area: 'East', Station: 'ابنوب', Location: 'Storage', 'Next Calibration Date': '1/1/2020' }, ctx())
    expect(JSON.stringify(r.normalized)).not.toMatch(/overdue|due_status|days_left/i)
  })
})

describe('gas detectors', () => {
  const gp = { file: 'Gas detector.xlsx', sheet: 'Sheet1', row: 2 }

  it('DETECT-1 absence creates NO detector record', () => {
    const r = transformGasDetector(gp, {
      Area: 'East', ' Station': 'ابنوب 1',
      'Gas detector exist or not exist in Station': 'Not exist in the station',
    }, ctx())
    expect(r.normalized['presence']).toBe('not_installed')
    expect(r.normalized['creates_detector_record']).toBe(false)
    expect(r.normalized['serial_number']).toBeNull()
  })

  it('DETECT-2 an installed detector with no serial is still imported', () => {
    const r = transformGasDetector(gp, {
      Area: 'East', ' Station': 'ابنوب 1',
      'Gas detector exist or not exist in Station': 'Exist in the station', 'S/N': null,
    }, ctx())
    expect(r.normalized['creates_detector_record']).toBe(true)
    expect(r.normalized['serial_number']).toBeNull()
    expect(r.issues.filter((i) => i.blocking)).toHaveLength(0)
  })

  it('DETECT-3 a float serial keeps every digit', () => {
    const r = transformGasDetector(gp, {
      Area: 'East', ' Station': 'ابنوب 1',
      'Gas detector exist or not exist in Station': 'Exist in the station', 'S/N': 1803.02075,
    }, ctx())
    expect(r.normalized['serial_number']).toBe('1803.02075')
  })
})

describe('hoses', () => {
  it('HOSE-1 PSI and BAR are never converted', () => {
    const r = transformHose({ file: 'HOSES.xlsx', sheet: 'Sheet1', row: 2 }, {
      Area: 'غرب', STATION: 'مجهولة', 'WORKING  PRESSURE ': '5000 PSI', 'TEST PRESSURE': '350 BAR',
    }, ctx())
    expect(r.normalized['working_pressure']).toMatchObject({ raw: '5000 PSI', unit: 'PSI', min: 5000 })
    expect(r.normalized['test_pressure']).toMatchObject({ raw: '350 BAR', unit: 'BAR', min: 350 })
  })

  it('HOSE-2 an unresolvable station leaves unit NULL rather than forcing one', () => {
    const r = transformHose({ file: 'HOSES.xlsx', sheet: 'Sheet1', row: 2 }, {
      Area: 'غرب', STATION: 'محطة غير معروفة',
    }, ctx())
    expect(r.normalized['unit_id']).toBeNull()
    expect(r.mappingStatus).toBe('needs_station_mapping')
  })
})

describe('pressure parsing', () => {
  it('PRESSURE-1 reads a range without converting units', () => {
    expect(parsePressure('(275-344) BAR')).toEqual({ raw: '(275-344) BAR', min: 275, max: 344, unit: 'BAR' })
  })
  it('PRESSURE-2 a unitless value keeps unit NULL rather than assuming one', () => {
    expect(parsePressure('275')).toEqual({ raw: '275', min: 275, max: 275, unit: null })
  })
})

describe('exclusions are structural', () => {
  it('EXCLUDE-1 the Repair Kit sheet is never in any read spec', () => {
    for (const wb of WORKBOOKS) {
      for (const s of wb.sheets) expect(isForbiddenSheet(s.sheet)).toBe(false)
    }
    expect(isForbiddenSheet('Repair Kit ')).toBe(true)
    expect(isForbiddenSheet('Repair Kit')).toBe(true)
    const wh = WORKBOOKS.find((w) => w.file.startsWith('Warehouse'))!
    expect(wh.excludedSheets.some((e) => e.sheet.trim() === 'Repair Kit')).toBe(true)
  })

  it('EXCLUDE-2 derived and counter columns are never imported', () => {
    for (const c of ['Number Of Days Left', 'Days Left', 'Next Calibration Month', '#', 'Column1']) {
      expect(isNeverImported(c)).toBe(true)
    }
    expect(isNeverImported('Serial Number')).toBe(false)
  })
})

describe('canonical model from Assets DataBase', () => {
  const rows = (raws: Array<Record<string, unknown>>): SheetRow[] =>
    raws.map((raw, i) => ({ provenance: { file: 'Assets DataBase - East, west and Delta Completed.xlsx', sheet: 'Sheet1', row: i + 2 }, raw }))

  it('MODEL-1 builds Station -> Unit two-level structure with forward fill', () => {
    const m = buildCanonicalModel(rows([
      { Area: 'East', 'Station Name': 'شبرا', 'Unit Name': 'شبرا 1', 'Unit Job No.': 30157 },
      { Area: null, 'Station Name': null, 'Unit Name': 'شبرا 2', 'Unit Job No.': 30158 },
    ]))
    expect(m.stations).toHaveLength(1)
    expect(m.stations[0].name).toBe('شبرا')
    expect(m.units).toHaveLength(2)
    expect(m.stations[0].unitIds).toHaveLength(2)
  })

  it('MODEL-2 a missing Job Number never blocks creation', () => {
    const m = buildCanonicalModel(rows([
      { Area: 'West', 'Station Name': 'الخمائل', 'Unit Name': 'الخمائل 1', 'Unit Job No.': null },
    ]))
    expect(m.units).toHaveLength(1)
    expect(m.stagedRows[0].outcome).toBe('ready')
    expect(m.stagedRows[0].normalized['unit_job_number']).toBeNull()
    const issue = m.issues.find((i) => i.issueType === 'missing_job_number')
    expect(issue?.blocking).toBe(false)
  })

  it('MODEL-3 a field-level disagreement becomes a conflict, not an overwrite', () => {
    const m = buildCanonicalModel(rows([
      { Area: 'East', 'Station Name': 'شبرا', 'Unit Name': 'شبرا 1', 'Unit Job No.': '30157' },
      { Area: 'East', 'Station Name': 'شبرا', 'Unit Name': 'شبرا 1', 'Unit Job No.': '99999' },
    ]))
    expect(m.conflicts).toHaveLength(1)
    const c = m.conflicts[0]
    expect(c.fieldName).toBe('job_number')
    expect(c.leftValueRaw).toBe('30157')   // both raw values kept
    expect(c.rightValueRaw).toBe('99999')
    expect(c.selectedSide).toBeNull()      // neither chosen
    expect(c.precedenceRule).toBeNull()
  })

  it('MODEL-4 ids are deterministic, so two runs agree', () => {
    const build = () => buildCanonicalModel(rows([
      { Area: 'East', 'Station Name': 'شبرا', 'Unit Name': 'شبرا 1' },
    ]))
    expect(build().stations[0].id).toBe(build().stations[0].id)
  })
})
