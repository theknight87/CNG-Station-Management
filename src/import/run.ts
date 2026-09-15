import { createHash } from 'node:crypto'
import { createReadStream } from 'node:fs'

import { buildCanonicalModel } from './buildCanonical'
import {
  withReplay,
  transformGasDetector,
  transformHose,
  transformInstalledSrv,
  transformVessel,
  transformWarehouseSrv,
  type PipelineContext,
} from './pipeline'
import { cellToText } from './normalize/identifiers'
import { normalizeRegion } from './normalize/regions'
import { listSheets, readSheet, type SheetRow } from './readers/workbook'
import { StationResolver, type StoredAlias } from './resolve/stations'
import { sourceRowHash, sourceRowKey } from './staging'
import { WORKBOOKS, isForbiddenSheet } from './sources'
import type { ImportIssue, SourceConflict, StagedRow } from './types'

/**
 * Dry run.
 *
 * Executes the SAME parsing, normalization, matching and validation a commit
 * would, and stops before any canonical write. Nothing in this module opens a
 * connection to a canonical asset table; the only outputs are staged rows,
 * issues, conflicts and a report.
 */

export interface RunOptions {
  sourceDir: string
  /** Confirmed aliases from the database. Empty on a first run: nothing is confirmed yet. */
  aliases?: StoredAlias[]
  /** source_row_key -> source_row_hash from earlier runs, for replay detection. */
  prior?: Map<string, string>
}

export interface FileReport {
  file: string
  sheet: string
  headerRow: number
  rowsRead: number
  target: string
}

export interface RunReport {
  startedAt: string
  completedAt: string
  mode: 'dry_run'
  checksums: Record<string, string>
  files: FileReport[]
  excludedSheets: Array<{ file: string; sheet: string; reason: string; rowsRead: 0 }>
  counts: Record<string, number>
  mappingStatus: Record<string, number>
  outcomes: Record<string, number>
  datePrecision: Record<string, number>
  issuesByType: Record<string, number>
  blockingIssues: number
  nonBlockingIssues: number
  ownerConfirmedRuleApplications: Record<string, { rows: number; contexts: Record<string, number> }>
  sourceConflicts: number
  unmatchedStationNames: Array<{ name: string; region: string | null; rows: number }>
  proposalsGenerated: number
  proposalsAutoAccepted: 0
  replayedRows: number
  changedRows: number
}

export interface RunResult {
  report: RunReport
  stagedRows: StagedRow[]
  issues: ImportIssue[]
  conflicts: SourceConflict[]
}

export async function sha256File(path: string): Promise<string> {
  return await new Promise((resolve, reject) => {
    const hash = createHash('sha256')
    createReadStream(path)
      .on('data', (c) => hash.update(c))
      .on('end', () => resolve(hash.digest('hex')))
      .on('error', reject)
  })
}

function bump(map: Record<string, number>, key: string, by = 1): void {
  map[key] = (map[key] ?? 0) + by
}

export async function runDryRun(options: RunOptions): Promise<RunResult> {
  const startedAt = new Date().toISOString()
  const checksums: Record<string, string> = {}
  const files: FileReport[] = []
  const excludedSheets: RunReport['excludedSheets'] = []
  const stagedRows: StagedRow[] = []
  const issues: ImportIssue[] = []
  const conflicts: SourceConflict[] = []

  for (const wb of WORKBOOKS) {
    checksums[wb.file] = await sha256File(`${options.sourceDir}/${wb.file}`)
  }

  // --- Stage 1: the canonical Station/Unit model, from Assets DataBase ------
  const assetsSpec = WORKBOOKS.find((w) => w.file.startsWith('Assets DataBase'))!
  const assetsSheet = await readSheet(
    `${options.sourceDir}/${assetsSpec.file}`,
    assetsSpec.file,
    assetsSpec.sheets[0].sheet,
    assetsSpec.sheets[0].headerRow,
  )
  const model = buildCanonicalModel(assetsSheet.rows)
  files.push({
    file: assetsSpec.file,
    sheet: assetsSheet.sheet,
    headerRow: assetsSheet.headerRow,
    rowsRead: assetsSheet.rows.length,
    target: 'stations_units',
  })
  stagedRows.push(...model.stagedRows)
  issues.push(...model.issues)
  conflicts.push(...model.conflicts)

  const resolver = new StationResolver(model.stations, model.units, options.aliases ?? [])
  const ctx: PipelineContext = {
    resolver,
    stationsById: model.stationsById,
    priorByKey: options.prior ?? new Map(),
  }

  // --- Stage 2: every other sheet ------------------------------------------
  for (const wb of WORKBOOKS) {
    for (const ex of wb.excludedSheets) {
      excludedSheets.push({ file: wb.file, sheet: ex.sheet, reason: ex.reason, rowsRead: 0 })
    }

    // Proof, not assertion: a forbidden sheet present in the file is listed
    // and never opened.
    const present = await listSheets(`${options.sourceDir}/${wb.file}`)
    for (const sheetName of present) {
      if (isForbiddenSheet(sheetName) && !wb.excludedSheets.some((e) => e.sheet === sheetName)) {
        excludedSheets.push({
          file: wb.file, sheet: sheetName, reason: 'OUT OF SCOPE by instruction', rowsRead: 0,
        })
      }
    }

    for (const spec of wb.sheets) {
      if (wb.file.startsWith('Assets DataBase')) continue // already done in stage 1
      if (isForbiddenSheet(spec.sheet)) {
        throw new Error(`refusing to read forbidden sheet ${spec.sheet}`)
      }

      const sheet = await readSheet(
        `${options.sourceDir}/${wb.file}`, wb.file, spec.sheet, spec.headerRow,
      )
      files.push({
        file: wb.file, sheet: sheet.sheet, headerRow: sheet.headerRow,
        rowsRead: sheet.rows.length, target: spec.target,
      })

      for (const row of sheet.rows) {
        const staged = transformFor(spec.target, row, ctx)
        if (staged) {
          stagedRows.push(staged)
          issues.push(...staged.issues)
        }
      }
    }
  }

  // ONE replay pass over every staged row from every source, including the two
  // paths that build rows directly. Replay detection is a property of the run.
  const checked = stagedRows.map((row) => withReplay(row, ctx))

  const report = buildReport({
    startedAt, checksums, files, excludedSheets, stagedRows: checked, issues, conflicts, model,
  })

  return { report, stagedRows: checked, issues, conflicts }
}

