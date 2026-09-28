// Phase 6x: normalize the matched workbook Storage rows with the import pipeline's own functions.
import { readFileSync, writeFileSync } from 'node:fs'
import { classifySerialCell, cellToText } from '../../src/import/normalize/identifiers'
import { normalizeDate } from '../../src/import/normalize/dates'
const [inp, outp] = process.argv.slice(2)
const d = (v: any) => normalizeDate(v && v.__date ? new Date(v.__date + 'Z') : v)
const rows = JSON.parse(readFileSync(inp, 'utf8'))
writeFileSync(outp, JSON.stringify(rows.map((r: any) => {
  const c = r.cells, s = classifySerialCell(c['Serial Number']), l = d(c['Last Calibration Date']), n = d(c['Next Calibration Date'])
  const raw = (v: any) => v && v.__date ? v.__date.slice(0, 10) : (v == null ? null : String(v))
  return [r.vessel_id, r.k, r.row, cellToText(c['Manufacturer'])?.replace(/\s+/g, ' ') ?? null, raw(c['Manufacturer']),
    s.serialNumber, raw(c['Serial Number']), s.serialStatus, cellToText(c['Type OF Compressor']),
    raw(c['Last Calibration Date']), l.value ?? null, l.precision, raw(c['Next Calibration Date']), n.value ?? null, n.precision,
    cellToText(c['Notes']), c]
})))
