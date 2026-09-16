import { describe, expect, it } from 'vitest'

import {
  applyDecision, indexDecisions, planImport, planRow,
  type ConfirmedMapping,
} from '@/import/mappingDecisions'
import type { StagedRow } from '@/import/types'

/**
 * The pre-import decision → import plan path.
 *
 * What these defend is the boundary between four different kinds of statement:
 * raw evidence, an automated candidate, a global owner rule, and one human's
 * ruling about one row. The import plan may act on the last of those and must
 * not confuse it with any of the others.
 */

const RAW = { Station: 'TESTDATA-RAW-STATION', Area: 'EAST', 'Serial Number': 'SV-001' }

function stagedVessel(overrides: Partial<StagedRow> = {}): StagedRow {
  return {
    provenance: { file: 'V.xlsx', sheet: 'Sheet1', row: 11 },
    sourceRaw: RAW,
    sourceRowKey: 'V.xlsx#Sheet1#11',
    sourceRowHash: 'hash-1',
    targetTable: 'storage_vessels',
    outcome: 'ready_unresolved',
    mappingStatus: 'needs_station_mapping',
    normalized: {
      region_raw: 'EAST',
      source_station_name_raw: 'TESTDATA-RAW-STATION',
      station_id: null,
      unit_id: null,
      serial_number: 'SV-001',
    },
    resolution: {
      station: { kind: 'unmatched', rule: null, proposals: [{ name: 'Abnub', score: 0.71 }] },
    },
    issues: [],
    ...overrides,
  }
}

const DECISION: ConfirmedMapping = {
  sourceRowKey: 'V.xlsx#Sheet1#11',
  targetTable: 'storage_vessels',
  confirmedStationId: 'station-1',
  confirmedUnitId: 'unit-1',
  regionId: 'region-east',
  resultingMappingStatus: 'resolved',
  decidedBy: 'admin-1',
  decidedAt: '2026-09-16T10:00:00Z',
}

describe('an unresolved staged row with no decision', () => {
  it('is held, not committed, and nothing upgrades it on its own', () => {
    const plan = planImport([stagedVessel()], [])
    expect(plan.counts.holdNeedsStation).toBe(1)
    expect(plan.counts.commit).toBe(0)
    expect(plan.rows[0].stationId).toBeNull()
    expect(plan.rows[0].mappingStatus).toBe('needs_station_mapping')
  })

  it('is not resolved by a similarity proposal, however confident', () => {
    const row = stagedVessel()
    // The row carries a 0.71 proposal. The plan ignores it completely.
    expect((row.resolution.station as { proposals: unknown[] }).proposals).toHaveLength(1)
    expect(planRow(row, new Map()).plan).toBe('hold_needs_station')
    expect(planRow(row, new Map()).decided).toBe(false)
  })
})

describe('an unresolved staged row WITH a human decision', () => {
  it('becomes committable, using the confirmed ids', () => {
    const plan = planImport([stagedVessel()], [DECISION])
    expect(plan.counts.commit).toBe(1)
    expect(plan.counts.decided).toBe(1)
    expect(plan.rows[0].stationId).toBe('station-1')
    expect(plan.rows[0].unitId).toBe('unit-1')
    expect(plan.rows[0].regionId).toBe('region-east')
    expect(plan.rows[0].mappingStatus).toBe('resolved')
  })

  it('carries a Station-only decision as still needing its Unit', () => {
    const stationOnly: ConfirmedMapping = {
      ...DECISION, confirmedUnitId: null, resultingMappingStatus: 'needs_unit_mapping',
    }
    const plan = planImport([stagedVessel()], [stationOnly])
    // Committable — the NOT NULL column is satisfied — but honest about the Unit.
    expect(plan.counts.commit).toBe(1)
    expect(plan.rows[0].unitId).toBeNull()
    expect(plan.rows[0].mappingStatus).toBe('needs_unit_mapping')
  })

  it('leaves the raw source evidence byte-for-byte unchanged', () => {
    const row = stagedVessel()
    const applied = applyDecision(row, DECISION)
    expect(applied.sourceRaw).toEqual(RAW)
    expect(applied.sourceRaw).toBe(row.sourceRaw)
    expect(applied.sourceRowKey).toBe(row.sourceRowKey)
    expect(applied.sourceRowHash).toBe(row.sourceRowHash)
    expect(applied.provenance).toEqual(row.provenance)
    // The original object is not mutated either.
    expect(row.mappingStatus).toBe('needs_station_mapping')
    expect(row.normalized.station_id).toBeNull()
  })

  it('keeps what the pipeline concluded beside what the human decided', () => {
    const applied = applyDecision(stagedVessel(), DECISION)
    expect(applied.normalized.staged_mapping_status).toBe('needs_station_mapping')
    expect(applied.mappingStatus).toBe('resolved')
    expect(applied.resolution.station).toEqual({
      kind: 'unmatched', rule: null, proposals: [{ name: 'Abnub', score: 0.71 }],
    })
  })

  it('records that a human, not a rule, supplied the ids', () => {
    const applied = applyDecision(stagedVessel(), DECISION)
    const human = applied.resolution.human_decision as Record<string, string>
    expect(human.kind).toBe('row_level_mapping_decision')
    expect(human.decided_by).toBe('admin-1')
    expect(human.scope).toMatch(/this source row only/i)
    expect(human.scope).toMatch(/NOT an alias/i)
  })
})

