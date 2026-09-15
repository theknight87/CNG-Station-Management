import { classifySerialCell, cellToText, isPlaceholder, readIdentifier } from './normalize/identifiers'
import { normalizeDate } from './normalize/dates'
import { normalizeRegion } from './normalize/regions'
import { StationResolver, type CanonicalStation, type CanonicalUnit, type StoredAlias } from './resolve/stations'
import { decideInstalledSrvMapping } from './resolve/srvMapping'
import { classifyReplay, sourceRowHash, sourceRowKey } from './staging'
import { isNeverImported } from './sources'
import type {
  ImportIssue,
  MappingStatus,
  Provenance,
  SourceConflict,
  StagedRow,
  StagingOutcome,
} from './types'

/**
 * The pipeline core: one source row in, one staged row out.
 *
 * Every transformer here obeys the same contract. A missing value produces
 * NULL and a non-blocking issue at most; it never produces a placeholder, and
 * it never rejects a row that still carries usable identity.
 */

export interface PipelineContext {
  resolver: StationResolver
  stationsById: Map<string, CanonicalStation>
  /** Hashes staged by earlier runs, for replay detection. */
  priorByKey: Map<string, string>
}

function issue(
  issueType: string,
  severity: ImportIssue['severity'],
  blocking: boolean,
  detail: string,
  provenance: Provenance,
  sourceValue?: string | null,
): ImportIssue {
  return { issueType, severity, blocking, detail, provenance, sourceValue: sourceValue ?? null }
}

/** Strips the columns that are never imported, with their reason recorded once. */
export function droppedColumns(raw: Record<string, unknown>): string[] {
  return Object.keys(raw).filter((k) => isNeverImported(k))
}

function baseRow(
  provenance: Provenance,
  raw: Record<string, unknown>,
  targetTable: string,
): Pick<StagedRow, 'provenance' | 'sourceRaw' | 'sourceRowKey' | 'sourceRowHash' | 'targetTable'> {
  return {
    provenance,
    sourceRaw: raw,
    sourceRowKey: sourceRowKey(provenance),
    sourceRowHash: sourceRowHash(raw),
    targetTable,
  }
}

/**
 * Applies replay classification to a finished row.
 *
 * Exported and applied in ONE place (run.ts), over every staged row from every
 * source. An earlier version applied it inside each transformer, which silently
 * skipped the two paths that build rows directly -- 727 of 7,163 rows went
 * unchecked. Replay detection is a property of the run, not of a transformer.
 */
export function withReplay(row: StagedRow, ctx: PipelineContext): StagedRow {
  const verdict = classifyReplay(row, ctx.priorByKey)
  if (verdict.kind === 'replay') {
    return {
      ...row,
      outcome: 'replayed',
      resolution: { ...row.resolution, replay: verdict.reason },
    }
  }
  if (verdict.kind === 'changed') {
    return { ...row, resolution: { ...row.resolution, sourceChanged: verdict.reason } }
  }
  return row
}

/** Reads a date column into the (value, precision, raw) triple plus its issues. */
function dateField(
  raw: unknown,
  label: string,
  provenance: Provenance,
  issues: ImportIssue[],
): ReturnType<typeof normalizeDate> {
  const d = normalizeDate(raw)
  if (d.precision === 'year_only') {
    issues.push(
      issue('year_only_date', 'info', false,
        `${label} is year-only (${d.year}); no exact date exists and no alert may be driven from it`,
        provenance, d.raw),
    )
  } else if (d.precision === 'invalid') {
    issues.push(
      issue('invalid_date', 'warning', false,
        `${label} is not a date; raw value preserved${d.sourceStatusRaw ? ' as source status text' : ''}`,
        provenance, d.raw),
    )
  }
  return d
}

