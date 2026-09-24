// Phase 6n: normalizes the snapshot rows with the import pipeline's own functions. Usage: npx tsx scripts/import/6n_normalize.ts <workdir>
import { readFileSync, writeFileSync } from 'node:fs'
import { parsePressure } from '../../src/import/pipeline'
import { normalizeDate } from '../../src/import/normalize/dates'
import { classifySerialCell, cellToText } from '../../src/import/normalize/identifiers'
const dir = process.argv[2]
const rows = JSON.parse(readFileSync(`${dir}/file_rows.json`, 'utf8'))
writeFileSync(`${dir}/file_norm.json`, JSON.stringify(rows.map((r: any) => ({
  ...r, station_txt: cellToText(r.station), location_txt: cellToText(r.location),
  serial_norm: classifySerialCell(r.serial), pressure_norm: parsePressure(r.pressure),
  last_norm: normalizeDate(r.last && r.last.__date ? new Date(r.last.__date) : r.last),
  next_norm: normalizeDate(r.next && r.next.__date ? new Date(r.next.__date) : r.next),
}))))
