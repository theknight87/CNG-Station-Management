import { createHash } from 'node:crypto'

import type { Provenance, StagedRow } from './types'

/**
 * Idempotency and replay detection (prompt section 21).
 *
 * Identity is (file, sheet, row) -- never a display name. Content is hashed
 * separately, so the pipeline can tell a REPLAY of the same row from a
 * genuinely CHANGED source row at the same position.
 */

const FIELD_SEPARATOR = String.fromCharCode(1)
const NULL_MARKER = String.fromCharCode(0)

/** Stable across runs: where the row lives in the workbook. */
export function sourceRowKey(p: Provenance): string {
  return `${p.file}::${p.sheet}::${p.row}`
}

/**
 * Changes when the row content changes. Keys are sorted so column order in the
 * workbook cannot alter the hash, and values are rendered in a stable way that
 * keeps a number and the string of that number distinguishable.
 */
export function sourceRowHash(row: Record<string, unknown>): string {
  const canonical = Object.keys(row)
    .sort()
    .map((k) => `${k}=${renderForHash(row[k])}`)
    .join(FIELD_SEPARATOR)
  return createHash('sha256').update(canonical, 'utf8').digest('hex')
}

function renderForHash(value: unknown): string {
  if (value === null || value === undefined) return NULL_MARKER
  if (value instanceof Date) return `D:${value.toISOString()}`
  if (typeof value === 'object') return `J:${JSON.stringify(value)}`
  return `${typeof value}:${String(value)}`
}

export interface PriorRow {
  sourceRowKey: string
  sourceRowHash: string
}

export type ReplayVerdict =
  | { kind: 'new' }
  | { kind: 'replay'; reason: string }
  | { kind: 'changed'; reason: string }

/**
 * Compares one row against what previous runs staged.
 *
 *   same key + same hash -> replay; a commit must not create a second entity
 *   same key + new hash  -> the source file genuinely changed at that row
 *   unknown key          -> new
 */
export function classifyReplay(
  row: Pick<StagedRow, 'sourceRowKey' | 'sourceRowHash'>,
  priorByKey: Map<string, string>,
): ReplayVerdict {
  const priorHash = priorByKey.get(row.sourceRowKey)
  if (priorHash === undefined) return { kind: 'new' }
  if (priorHash === row.sourceRowHash) {
    return { kind: 'replay', reason: 'identical source row already staged by an earlier run' }
  }
  return {
    kind: 'changed',
    reason: 'same file/sheet/row, different content: the source file changed at this position',
  }
}

export function buildPriorIndex(prior: PriorRow[]): Map<string, string> {
  return new Map(prior.map((p) => [p.sourceRowKey, p.sourceRowHash]))
}
