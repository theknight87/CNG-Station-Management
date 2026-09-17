import { createHash } from 'node:crypto'
import { describe, expect, it } from 'vitest'
import {
  batchKey,
  buildStagingPayload,
  manifestFingerprint,
  type BuildInput,
  type SourceFile,
} from '../stagingPayload'
import type { ImportIssue, StagedRow } from '../types'

/**
 * The staging payload (Prompt 20F).
 *
 * The database side of this is asserted in SQL against a real PostgreSQL —
 * grants, the canonical firewall and the replay index are catalog facts and are
 * proved there. What only this layer can get wrong is the TRANSFORM: whether the
 * thing handed to the database still says what the source said.
 *
 * So these defend fidelity, not plumbing. Arabic must survive byte-for-byte, a
 * NULL must stay NULL rather than acquiring a helpful default, and the
 * fingerprint must actually change when a workbook changes — otherwise the
 * replay guard in migration 0044 would be enforcing a constant.
 */

const sha256 = (text: string) => createHash('sha256').update(text, 'utf8').digest('hex')

const SOURCES: SourceFile[] = [
  { file: 'Gas detector.xlsx', sha256: 'a'.repeat(64), bytes: 27152 },
  { file: 'HOSES.xlsx', sha256: 'b'.repeat(64), bytes: 16351 },
]

function stagedRow(over: Partial<StagedRow> = {}): StagedRow {
  return {
    provenance: { file: 'Gas detector.xlsx', sheet: 'Sheet1', row: 7 },
    sourceRaw: { Station: 'ابنوب اسيوط', Serial: null, Model: null },
    sourceRowKey: 'Gas detector.xlsx::Sheet1::7',
    sourceRowHash: 'f'.repeat(64),
    targetTable: 'gas_detectors',
    outcome: 'ready_unresolved',
    mappingStatus: 'needs_station_mapping',
    normalized: { station_name_raw: 'ابنوب اسيوط', serial_number: null },
    resolution: { station: 'unmatched' },
    issues: [],
    ...over,
  } as StagedRow
}

function input(over: Partial<BuildInput> = {}): BuildInput {
  return {
    label: 'test',
    startedAt: '2026-09-17T00:00:00.000Z',
    pipelineVersion: 'test',
    sources: SOURCES,
    fingerprint: 'deadbeef',
    files: [
      { file: 'Gas detector.xlsx', sheet: 'Sheet1', headerRow: 1, rowsRead: 316, target: 'gas_detectors' },
      { file: 'HOSES.xlsx', sheet: 'Sheet1', headerRow: 1, rowsRead: 71, target: 'hoses' },
    ],
    excludedSheets: [{ file: 'Warehouse Relief Data.xlsx', sheet: 'Repair Kit ', reason: 'OUT OF SCOPE by instruction; never read' }],
    counts: {},
    mappingStatus: {},
    outcomes: {},
    issuesByType: {},
    ownerConfirmedRuleApplications: {},
    stagedRows: [stagedRow()],
    issues: [],
    conflicts: [],
    ...over,
  }
}

describe('the manifest fingerprint binds the source SET', () => {
  it('is stable regardless of the order the files were listed in', () => {
    const forwards = manifestFingerprint(SOURCES, sha256)
    const backwards = manifestFingerprint([...SOURCES].reverse(), sha256)
    expect(forwards).toBe(backwards)
  })

  it('CHANGES when any one file changes', () => {
    // If this ever held equal, the replay guard in 0044 would be enforcing a
    // constant and an edited workbook could be committed as the approved one.
    const before = manifestFingerprint(SOURCES, sha256)
    const after = manifestFingerprint(
      [SOURCES[0], { ...SOURCES[1], sha256: 'c'.repeat(64) }],
      sha256,
    )
    expect(after).not.toBe(before)
  })

  it('distinguishes the same hash under a different filename', () => {
    const a = manifestFingerprint([{ file: 'one.xlsx', sha256: 'a'.repeat(64), bytes: 1 }], sha256)
    const b = manifestFingerprint([{ file: 'two.xlsx', sha256: 'a'.repeat(64), bytes: 1 }], sha256)
    expect(a).not.toBe(b)
  })
})

