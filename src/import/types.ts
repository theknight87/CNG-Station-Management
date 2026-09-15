/**
 * Import pipeline types.
 *
 * The governing rule (CLAUDE.md §6, prompt §3): import every verified value,
 * leave missing values NULL, and never fabricate. NULL is valid data, not an
 * error, and never blocks creation of a record.
 */

/** Where a value came from. Enough to reconstruct the source cell. */
export interface Provenance {
  file: string
  sheet: string
  /** 1-based, as the workbook numbers it. */
  row: number
  column?: string
}

/**
 * A normalized value that NEVER loses its raw original (principle #6, §4).
 * `raw` is what the cell held; `value` is the normalized form, or null when
 * normalization is not deterministic. They stay distinguishable forever.
 */
export interface Normalized<T> {
  value: T | null
  raw: string | null
  /** Names the rule that produced `value`. Absent when nothing was applied. */
  rule?: string
}

export type DatePrecision = 'exact_date' | 'year_only' | 'unknown' | 'invalid'

/** A date is always a triple. Only `exact_date` may ever drive an alert. */
export interface NormalizedDate {
  value: string | null // ISO yyyy-mm-dd, ONLY when precision is exact_date
  precision: DatePrecision
  raw: string | null
  /** Kept for year_only so the source year stays visible without inventing a day. */
  year: number | null
  /** Source status text such as منتهي, preserved rather than converted (D6). */
  sourceStatusRaw?: string | null
}

export type IdentifierKind = 'serial_number' | 'part_number'

/**
 * An identifier is TEXT, always. It is never parsed as a number, never padded,
 * never stripped, never corrected.
 */
export interface NormalizedIdentifier {
  serialNumber: string | null
  partNumber: string | null
  serialStatus: 'assigned' | 'not_yet_assigned' | 'unknown'
  raw: string | null
  /** Set only when an OWNER-CONFIRMED rule fired, naming that rule. */
  ownerConfirmedRule?: string
  /** Shape looks like a part number but nothing confirms it: flag, never act. */
  suspectedPartNumber?: boolean
}

export type CanonicalRegion = 'East' | 'West' | 'Canal' | 'Delta' | 'Alex' | 'Upper'

export type StagingOutcome =
  | 'ready'
  | 'ready_unresolved'
  | 'proposal_only'
  | 'conflict'
  | 'rejected'
  | 'excluded'
  | 'replayed'

export type MappingStatus =
  | 'needs_station_mapping'
  | 'needs_unit_mapping'
  | 'needs_equipment_mapping'
  | 'resolved'
  | 'conflict'

export type IssueSeverity = 'info' | 'warning' | 'error'

/**
 * BLOCKING vs NON-BLOCKING (prompt §23) is a property of the issue, not of
 * NULL-ness. A missing optional serial is non-blocking. An unknown Station for
 * an installed SRV is non-blocking too: the SRV stages as
 * needs_station_mapping rather than being rejected.
 */
export interface ImportIssue {
  issueType: string
  severity: IssueSeverity
  blocking: boolean
  detail: string
  sourceValue?: string | null
  provenance: Provenance
}

/** One source row after parsing, normalization, matching and validation. */
export interface StagedRow {
  provenance: Provenance
  /** The ENTIRE source row, verbatim. Never overwritten. */
  sourceRaw: Record<string, unknown>
  sourceRowKey: string
  sourceRowHash: string
  targetTable: string
  outcome: StagingOutcome
  mappingStatus: MappingStatus | null
  normalized: Record<string, unknown>
  /** How each resolution was reached, so a value is explainable. */
  resolution: Record<string, unknown>
  issues: ImportIssue[]
}

/** Two sources disagreeing on one field of one entity. Neither is chosen. */
export interface SourceConflict {
  entityKind: string
  entityKey: string
  fieldName: string
  leftValueRaw: string | null
  leftSource: Provenance
  rightValueRaw: string | null
  rightSource: Provenance
  /** Only where import-mapping.md §8 declares one. Null = a human decides. */
  precedenceRule: string | null
  selectedSide: 'left' | 'right' | null
}

/** A fuzzy suggestion. Advisory only — it never establishes identity. */
export interface MatchProposal {
  rawName: string
  candidateId: string | null
  candidateName: string
  score: number
  method: string
  /** Always false in this pipeline. Kept explicit so the invariant is visible. */
  autoAccepted: false
}