function transformFor(target: string, row: SheetRow, ctx: PipelineContext): StagedRow | null {
  switch (target) {
    case 'installed_relief_valves':
      return transformInstalledSrv(row.provenance, row.raw, ctx)
    case 'warehouse_relief_valves':
      return transformWarehouseSrv(row.provenance, row.raw, ctx)
    case 'storage_vessels':
      return transformVessel(row.provenance, row.raw, ctx)
    case 'gas_detectors':
      return transformGasDetector(row.provenance, row.raw, ctx)
    case 'hoses':
      return transformHose(row.provenance, row.raw, ctx)
    case 'unit_attributes':
      return transformUnitAttributes(row, ctx)
    default:
      return null
  }
}

/**
 * `Station data base.xlsx` — unit-grain, and NOT a Station master.
 *
 * A row here NEVER creates a Station by default. It resolves against the
 * canonical model; where it does not resolve it stages as `proposal_only`,
 * which attaches nothing and creates nothing, and waits for a human.
 */
function transformUnitAttributes(row: SheetRow, ctx: PipelineContext): StagedRow {
  const { provenance, raw } = row
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push({
      issueType: 'unknown_region', severity: 'warning', blocking: false,
      detail: `region '${region.raw}' matches no canonical Region`,
      provenance, sourceValue: region.raw,
    })
  }

  const nameRaw = cellToText(raw['Station Name'])
  const resolution = ctx.resolver.resolve({
    rawName: nameRaw ?? '', region: region.value, sourceFile: provenance.file,
  })

  if (resolution.kind === 'ambiguous') {
    issues.push({
      issueType: 'ambiguous_station_identity', severity: 'warning', blocking: false,
      detail: 'name matches several candidates; no attachment and no winner',
      provenance, sourceValue: nameRaw,
    })
  } else if (resolution.kind === 'proposal') {
    issues.push({
      issueType: 'ambiguous_station_identity', severity: 'info', blocking: false,
      detail: 'a proposed alias was generated; it attaches nothing until a human confirms it',
      provenance, sourceValue: nameRaw,
    })
  } else if (resolution.kind === 'unmatched') {
    issues.push({
      issueType: 'not_found_in_assets_database', severity: 'warning', blocking: false,
      detail: 'name matches nothing in the structural source; station/unit identity unresolved',
      provenance, sourceValue: nameRaw,
    })
  }

  const station = resolution.stationId ? ctx.stationsById.get(resolution.stationId) ?? null : null

  return {
    provenance,
    sourceRaw: raw,
    sourceRowKey: sourceRowKey(provenance),
    sourceRowHash: sourceRowHash(raw),
    targetTable: 'unit_attributes',
    // A proposal attaches NOTHING. That is the whole point of this outcome.
    outcome: resolution.resolved ? 'ready' : resolution.proposals.length > 0 ? 'proposal_only' : 'ready_unresolved',
    mappingStatus: resolution.resolved && station?.unitIds.length === 1 ? 'resolved' : 'needs_unit_mapping',
    normalized: {
      region: region.value,
      region_raw: region.raw,
      source_name_raw: nameRaw,
      station_id: resolution.resolved ? station?.id ?? null : null,
      unit_id: resolution.resolved ? resolution.unitId : null,
      bay_status_raw: cellToText(raw['Bay Status']),
      compressor_model: cellToText(raw['Compressor\n Model']),
      total_running_hours: cellToText(raw['Total Running\n Hours']),
      avg_hours_per_day: cellToText(raw['Average \nHours / Day']),
      avg_gas_sales_per_day_raw: cellToText(raw['Average Gas\n Sales / Day']),
      dispenser_model: cellToText(raw['Dispenser \nModel']),
      dispenser_count_reported_raw: cellToText(raw['No. \nOf Dispensers']),
      hose_count_reported_raw: cellToText(raw['No. \nOf Hoses']),
      recovery_tank_model: cellToText(raw['Recovery Tank \nModel']),
      storage_count_reported_raw: cellToText(raw['No.\nOf Storage']),
      storage_model: cellToText(raw['Storage\n Model']),
      gas_detector_model: cellToText(raw['Gas Detector Model']),
      notes: cellToText(raw['Notes']),
    },
    resolution: {
      station: { kind: resolution.kind, rule: resolution.rule, proposals: resolution.proposals },
      grain: 'this workbook is UNIT-GRAIN; a row is never treated as a Station master record',
    },
    issues,
  }
}

