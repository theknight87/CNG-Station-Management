import type { ImportIssue, SourceConflict, StagedRow } from './types'

/**
 * Turns a dry-run result into the jsonb payload `cng_stage_import_batch` stores.
 *
 * PURE. It opens no connection, reads no file and decides nothing. That is the
 * point: the shape sent to the database is testable here, and the transform
 * between "what the dry run computed" and "what gets persisted" is a function
 * rather than something buried in a script.
 *
 * It also fabricates nothing. Every field is copied through; a NULL stays NULL,
 * Arabic travels as a JSON string and is stored byte-for-byte, and no value is
 * normalized, defaulted or inferred a second time.
 */

/** One source file and the SHA-256 the runner computed for it. */
export interface SourceFile {
  file: string
  sha256: string
  bytes: number
}

export interface BatchPayload {
  batch_key: string
  source_file: string
  source_sheet: string
  file_checksum: string
  header_row: number
  rows_read: number
  rows_flagged: number
  rows_failed: number
  metadata: Record<string, unknown>
}

export interface StagingPayload {
  manifest: {
    label: string
    started_at: string
    manifest_fingerprint: string
    pipeline_version: string
    sources: SourceFile[]
    counts: Record<string, number>
    mapping_status: Record<string, number>
    outcomes: Record<string, number>
    issues_by_type: Record<string, number>
    excluded_sheets: Array<{ file: string; sheet: string; reason: string }>
    owner_confirmed_rule_applications: Record<string, unknown>
  }
  batches: BatchPayload[]
  rows: Array<Record<string, unknown>>
  issues: Array<Record<string, unknown>>
  conflicts: Array<Record<string, unknown>>
}

/** A batch is one file/sheet pair. The key ties rows and issues to it. */
export function batchKey(file: string, sheet: string): string {
  return `${file}::${sheet}`
}

/** Separators that cannot occur inside a filename or a hex digest. */
const FIELD_SEP = String.fromCharCode(0)
const RECORD_SEP = String.fromCharCode(30)

/**
 * The fingerprint of a source SET.
 *
 * Every file name and its SHA-256, sorted so file order cannot change the
 * value. Identical source content therefore always produces the identical
 * fingerprint, and ANY changed byte in ANY workbook produces a different one —
 * which is what makes the replay guard in migration 0044 meaningful rather than
 * advisory.
 *
 * `hash` is injected so this stays pure and runs unchanged in a test.
 */
export function manifestFingerprint(
  sources: SourceFile[],
  hash: (input: string) => string,
): string {
  const canonical = [...sources]
    .sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : 0))
    .map((s) => `${s.file}${FIELD_SEP}${s.sha256}`)
    .join(RECORD_SEP)
  return hash(canonical)
}

export interface BuildInput {
  label: string
  startedAt: string
  pipelineVersion: string
  sources: SourceFile[]
  fingerprint: string
  files: Array<{ file: string; sheet: string; headerRow: number; rowsRead: number; target: string }>
  excludedSheets: Array<{ file: string; sheet: string; reason: string }>
  counts: Record<string, number>
  mappingStatus: Record<string, number>
  outcomes: Record<string, number>
  issuesByType: Record<string, number>
  ownerConfirmedRuleApplications: Record<string, unknown>
  stagedRows: StagedRow[]
  issues: ImportIssue[]
  conflicts: SourceConflict[]
}

export function buildStagingPayload(input: BuildInput): StagingPayload {
  const checksumOf = new Map(input.sources.map((s) => [s.file, s.sha256]))

  // An issue belongs to the batch its own provenance names. Counting them per
  // batch here — rather than storing a total on the run — is what lets a
  // reviewer see which sheet produced which problems.
  const flagged = new Map<string, number>()
  for (const issue of input.issues) {
    const key = batchKey(issue.provenance.file, issue.provenance.sheet)
    flagged.set(key, (flagged.get(key) ?? 0) + 1)
  }

  const batches: BatchPayload[] = input.files.map((f) => {
    const key = batchKey(f.file, f.sheet)
    const checksum = checksumOf.get(f.file)
    if (!checksum) throw new Error(`no SHA-256 recorded for ${f.file}`)
    return {
      batch_key: key,
      source_file: f.file,
      source_sheet: f.sheet,
      file_checksum: checksum,
      header_row: f.headerRow,
      rows_read: f.rowsRead,
      rows_flagged: flagged.get(key) ?? 0,
      // Staging never fails a row: an unusable value becomes an ISSUE against a
      // preserved row (principle #10). A row is absent only where the source has
      // no row, which the reader reports as rowsRead.
      rows_failed: 0,
      metadata: { target_table: f.target },
    }
  })

  const known = new Set(batches.map((b) => b.batch_key))
  const rows = input.stagedRows.map((r) => {
    const key = batchKey(r.provenance.file, r.provenance.sheet)
    if (!known.has(key)) throw new Error(`staged row references unknown batch ${key}`)
    return {
      batch_key: key,
      source_file: r.provenance.file,
      source_sheet: r.provenance.sheet,
      source_row: r.provenance.row,
      source_raw: r.sourceRaw,
      source_row_key: r.sourceRowKey,
      source_row_hash: r.sourceRowHash,
      target_table: r.targetTable,
      outcome: r.outcome,
      mapping_status: r.mappingStatus,
      normalized: r.normalized,
      resolution: r.resolution,
    }
  })

  const issues = input.issues.map((i) => ({
    batch_key: batchKey(i.provenance.file, i.provenance.sheet),
    source_file: i.provenance.file,
    source_sheet: i.provenance.sheet,
    source_row: i.provenance.row,
    source_raw: null,
    source_value: i.sourceValue ?? null,
    issue_type: i.issueType,
    severity: i.severity,
    detail: i.detail,
  }))

  const conflicts = input.conflicts.map((c) => ({
    entity_kind: c.entityKind,
    entity_key: c.entityKey,
    field_name: c.fieldName,
    left_value_raw: c.leftValueRaw,
    left_source: c.leftSource,
    right_value_raw: c.rightValueRaw,
    right_source: c.rightSource,
    precedence_rule: c.precedenceRule,
    selected_side: c.selectedSide,
  }))

  return {
    manifest: {
      label: input.label,
      started_at: input.startedAt,
      manifest_fingerprint: input.fingerprint,
      pipeline_version: input.pipelineVersion,
      sources: input.sources,
      counts: input.counts,
      mapping_status: input.mappingStatus,
      outcomes: input.outcomes,
      issues_by_type: input.issuesByType,
      excluded_sheets: input.excludedSheets,
      owner_confirmed_rule_applications: input.ownerConfirmedRuleApplications,
    },
    batches,
    rows,
    issues,
    conflicts,
  }
}
