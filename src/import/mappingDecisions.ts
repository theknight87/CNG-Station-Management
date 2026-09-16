import type { MappingStatus, StagedRow } from './types'

/**
 * How the import plan consumes human pre-import mapping decisions.
 *
 * THE PROBLEM. `storage_vessels`, `recovery_tanks`, `gas_detectors` and `hoses`
 * all declare `station_id NOT NULL`. The Prompt 6 dry run staged 1,104 rows in
 * `needs_station_mapping`, and none of them can be committed as staged. The
 * resolution is not to relax the column — a vessel with no proven Station is
 * precisely the record principle #8 says must never be guessed — but to let a
 * human confirm the Station BEFORE the commit, while the evidence is still here.
 *
 * THE RULE THIS MODULE ENFORCES, and the reason it is a separate module rather
 * than a branch inside the pipeline:
 *
 *   A decision applies to ONE SOURCE ROW, matched on `sourceRowKey` — the
 *   (file, sheet, row) identity — AND on `sourceRowHash`, the content that was
 *   actually reviewed. It is NOT an alias. A second row carrying the same raw
 *   Station text gets nothing from it, however obvious the match looks. Turning
 *   a row decision into a rule is exactly the silent guess CLAUDE.md §8 forbids,
 *   and there is no code path here that could do it.
 *
 * WHY THE HASH, AND NOT THE KEY ALONE (Prompt 19B).
 *
 *   `sourceRowKey` says WHERE the row was. It does not say WHAT the
 *   administrator read. A workbook is a live document: rows get inserted,
 *   deleted, re-ordered and overwritten, so `V.xlsx#Sheet1#11` may hold a
 *   different vessel next month. Matching on the key alone would attach last
 *   month's Station to this month's asset — a fabricated physical relationship
 *   nobody guessed at, which is precisely what principle #8 exists to stop.
 *
 *   So reuse requires BOTH halves. A key match with a hash mismatch is a
 *   STALE-SOURCE decision: not applied, not silently demoted to "no decision",
 *   and its Station/Unit never injected. It is a distinct plan state so the
 *   reason a previous ruling stopped counting stays visible.
 *
 * RAW EVIDENCE IS NEVER TOUCHED. `sourceRaw`, `sourceRowKey`, `sourceRowHash`,
 * `provenance` and the original `resolution` are copied through unchanged; the
 * staged row's own `mappingStatus` is preserved under
 * `normalized.staged_mapping_status` so what the pipeline concluded on its own
 * stays legible beside what a human decided.
 */

/** The four pre-import asset types. Installed SRVs map in the canonical table. */
export const PRE_IMPORT_TARGETS = [
  'storage_vessels',
  'recovery_tanks',
  'gas_detectors',
  'hoses',
] as const

export type PreImportTarget = (typeof PRE_IMPORT_TARGETS)[number]

/** One ACTIVE row from `v_import_confirmed_mappings`. */
export interface ConfirmedMapping {
  sourceRowKey: string
  /**
   * The `source_row_hash` of the staging row this decision was made FROM,
   * captured server-side by `cng_admin_decide_staged_mapping`. Required, not
   * optional: a decision that cannot say what it reviewed cannot be reused.
   */
  reviewedSourceRowHash: string
  targetTable: string
  confirmedStationId: string
  confirmedUnitId: string | null
  regionId: string
  resultingMappingStatus: 'needs_unit_mapping' | 'resolved'
  decidedBy: string
  decidedAt: string
}

export interface PlannedRow {
  row: StagedRow
  /** `true` when a human decision supplied the ids below. */
  decided: boolean
  stationId: string | null
  unitId: string | null
  regionId: string | null
  mappingStatus: MappingStatus | null
  /** Why this row is or is not committable, in one word a report can group by. */
  plan: 'commit' | 'hold_needs_station' | 'stale_source_decision' | 'not_applicable'
  /**
   * The decision that APPLIES. Null when none does — including when one exists
   * for this source row but was made against different content, which is what
   * `staleDecision` carries instead. Keeping them apart is the point: a stale
   * decision must never be reachable through the field a caller would apply.
   */
  decision: ConfirmedMapping | null
  /** A decision for this source row whose reviewed content no longer matches. */
  staleDecision: ConfirmedMapping | null
}

export function isPreImportTarget(target: string): target is PreImportTarget {
  return (PRE_IMPORT_TARGETS as readonly string[]).includes(target)
}

/**
 * Index decisions by source row. A duplicate key is a bug in the caller's query,
 * not something to resolve by preferring one — the database already guarantees
 * one ACTIVE decision per source row via `imd_one_active_per_source_row`.
 */
export function indexDecisions(decisions: ConfirmedMapping[]): Map<string, ConfirmedMapping> {
  const byKey = new Map<string, ConfirmedMapping>()
  for (const decision of decisions) {
    if (byKey.has(decision.sourceRowKey)) {
      throw new Error(
        `two active mapping decisions for ${decision.sourceRowKey}; the database forbids this, so the query is wrong`,
      )
    }
    byKey.set(decision.sourceRowKey, decision)
  }
  return byKey
}

/**
 * Decide what a commit would do with one staged row.
 *
 * A row with no decision keeps exactly the status the pipeline gave it. Nothing
 * here upgrades a row on its own.
 */