function buildReport(input: {
  startedAt: string
  checksums: Record<string, string>
  files: FileReport[]
  excludedSheets: RunReport['excludedSheets']
  stagedRows: StagedRow[]
  issues: ImportIssue[]
  conflicts: SourceConflict[]
  model: ReturnType<typeof buildCanonicalModel>
}): RunReport {
  const outcomes: Record<string, number> = {}
  const mappingStatus: Record<string, number> = {}
  const datePrecision: Record<string, number> = {}
  const issuesByType: Record<string, number> = {}
  const counts: Record<string, number> = {}
  const ownerRules: RunReport['ownerConfirmedRuleApplications'] = {}
  const unmatched = new Map<string, { region: string | null; rows: number }>()
  let proposals = 0
  let replayed = 0
  let changed = 0

  for (const row of input.stagedRows) {
    bump(outcomes, row.outcome)
    bump(counts, row.targetTable)
    if (row.mappingStatus) bump(mappingStatus, row.mappingStatus)
    if (row.outcome === 'replayed') replayed++
    if ((row.resolution as { sourceChanged?: string }).sourceChanged) changed++

    const stationRes = (row.resolution as { station?: { proposals?: unknown[]; kind?: string } }).station
    if (stationRes?.proposals) proposals += stationRes.proposals.length
    if (stationRes?.kind === 'unmatched') {
      const name = String(row.normalized['source_station_name_raw'] ?? row.normalized['source_name_raw'] ?? '')
      if (name) {
        const prior = unmatched.get(name)
        unmatched.set(name, {
          region: (row.normalized['region'] as string | null) ?? null,
          rows: (prior?.rows ?? 0) + 1,
        })
      }
    }

    for (const key of ['last_calibration', 'next_due_date', 'issue_date', 'last_test']) {
      const d = row.normalized[key] as { precision?: string } | null | undefined
      if (d?.precision) bump(datePrecision, d.precision)
    }

    const rule = (row.resolution as { ownerConfirmedRule?: string }).ownerConfirmedRule
    if (typeof rule === 'string') {
      ownerRules[rule] ??= { rows: 0, contexts: {} }
      ownerRules[rule].rows++
      bump(ownerRules[rule].contexts, `${row.provenance.file}::${row.provenance.sheet}`)
    }
    // NOTE: counted from `resolution.ownerConfirmedRule` ONLY, above. An
    // earlier version also counted the same rows a second time from their
    // normalized part_number, which doubled every figure.
    const stationRule = (row.resolution as { station?: { rule?: string | null } }).station?.rule
    if (typeof stationRule === 'string' && stationRule.startsWith('owner_confirmed_station_alias')) {
      ownerRules[stationRule] ??= { rows: 0, contexts: {} }
      ownerRules[stationRule].rows++
      bump(ownerRules[stationRule].contexts, `${row.provenance.file}::${row.provenance.sheet}`)
    }
  }

  for (const i of input.issues) bump(issuesByType, i.issueType)

  counts['station_candidates'] = input.model.stations.length
  counts['unit_candidates'] = input.model.units.length

  return {
    startedAt: input.startedAt,
    completedAt: new Date().toISOString(),
    mode: 'dry_run',
    checksums: input.checksums,
    files: input.files,
    excludedSheets: input.excludedSheets,
    counts,
    mappingStatus,
    outcomes,
    datePrecision,
    issuesByType,
    blockingIssues: input.issues.filter((i) => i.blocking).length,
    nonBlockingIssues: input.issues.filter((i) => !i.blocking).length,
    ownerConfirmedRuleApplications: ownerRules,
    sourceConflicts: input.conflicts.length,
    unmatchedStationNames: [...unmatched.entries()]
      .map(([name, v]) => ({ name, region: v.region, rows: v.rows }))
      .sort((a, b) => b.rows - a.rows),
    proposalsGenerated: proposals,
    // Structurally zero: nothing in this pipeline accepts a proposal.
    proposalsAutoAccepted: 0,
    replayedRows: replayed,
    changedRows: changed,
  }
}
