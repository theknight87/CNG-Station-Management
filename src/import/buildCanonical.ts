import { createHash } from 'node:crypto'

import { cellToText, readIdentifier } from './normalize/identifiers'
import { normalizeRegion } from './normalize/regions'
import type { CanonicalStation, CanonicalUnit } from './resolve/stations'
import type { ImportIssue, Provenance, SourceConflict, StagedRow } from './types'
import { sourceRowHash, sourceRowKey } from './staging'
import type { SheetRow } from './readers/workbook'

/**
 * Builds the canonical Station/Unit candidate model from `Assets DataBase`,
 * the ONLY source that states both levels explicitly (East, West, Delta).
 *
 * `Station data base.xlsx` is deliberately NOT used to create Stations here: it
 * is unit-grain, so one of its rows does not equal one Station
 * (data-quality-report.md §3). Its rows resolve against this model and, where
 * they do not resolve, produce proposals and issues — never new Stations by
 * default.
 *
 * Ids are deterministic hashes of (region, station[, unit]) so a dry run is
 * reproducible and two runs of the same source produce the same model. They are
 * pipeline-internal candidate ids, not database primary keys.
 */

function candidateId(...parts: string[]): string {
  return createHash('sha256').update(parts.join('␟'), 'utf8').digest('hex').slice(0, 32)
}

export interface CanonicalModel {
  stations: CanonicalStation[]
  units: CanonicalUnit[]
  stationsById: Map<string, CanonicalStation>
  stagedRows: StagedRow[]
  issues: ImportIssue[]
  conflicts: SourceConflict[]
}

export function buildCanonicalModel(rows: SheetRow[]): CanonicalModel {
  const stations = new Map<string, CanonicalStation>()
  const units = new Map<string, CanonicalUnit>()
  const stagedRows: StagedRow[] = []
  const issues: ImportIssue[] = []
  const conflicts: SourceConflict[] = []

  // The sheet is block-structured: Area and Station Name appear once per block
  // and continuation rows leave them blank. Forward-fill is the documented
  // reading of that layout, not an inference about identity.
  let currentRegion: string | null = null
  let currentStation: string | null = null

  // Remembers where a unit's job number came from, so a second, different
  // value becomes a FIELD-LEVEL conflict rather than an overwrite.
  const jobNumberSeen = new Map<string, { value: string | null; provenance: Provenance }>()

  for (const { provenance, raw } of rows) {
    const regionCell = normalizeRegion(raw['Area'])
    const stationCell = cellToText(raw['Station Name'])
    if (regionCell.raw !== null) currentRegion = regionCell.value
    if (stationCell !== null) currentStation = stationCell

    const unitName = cellToText(raw['Unit Name'])
    const issuesForRow: ImportIssue[] = []

    if (currentStation === null || currentRegion === null) {
      issuesForRow.push({
        issueType: 'structurally_invalid_row',
        severity: 'warning',
        blocking: true,
        detail: 'row precedes any station/area block header; no entity identity can be established',
        provenance,
        sourceValue: null,
      })
      stagedRows.push({
        provenance,
        sourceRaw: raw,
        sourceRowKey: sourceRowKey(provenance),
        sourceRowHash: sourceRowHash(raw),
        targetTable: 'stations_units',
        outcome: 'rejected',
        mappingStatus: null,
        normalized: {},
        resolution: {},
        issues: issuesForRow,
      })
      issues.push(...issuesForRow)
      continue
    }

    const region = currentRegion as CanonicalStation['region']
    const stationId = candidateId(region, currentStation)
    if (!stations.has(stationId)) {
      stations.set(stationId, {
        id: stationId,
        name: currentStation,
        region,
        unitIds: [],
      })
    }
    const station = stations.get(stationId)!

    let unitId: string | null = null
    if (unitName !== null) {
      unitId = candidateId(region, currentStation, unitName)
      if (!units.has(unitId)) {
        units.set(unitId, { id: unitId, name: unitName, stationId })
        station.unitIds.push(unitId)
      }

      const job = readIdentifier(raw['Unit Job No.'])
      const prior = jobNumberSeen.get(unitId)
      if (prior && prior.value !== job.value && job.value !== null && prior.value !== null) {
        // Two sources disagree on ONE field. Both kept; neither chosen.
        conflicts.push({
          entityKind: 'unit',
          entityKey: `${region}/${currentStation}/${unitName}`,
          fieldName: 'job_number',
          leftValueRaw: prior.value,
          leftSource: prior.provenance,
          rightValueRaw: job.value,
          rightSource: provenance,
          precedenceRule: null,
          selectedSide: null,
        })
      } else if (!prior) {
        jobNumberSeen.set(unitId, { value: job.value, provenance })
      }

      if (job.value === null) {
        // A missing Job Number NEVER blocks creation (principle #4).
        issuesForRow.push({
          issueType: 'missing_job_number',
          severity: 'info',
          blocking: false,
          detail: 'unit has no Job Number in the source; NULL is valid and creation proceeds',
          provenance,
          sourceValue: null,
        })
      }
    }

    stagedRows.push({
      provenance,
      sourceRaw: raw,
      sourceRowKey: sourceRowKey(provenance),
      sourceRowHash: sourceRowHash(raw),
      targetTable: 'stations_units',
      outcome: 'ready',
      mappingStatus: unitId === null ? 'needs_unit_mapping' : 'resolved',
      normalized: {
        region,
        station_name: currentStation,
        station_name_raw: stationCell,
        unit_name: unitName,
        unit_job_number: readIdentifier(raw['Unit Job No.']).value,
        dispenser_model: cellToText(raw['Dispenser \nModel']),
        dispenser_bay_label: cellToText(raw['DIS. Name']),
        dispenser_serial: readIdentifier(raw['DIS. S/N']).value,
        storage_model: cellToText(raw['Storage\n Model']),
        storage_serial: readIdentifier(raw['Storsge S/N']).value,
        compressor_model: cellToText(raw['Compressor\n Model']),
      },
      resolution: {
        source: 'Assets DataBase is authoritative for station/unit STRUCTURE (import-mapping.md §8)',
        forwardFilled: {
          region: regionCell.raw === null,
          station: stationCell === null,
        },
      },
      issues: issuesForRow,
    })
    issues.push(...issuesForRow)
  }

  return {
    stations: [...stations.values()],
    units: [...units.values()],
    stationsById: stations,
    stagedRows,
    issues,
    conflicts,
  }
}