/** Reads a serial column, honouring the owner-confirmed list and nothing else. */
function serialField(raw: unknown, provenance: Provenance, issues: ImportIssue[]) {
  const id = classifySerialCell(raw, provenance)

  if (id.ownerConfirmedRule) {
    issues.push(
      issue('placeholder_value', 'info', false,
        `owner-confirmed part number applied: ${id.ownerConfirmedRule}; serial_number NULL, serial_status not_yet_assigned`,
        provenance, id.raw),
    )
  }
  if (id.suspectedPartNumber) {
    issues.push(
      issue('suspected_part_number_in_serial_column', 'warning', false,
        'value in a serial column has part-number shape but is NOT owner-confirmed; kept as a serial, flagged for a human',
        provenance, id.raw),
    )
  }
  if (id.raw !== null && isPlaceholder(id.raw)) {
    issues.push(
      issue('placeholder_in_source', 'info', false,
        'placeholder in a serial column; stored as NULL with the literal value preserved as raw evidence',
        provenance, id.raw),
    )
  }
  if (id.raw === null) {
    issues.push(
      issue('missing_serial', 'info', false,
        'no serial in the source; NULL is valid and never blocks creation',
        provenance, null),
    )
  }
  if (id.raw !== null && /e/i.test(id.raw) && id.serialNumber === null && id.partNumber === null) {
    issues.push(
      issue('identifier_numeric_coercion', 'error', true,
        'identifier reached scientific notation and has already lost digits; raw preserved, not reconstructed',
        provenance, id.raw),
    )
  }
  return id
}

/**
 * Pressure is stored as a quad (raw, min, max, unit) and NEVER converted
 * between PSI and BAR.
 */
export function parsePressure(raw: unknown): {
  raw: string | null
  min: number | null
  max: number | null
  unit: string | null
} {
  const text = cellToText(raw)
  if (text === null) return { raw: null, min: null, max: null, unit: null }

  const unitMatch = text.match(/\b(PSI|BAR)\b/i)
  const unit = unitMatch ? unitMatch[1].toUpperCase() : null

  const range = text.match(/\(?\s*(\d+(?:\.\d+)?)\s*-\s*(\d+(?:\.\d+)?)\s*\)?/)
  if (range) return { raw: text, min: Number(range[1]), max: Number(range[2]), unit }

  const single = text.match(/(\d+(?:\.\d+)?)/)
  if (single) return { raw: text, min: Number(single[1]), max: Number(single[1]), unit }

  return { raw: text, min: null, max: null, unit }
}

// ---------------------------------------------------------------------------
// Installed SRVs
// ---------------------------------------------------------------------------

export function transformInstalledSrv(
  provenance: Provenance,
  raw: Record<string, unknown>,
  ctx: PipelineContext,
): StagedRow {
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push(
      issue('unknown_region', 'warning', false,
        `region '${region.raw}' matches no canonical Region; no seventh Region is created`,
        provenance, region.raw),
    )
  }

  const stationRaw = cellToText(raw['Station'])
  const resolution = ctx.resolver.resolve({
    rawName: stationRaw ?? '',
    region: region.value,
    sourceFile: provenance.file,
    provenance,
  })
  const station = resolution.stationId ? ctx.stationsById.get(resolution.stationId) ?? null : null

  const location = cellToText(raw['Location'])
  const decision = decideInstalledSrvMapping(resolution, station, location)

  if (decision.mappingStatus === 'needs_station_mapping') {
    issues.push(
      issue('unmatched_station', 'warning', false,
        `station '${stationRaw ?? ''}' is unresolved. The SRV is STILL imported with station_id NULL and its raw station name; it is never dropped`,
        provenance, stationRaw),
    )
  }
  if (resolution.kind === 'ambiguous') {
    issues.push(
      issue('ambiguous_station_identity', 'warning', false,
        'several station candidates match; no winner is selected automatically',
        provenance, stationRaw),
    )
  }

  const serial = serialField(raw['Serial Number'], provenance, issues)
  const last = dateField(raw['Last Calibration Date'], 'last calibration date', provenance, issues)
  const next = dateField(raw['Next Calibration Date'], 'next calibration date', provenance, issues)

  const outcome: StagingOutcome =
    decision.mappingStatus === 'resolved' ? 'ready' : 'ready_unresolved'

  return {
      ...baseRow(provenance, raw, 'installed_relief_valves'),
      outcome,
      mappingStatus: decision.mappingStatus,
      normalized: {
        region: region.value,
        region_raw: region.raw,
        station_id: decision.stationId,
        unit_id: decision.unitId,
        compressor_id: decision.compressorId,
        storage_vessel_id: decision.storageVesselId,
        dispenser_id: decision.dispenserId,
        expected_parent_kind: decision.expectedParentKind,
        source_station_name_raw: stationRaw,
        location_raw: location,
        serial_number: serial.serialNumber,
        part_number: serial.partNumber,
        serial_number_raw: serial.raw,
        serial_status: serial.serialStatus,
        manufacturer: cellToText(raw['Manufacturer']),
        size_type: cellToText(raw['Size Type']),
        port_in: cellToText(raw['IN']),
        port_out: cellToText(raw['OUT']),
        set_pressure: parsePressure(raw['Set Pressure']),
        last_calibration: last,
        next_due_date: next,
        notes: cellToText(raw['Notes']),
      },
      resolution: {
        station: {
          kind: resolution.kind,
          rule: resolution.rule,
          proposals: resolution.proposals,
        },
        mapping: decision.reason,
        // Only an OWNER-CONFIRMED rule belongs here. `??` binds tighter than
        // `?:`, so this must stay an explicit conditional: an earlier version
        // mis-parsed and logged ordinary canonical matches as owner rulings.
        ownerConfirmedRule: serial.ownerConfirmedRule,
        droppedColumns: droppedColumns(raw),
      },
      issues,
  }
}

