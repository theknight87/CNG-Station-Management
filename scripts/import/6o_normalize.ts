// Phase 6o: normalize every snapshot column with the import pipeline's own functions.
import { readFileSync, writeFileSync } from 'node:fs'
import { parsePressure } from '/home/user/CNG-Station-Management/src/import/pipeline'
import { classifySerialCell, cellToText } from '/home/user/CNG-Station-Management/src/import/normalize/identifiers'
import { normalizeDate } from '/home/user/CNG-Station-Management/src/import/normalize/dates'
const dir = process.argv[2]
const rows = JSON.parse(readFileSync(`${dir}/file_full.json`, 'utf8'))
const d = (v: any) => normalizeDate(v && v.__date ? new Date(v.__date) : v)
writeFileSync(`${dir}/file_full_norm.json`, JSON.stringify(rows.map((r: any) => {
  const c = r.cells
  return { row: r.row, raw: c, region: cellToText(c['Area']), station: cellToText(c['Station']), location: cellToText(c['Location']),
    serial: classifySerialCell(c['Serial Number']), pressure: parsePressure(c['Set Pressure']),
    manufacturer: cellToText(c['Manufacturer']), size_type: cellToText(c['Size Type']), inlet: cellToText(c['IN']), outlet: cellToText(c['OUT']),
    last: d(c['Last Calibration Date']), next: d(c['Next Calibration Date']), notes: cellToText(c['Notes']) }
})))