export function planRow(row: StagedRow, byKey: Map<string, ConfirmedMapping>): PlannedRow {
  const stagedStation = (row.normalized.station_id as string | null) ?? null
  const stagedUnit = (row.normalized.unit_id as string | null) ?? null
  const stagedRegion = (row.normalized.region_id as string | null) ?? null

  if (!isPreImportTarget(row.targetTable)) {
    return {
      row, decided: false, decision: null, staleDecision: null,
      stationId: stagedStation, unitId: stagedUnit, regionId: stagedRegion,
      mappingStatus: row.mappingStatus, plan: 'not_applicable',
    }
  }

  const candidate = byKey.get(row.sourceRowKey) ?? null

  // A decision is only honoured for the table it was recorded against. A
  // decision about a hose row must never resolve a vessel row that happens to
  // share a source row key across files.
  if (candidate === null || candidate.targetTable !== row.targetTable) {
    const committable = stagedStation !== null
    return {
      row, decided: false, decision: null, staleDecision: null,
      stationId: stagedStation, unitId: stagedUnit, regionId: stagedRegion,
      mappingStatus: row.mappingStatus,
      plan: committable ? 'commit' : 'hold_needs_station',
    }
  }

  // THE CONTENT CHECK. The key matched; the content did not. The decision was
  // made about a row that no longer says what it said, so it is held for human
  // re-review — and reported as such, rather than being quietly rewritten into
  // "there is no decision", which would hide why the previous ruling lapsed.
  //
  // The staged values are carried through UNCHANGED: the old confirmed ids are
  // not injected, not even as a default.
  if (candidate.reviewedSourceRowHash !== row.sourceRowHash) {
    return {
      row, decided: false, decision: null, staleDecision: candidate,
      stationId: stagedStation, unitId: stagedUnit, regionId: stagedRegion,
      mappingStatus: row.mappingStatus,
      plan: 'stale_source_decision',
    }
  }

  return {
    row, decided: true, decision: candidate, staleDecision: null,
    stationId: candidate.confirmedStationId,
    unitId: candidate.confirmedUnitId,
    regionId: candidate.regionId,
    mappingStatus: candidate.resultingMappingStatus,
    plan: 'commit',
  }
}

/**
 * Apply a decision to a staged row, returning a NEW row.
 *
 * The original is not mutated and its raw columns are copied through untouched.
 * `resolution.human_decision` records that a human, not a rule, supplied these
 * ids — so a later reader can tell a confirmed mapping from a matched alias.
 */
export function applyDecision(row: StagedRow, decision: ConfirmedMapping): StagedRow {
  if (decision.sourceRowKey !== row.sourceRowKey) {
    throw new Error('a mapping decision may only be applied to its own source row')
  }
  if (decision.targetTable !== row.targetTable) {
    throw new Error('a mapping decision may only be applied to its own target table')
  }
  // Defence in depth. `planRow` already refuses this, but `applyDecision` is
  // what actually writes the confirmed ids, so the invariant is enforced where
  // the damage would be done rather than only where it is detected.
  if (decision.reviewedSourceRowHash !== row.sourceRowHash) {
    throw new Error(
      'stale_source_decision: this decision was made against different source content and must be re-reviewed',
    )
  }
  return {
    ...row,
    // sourceRaw, sourceRowKey, sourceRowHash and provenance are carried by the
    // spread and are deliberately not rewritten below.
    outcome: decision.resultingMappingStatus === 'resolved' ? 'ready' : 'ready_unresolved',
    mappingStatus: decision.resultingMappingStatus,
    normalized: {
      ...row.normalized,
      station_id: decision.confirmedStationId,
      unit_id: decision.confirmedUnitId,
      region_id: decision.regionId,
      // What the pipeline concluded on its own, kept beside the human ruling.
      staged_mapping_status: row.mappingStatus,
    },
    resolution: {
      ...row.resolution,
      human_decision: {
        kind: 'row_level_mapping_decision',
        decided_by: decision.decidedBy,
        decided_at: decision.decidedAt,
        // Recorded so a later reader can re-check the binding rather than
        // taking this module's word for it.
        reviewed_source_row_hash: decision.reviewedSourceRowHash,
        // Stated in the data itself, so nobody reading a report later mistakes
        // this for a rule that generalises.
        scope: 'this source row only; NOT an alias and NOT a global rule',
      },
    },
  }
}

export interface ImportPlan {
  rows: PlannedRow[]
  counts: {
    commit: number
    holdNeedsStation: number
    staleSourceDecision: number
    notApplicable: number
    decided: number
  }
}

/**
 * Build the plan a commit would follow. Read-only: it writes nothing, opens
 * nothing, and is the same shape whether or not any decision exists.
 */
export function planImport(rows: StagedRow[], decisions: ConfirmedMapping[]): ImportPlan {
  const byKey = indexDecisions(decisions)
  const planned = rows.map((row) => planRow(row, byKey))
  return {
    rows: planned,
    counts: {
      commit: planned.filter((p) => p.plan === 'commit').length,
      holdNeedsStation: planned.filter((p) => p.plan === 'hold_needs_station').length,
      staleSourceDecision: planned.filter((p) => p.plan === 'stale_source_decision').length,
      notApplicable: planned.filter((p) => p.plan === 'not_applicable').length,
      decided: planned.filter((p) => p.decided).length,
    },
  }
}