// ---------------------------------------------------------------------------
// Warehouse SRVs — a SEPARATE inventory concept. No mapping lifecycle.
// ---------------------------------------------------------------------------

export function transformWarehouseSrv(
  provenance: Provenance,
  raw: Record<string, unknown>,
  // Unused: warehouse stock resolves against no station and carries no mapping
  // lifecycle. The parameter stays so every transformer has one signature.
  _ctx: PipelineContext,
): StagedRow {
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push(
      issue('unknown_region', 'warning', false,
        `region '${region.raw}' matches no canonical Region`, provenance, region.raw),
    )
  }

  const serial = serialField(raw['Serial Number'], provenance, issues)
  const part = readIdentifier(raw['Part Number'])
  const last = dateField(raw['Last Calibration Date'], 'last calibration date', provenance, issues)
  const next = dateField(raw['Next Calibration Date'], 'next calibration date', provenance, issues)
  const issued = dateField(raw['Warehouse Issue Date'], 'warehouse issue date', provenance, issues)

  return {
      ...baseRow(provenance, raw, 'warehouse_relief_valves'),
      outcome: 'ready',
      // Warehouse stock belongs to no Unit. The installed lifecycle MUST NOT be
      // applied to it, so mappingStatus stays null by construction.
      mappingStatus: null,
      normalized: {
        serial_number: serial.serialNumber,
        part_number: serial.partNumber ?? part.value,
        serial_number_raw: serial.raw,
        serial_status: serial.serialStatus,
        availability_status_raw: cellToText(raw['Availability Status']),
        manufacturer: cellToText(raw['Manufacturer']),
        size_type: cellToText(raw['Size Type']),
        port_in: cellToText(raw['IN']),
        port_out: cellToText(raw['OUT']),
        set_pressure: parsePressure(raw['Set Pressure']),
        warehouse_code: readIdentifier(raw['Warehouse Code']).value,
        calibration_location: cellToText(raw['Calibration Location']),
        assigned_region: region.value,
        assigned_station_raw: cellToText(raw['Station']),
        last_calibration: last,
        next_due_date: next,
        issue_date: issued,
        notes: cellToText(raw['Notes']),
      },
      resolution: {
        note: 'warehouse stock: never merged with installed SRVs, never given a mapping_status',
        ownerConfirmedRule: serial.ownerConfirmedRule,
        droppedColumns: droppedColumns(raw),
      },
      issues,
  }
}

// ---------------------------------------------------------------------------
// Vessels — Location splits this sheet into two different equipment tables
// ---------------------------------------------------------------------------