describe('a decision is bound to ONE source row', () => {
  it('does not resolve a second row carrying the identical raw station text', () => {
    const rowA = stagedVessel()
    const rowB = stagedVessel({ sourceRowKey: 'V.xlsx#Sheet1#12', sourceRowHash: 'hash-2' })
    const plan = planImport([rowA, rowB], [DECISION])
    expect(plan.counts.commit).toBe(1)
    expect(plan.counts.holdNeedsStation).toBe(1)
    // Identical raw text, identical proposal, opposite outcome — which is the
    // whole point: a row decision is not an alias rule.
    expect(rowB.normalized.source_station_name_raw).toBe(rowA.normalized.source_station_name_raw)
    expect(plan.rows[1].decided).toBe(false)
  })

  it('refuses to be applied to another row', () => {
    const other = stagedVessel({ sourceRowKey: 'V.xlsx#Sheet1#99' })
    expect(() => applyDecision(other, DECISION)).toThrow(/its own source row/i)
  })

  it('is ignored when the target table does not match', () => {
    const hose = stagedVessel({ targetTable: 'hoses' })
    expect(planRow(hose, new Map([[DECISION.sourceRowKey, DECISION]])).decided).toBe(false)
    expect(() => applyDecision(hose, DECISION)).toThrow(/its own target table/i)
  })

  it('rejects two active decisions for one row rather than picking one', () => {
    expect(() => indexDecisions([DECISION, { ...DECISION, confirmedStationId: 'station-2' }]))
      .toThrow(/two active mapping decisions/i)
  })
})

describe('asset types that are not pre-import mappable', () => {
  it('leaves an installed SRV staging row alone', () => {
    // Installed SRVs have a nullable canonical station_id: they import
    // unresolved and are mapped in the canonical table, not here.
    const srv = stagedVessel({ targetTable: 'installed_relief_valves' })
    const planned = planRow(srv, new Map([[DECISION.sourceRowKey, DECISION]]))
    expect(planned.plan).toBe('not_applicable')
    expect(planned.decided).toBe(false)
    expect(planned.mappingStatus).toBe('needs_station_mapping')
  })
})

describe('the whole replay, end to end', () => {
  it('goes raw unresolved row → decision → plan that would commit confirmed ids', () => {
    const row = stagedVessel()

    // 1. The dry run staged it unresolved; a commit would hold it.
    expect(planImport([row], []).counts.holdNeedsStation).toBe(1)

    // 2. A human decides. (In the database this is cng_admin_decide_staged_mapping;
    //    here it is the row that function writes.)
    const decisions = [DECISION]

    // 3. A REPLAY of the same staged row now recognises the decision...
    const replanned = planImport([row], decisions)
    expect(replanned.counts.commit).toBe(1)
    expect(replanned.rows[0].decided).toBe(true)

    // 4. ...and the row a commit would write carries the confirmed ids while the
    //    raw source is still exactly what the workbook said.
    const committable = applyDecision(row, DECISION)
    expect(committable.normalized.station_id).toBe('station-1')
    expect(committable.normalized.unit_id).toBe('unit-1')
    expect(committable.sourceRaw).toEqual(RAW)
    expect(committable.outcome).toBe('ready')
  })
})