describe('the payload preserves what the source said', () => {
  it('carries Arabic through byte-for-byte, raw and normalized', () => {
    const payload = buildStagingPayload(input())
    const row = payload.rows[0] as { source_raw: Record<string, unknown>; normalized: Record<string, unknown> }
    expect(row.source_raw.Station).toBe('ابنوب اسيوط')
    expect(row.normalized.station_name_raw).toBe('ابنوب اسيوط')
    // And it survives a JSON round trip, which is how it reaches PostgreSQL.
    expect(JSON.parse(JSON.stringify(row)).source_raw.Station).toBe('ابنوب اسيوط')
  })

  it('leaves a NULL technical value NULL instead of defaulting it', () => {
    const payload = buildStagingPayload(input())
    const row = payload.rows[0] as { source_raw: Record<string, unknown>; normalized: Record<string, unknown> }
    expect(row.source_raw.Serial).toBeNull()
    expect(row.source_raw.Model).toBeNull()
    expect(row.normalized.serial_number).toBeNull()
  })

  it('preserves the row identity and the content hash the dry run computed', () => {
    const payload = buildStagingPayload(input())
    const row = payload.rows[0] as Record<string, unknown>
    expect(row.source_row_key).toBe('Gas detector.xlsx::Sheet1::7')
    expect(row.source_row_hash).toBe('f'.repeat(64))
  })

  it('keeps the unresolved mapping status rather than resolving anything', () => {
    const payload = buildStagingPayload(input())
    expect((payload.rows[0] as Record<string, unknown>).mapping_status).toBe('needs_station_mapping')
  })
})

describe('the payload cannot misattribute a row', () => {
  it('gives every batch the checksum of its own file', () => {
    const payload = buildStagingPayload(input())
    const byKey = new Map(payload.batches.map((b) => [b.source_file, b.file_checksum]))
    expect(byKey.get('Gas detector.xlsx')).toBe('a'.repeat(64))
    expect(byKey.get('HOSES.xlsx')).toBe('b'.repeat(64))
  })

  it('refuses a source file with no recorded SHA-256', () => {
    expect(() => buildStagingPayload(input({ sources: [SOURCES[0]] })))
      .toThrow(/no SHA-256 recorded for HOSES\.xlsx/)
  })

  it('refuses a staged row that belongs to no batch in this run', () => {
    // A row whose provenance names a sheet the run did not read would otherwise
    // be stored against a NULL batch and lose its traceability.
    const orphan = stagedRow({ provenance: { file: 'Somewhere else.xlsx', sheet: 'Sheet1', row: 1 } })
    expect(() => buildStagingPayload(input({ stagedRows: [orphan] })))
      .toThrow(/unknown batch/)
  })

  it('counts each issue against the batch its own provenance names', () => {
    const issue = (file: string): ImportIssue => ({
      issueType: 'missing_serial', severity: 'warning', blocking: false,
      detail: 'no serial in source', provenance: { file, sheet: 'Sheet1', row: 3 },
    })
    const payload = buildStagingPayload(input({
      issues: [issue('Gas detector.xlsx'), issue('Gas detector.xlsx'), issue('HOSES.xlsx')],
    }))
    const flagged = new Map(payload.batches.map((b) => [b.source_file, b.rows_flagged]))
    expect(flagged.get('Gas detector.xlsx')).toBe(2)
    expect(flagged.get('HOSES.xlsx')).toBe(1)
  })
})

describe('staging imports nothing and decides nothing', () => {
  it('reports rows_imported as 0 on every batch — that column means CANONICAL insertion', () => {
    const payload = buildStagingPayload(input())
    // The builder never sets it; the database writes 0. Staging is not an import.
    for (const b of payload.batches) {
      expect(Object.keys(b)).not.toContain('rows_imported')
    }
  })

  it('emits no mapping decision of any kind', () => {
    const payload = buildStagingPayload(input())
    const serialized = JSON.stringify(payload)
    expect(serialized).not.toContain('mapping_decision')
    expect(serialized).not.toContain('reviewed_source_row_hash')
  })

  it('records the excluded Repair Kit sheet as evidence, and stages no row from it', () => {
    const payload = buildStagingPayload(input())
    expect(payload.manifest.excluded_sheets.some((e) => e.sheet.trim() === 'Repair Kit')).toBe(true)
    expect(payload.batches.some((b) => b.source_sheet.trim() === 'Repair Kit')).toBe(false)
    expect(payload.rows.some((r) => String((r as Record<string, unknown>).source_sheet).trim() === 'Repair Kit')).toBe(false)
  })

  it('keys a batch by file and sheet, so two sheets of one workbook stay apart', () => {
    expect(batchKey('Warehouse Relief Data.xlsx', 'رصيد المحطات'))
      .not.toBe(batchKey('Warehouse Relief Data.xlsx', 'رصيد المخزن'))
  })
})