export function transformVessel(
  provenance: Provenance,
  raw: Record<string, unknown>,
  ctx: PipelineContext,
): StagedRow {
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push(issue('unknown_region', 'warning', false,
      `region '${region.raw}' matches no canonical Region`, provenance, region.raw))
  }

  const location = cellToText(raw['Location'])
  const key = location?.trim().toLowerCase()
  const target =
    key === 'storage' ? 'storage_vessels' : key === 'recovery' ? 'recovery_tanks' : null

  if (target === null) {
    issues.push(
      issue('structurally_invalid_row', 'error', true,
        `Location '${location ?? ''}' selects neither storage_vessel nor recovery_tank; the row names no equipment table`,
        provenance, location),
    )
  }

  const stationRaw = cellToText(raw['Station'])
  const resolution = ctx.resolver.resolve({
    rawName: stationRaw ?? '',
    region: region.value,
    sourceFile: provenance.file,
  })
  const station = resolution.stationId ? ctx.stationsById.get(resolution.stationId) ?? null : null

  let mappingStatus: MappingStatus
  if (!resolution.resolved || station === null) {
    mappingStatus = 'needs_station_mapping'
    issues.push(issue('unmatched_station', 'warning', false,
      `station '${stationRaw ?? ''}' unresolved; the vessel is still staged with station_id NULL`,
      provenance, stationRaw))
  } else if (station.unitIds.length === 1) {
    mappingStatus = 'resolved'
  } else {
    mappingStatus = 'needs_unit_mapping'
  }

  const serial = serialField(raw['Serial Number'], provenance, issues)
  const last = dateField(raw['Last Calibration Date'], 'last calibration date', provenance, issues)
  const next = dateField(raw['Next Calibration Date'], 'next calibration date', provenance, issues)

  return {
      ...baseRow(provenance, raw, target ?? 'storage_vessels'),
      outcome: target === null ? 'rejected' : mappingStatus === 'resolved' ? 'ready' : 'ready_unresolved',
      mappingStatus: target === null ? null : mappingStatus,
      normalized: {
        region: region.value,
        region_raw: region.raw,
        station_id: station?.id ?? null,
        unit_id: mappingStatus === 'resolved' ? station?.unitIds[0] ?? null : null,
        source_station_name_raw: stationRaw,
        location_raw: location,
        // Descriptive text only. Deliberately NOT a foreign key to compressor.
        compressor_context_raw: cellToText(raw['Type OF Compressor']),
        manufacturer: cellToText(raw['Manufacturer']),
        serial_number: serial.serialNumber,
        serial_number_raw: serial.raw,
        serial_status: serial.serialStatus,
        last_calibration: last,
        next_due_date: next,
        notes: cellToText(raw['Notes']),
      },
      resolution: {
        station: { kind: resolution.kind, rule: resolution.rule, proposals: resolution.proposals },
        tableSelectedBy: `Location=${location ?? 'NULL'}`,
        droppedColumns: droppedColumns(raw),
      },
      issues,
  }
}

// ---------------------------------------------------------------------------
// Gas detectors — absence is never given a fake record
// ---------------------------------------------------------------------------

export function transformGasDetector(
  provenance: Provenance,
  raw: Record<string, unknown>,
  ctx: PipelineContext,
): StagedRow {
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push(issue('unknown_region', 'warning', false,
      `region '${region.raw}' matches no canonical Region`, provenance, region.raw))
  }

  const presenceRaw = cellToText(raw['Gas detector exist or not exist in Station'])
  const presenceKey = presenceRaw?.trim().toLowerCase() ?? ''
  const installed = presenceKey.startsWith('exist')
  const notInstalled = presenceKey.startsWith('not exist')

  const stationRaw = cellToText(raw[' Station'] ?? raw['Station'])
  const resolution = ctx.resolver.resolve({
    rawName: stationRaw ?? '',
    region: region.value,
    sourceFile: provenance.file,
  })
  const station = resolution.stationId ? ctx.stationsById.get(resolution.stationId) ?? null : null

  const serial = installed ? serialField(raw['S/N'], provenance, issues) : null
  const last = dateField(raw['Last Calibration Date'], 'last calibration date', provenance, issues)
  const next = dateField(raw['Next Calibration Date'], 'next calibration date', provenance, issues)

  const mappingStatus: MappingStatus =
    station === null ? 'needs_station_mapping' : station.unitIds.length === 1 ? 'resolved' : 'needs_unit_mapping'

  return {
      ...baseRow(provenance, raw, 'gas_detectors'),
      // A "not exist" row records PRESENCE on the unit and creates NO detector.
      outcome: notInstalled ? 'ready' : mappingStatus === 'resolved' ? 'ready' : 'ready_unresolved',
      mappingStatus,
      normalized: {
        region: region.value,
        station_id: station?.id ?? null,
        unit_id: mappingStatus === 'resolved' ? station?.unitIds[0] ?? null : null,
        source_station_name_raw: stationRaw,
        presence: installed ? 'installed' : notInstalled ? 'not_installed' : 'unknown',
        presence_raw: presenceRaw,
        area_type_raw: cellToText(raw[' Open Area / Close Area '] ?? raw['Open Area / Close Area']),
        // Absence creates no detector record at all: no serial, no dates.
        creates_detector_record: installed,
        serial_number: serial?.serialNumber ?? null,
        serial_number_raw: serial?.raw ?? null,
        serial_status: serial?.serialStatus ?? 'unknown',
        last_calibration: installed ? last : null,
        next_due_date: installed ? next : null,
        notes: cellToText(raw['Notes']),
      },
      resolution: {
        station: { kind: resolution.kind, rule: resolution.rule, proposals: resolution.proposals },
        presenceRule: 'absence is recorded on the unit and never given a detector record',
        droppedColumns: droppedColumns(raw),
      },
      issues,
  }
}

// ---------------------------------------------------------------------------
// Hoses
// ---------------------------------------------------------------------------

export function transformHose(
  provenance: Provenance,
  raw: Record<string, unknown>,
  ctx: PipelineContext,
): StagedRow {
  const issues: ImportIssue[] = []
  const region = normalizeRegion(raw['Area'])
  if (region.value === null && region.raw !== null) {
    issues.push(issue('unknown_region', 'warning', false,
      `region '${region.raw}' matches no canonical Region`, provenance, region.raw))
  }

  const stationRaw = cellToText(raw['STATION'])
  const resolution = ctx.resolver.resolve({
    rawName: stationRaw ?? '',
    region: region.value,
    sourceFile: provenance.file,
  })
  const station = resolution.stationId ? ctx.stationsById.get(resolution.stationId) ?? null : null

  const serial = serialField(raw['SN '] ?? raw['SN'], provenance, issues)
  const last = dateField(raw['CALBRATION DATE '] ?? raw['CALBRATION DATE'], 'hydrotest date', provenance, issues)
  const next = dateField(raw['NEXT CLIBRATION DATE'], 'next hydrotest date', provenance, issues)

  // Unit is left NULL unless the Station proves exactly one. A hose is never
  // forced onto a Unit merely to satisfy the hierarchy.
  const mappingStatus: MappingStatus =
    station === null ? 'needs_station_mapping' : station.unitIds.length === 1 ? 'resolved' : 'needs_unit_mapping'

  return {
      ...baseRow(provenance, raw, 'hoses'),
      outcome: mappingStatus === 'resolved' ? 'ready' : 'ready_unresolved',
      mappingStatus,
      normalized: {
        region: region.value,
        region_raw: region.raw,
        station_id: station?.id ?? null,
        unit_id: mappingStatus === 'resolved' ? station?.unitIds[0] ?? null : null,
        source_station_name_raw: stationRaw,
        description: cellToText(raw['DESC']),
        serial_number: serial.serialNumber,
        serial_number_raw: serial.raw,
        serial_status: serial.serialStatus,
        // PSI and BAR both occur. Never converted.
        working_pressure: parsePressure(raw['WORKING  PRESSURE '] ?? raw['WORKING PRESSURE']),
        test_pressure: parsePressure(raw['TEST PRESSURE']),
        last_test: last,
        next_due_date: next,
      },
      resolution: {
        station: { kind: resolution.kind, rule: resolution.rule, proposals: resolution.proposals },
        droppedColumns: droppedColumns(raw),
      },
      issues,
  }
}

export type { CanonicalStation, CanonicalUnit, StoredAlias, SourceConflict }
