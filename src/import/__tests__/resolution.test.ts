import { describe, expect, it } from 'vitest'

import {
  OWNER_CONFIRMED_STATION_ALIASES,
  StationResolver,
  type CanonicalStation,
  type CanonicalUnit,
  type StoredAlias,
} from '../resolve/stations'
import {
  decideInstalledSrvMapping,
  expectedParentKindFromLocation,
  visibleInUnitSrvTab,
} from '../resolve/srvMapping'
import { buildPriorIndex, classifyReplay, sourceRowHash, sourceRowKey } from '../staging'

const stations: CanonicalStation[] = [
  { id: 'st-abnoub', name: 'ابنوب', region: 'Upper', unitIds: ['u-abnoub-1'] },
  { id: 'st-shobra', name: 'شبرا', region: 'East', unitIds: ['u-s1', 'u-s2', 'u-s3', 'u-s4'] },
  { id: 'st-khamayel', name: 'الخمائل', region: 'West', unitIds: ['u-k1', 'u-k2'] },
  { id: 'st-nounits', name: 'محطة بلا وحدات', region: 'Canal', unitIds: [] },
]
const units: CanonicalUnit[] = [
  { id: 'u-abnoub-1', name: 'ابنوب 1', stationId: 'st-abnoub' },
  { id: 'u-s1', name: 'شبرا 1', stationId: 'st-shobra' },
  { id: 'u-s2', name: 'شبرا 2', stationId: 'st-shobra' },
  { id: 'u-s3', name: 'شبرا 3', stationId: 'st-shobra' },
  { id: 'u-s4', name: 'شبرا 4', stationId: 'st-shobra' },
  { id: 'u-k1', name: 'الخمائل 1', stationId: 'st-khamayel' },
  { id: 'u-k2', name: 'الخمائل 2', stationId: 'st-khamayel' },
]
const byId = new Map(stations.map((s) => [s.id, s]))

function resolver(aliases: StoredAlias[] = []) {
  return new StationResolver(stations, units, aliases)
}

describe('station resolution is conservative', () => {
  it('RESOLVE-1 an exact canonical name resolves', () => {
    const r = resolver().resolve({ rawName: 'شبرا', region: 'East', sourceFile: 'f.xlsx' })
    expect(r.resolved).toBe(true)
    expect(r.kind).toBe('exact_canonical')
    expect(r.stationId).toBe('st-shobra')
  })

  it('RESOLVE-2 a CONFIRMED stored alias resolves', () => {
    const r = resolver([
      { rawName: 'Shobra', region: 'East', sourceFile: null, stationId: 'st-shobra', unitId: null, status: 'confirmed' },
    ]).resolve({ rawName: 'Shobra', region: 'East', sourceFile: 'f.xlsx' })
    expect(r.resolved).toBe(true)
    expect(r.kind).toBe('confirmed_alias')
  })

  it('RESOLVE-3 a PROPOSED alias does NOT resolve and attaches nothing', () => {
    const r = resolver([
      { rawName: 'Shobra', region: 'East', sourceFile: null, stationId: 'st-shobra', unitId: null, status: 'proposed' },
    ]).resolve({ rawName: 'Shobra', region: 'East', sourceFile: 'f.xlsx' })
    expect(r.resolved).toBe(false)
    expect(r.stationId).toBeNull()
  })

  it('RESOLVE-4 the owner-confirmed pair ابنوب اسيوط = ابنوب resolves', () => {
    const r = resolver().resolve({ rawName: 'ابنوب اسيوط', region: 'Upper', sourceFile: 'f.xlsx' })
    expect(r.resolved).toBe(true)
    expect(r.kind).toBe('owner_confirmed')
    expect(r.stationId).toBe('st-abnoub')
    expect(r.rule).toContain('owner_confirmed_station_alias')
  })

  it('RESOLVE-5 NEGATIVE: that confirmation creates NO governorate-suffix rule', () => {
    // Every other suffixed name must stay unresolved and wait for a human.
    for (const name of ['ابو القمصان اسيوط', 'ابو تيج- اسيوط', 'الادبيه - السويس', 'شبرا اسيوط']) {
      const r = resolver().resolve({ rawName: name, region: 'Upper', sourceFile: 'f.xlsx' })
      expect(r.resolved, `${name} must NOT resolve`).toBe(false)
      expect(r.stationId).toBeNull()
    }
    // And the confirmed list is exactly one pair, by enumeration.
    expect(OWNER_CONFIRMED_STATION_ALIASES).toHaveLength(1)
  })

  it('RESOLVE-6 NEGATIVE: similarity NEVER auto-maps', () => {
    const r = resolver().resolve({ rawName: 'شبرا ١', region: 'East', sourceFile: 'f.xlsx' })
    expect(r.resolved).toBe(false)
    expect(r.stationId).toBeNull()
    for (const p of r.proposals) expect(p.autoAccepted).toBe(false)
  })

  it('RESOLVE-7 NEGATIVE: a high-scoring proposal still does not resolve', () => {
    const r = resolver().resolve({ rawName: 'الخمائل 2', region: 'West', sourceFile: 'f.xlsx' })
    // الخمائل 2 IS a unit name here, so it resolves by exact unit name...
    expect(r.kind).toBe('exact_canonical')
    // ...but an unknown numbered name only ever proposes.
    const r2 = resolver().resolve({ rawName: 'الخمائل 7', region: 'West', sourceFile: 'f.xlsx' })
    expect(r2.resolved).toBe(false)
    expect(r2.proposals.length).toBeGreaterThan(0)
    expect(r2.proposals[0].score).toBeGreaterThan(0.9)
    expect(r2.stationId).toBeNull()
  })

  it('RESOLVE-8 an unknown station resolves to nothing at all', () => {
    const r = resolver().resolve({ rawName: 'محطة مجهولة تماما', region: 'Alex', sourceFile: 'f.xlsx' })
    expect(r.kind).toBe('unmatched')
    expect(r.stationId).toBeNull()
  })

  it('RESOLVE-9 a REJECTED alias is never re-proposed', () => {
    const r = resolver([
      { rawName: 'شبرا ١', region: 'East', sourceFile: null, stationId: 'st-shobra', unitId: null, status: 'rejected' },
    ]).resolve({ rawName: 'شبرا ١', region: 'East', sourceFile: 'f.xlsx' })
    expect(r.kind).toBe('unmatched')
    expect(r.proposals).toHaveLength(0)
  })
})

describe('the installed-SRV mapping lifecycle', () => {
  const unresolved = { kind: 'unmatched' as const, stationId: null, unitId: null, resolved: false, rawName: 'x', rule: null, proposals: [] }
  const resolved = (id: string) => ({ kind: 'exact_canonical' as const, stationId: id, unitId: null, resolved: true, rawName: 'x', rule: 'exact_canonical_name', proposals: [] })

  it('SRV-A unknown station stages as needs_station_mapping, everything NULL', () => {
    const d = decideInstalledSrvMapping(unresolved, null, 'Stage')
    expect(d.mappingStatus).toBe('needs_station_mapping')
    expect(d.stationId).toBeNull()
    expect(d.unitId).toBeNull()
    expect(d.compressorId).toBeNull()
    expect(d.storageVesselId).toBeNull()
    expect(d.dispenserId).toBeNull()
  })

  it('SRV-B station with several units stages as needs_unit_mapping', () => {
    const d = decideInstalledSrvMapping(resolved('st-shobra'), byId.get('st-shobra')!, 'Stage')
    expect(d.mappingStatus).toBe('needs_unit_mapping')
    expect(d.stationId).toBe('st-shobra')
    expect(d.unitId).toBeNull()
  })

  it('SRV-C station with exactly one unit stages as needs_equipment_mapping', () => {
    const d = decideInstalledSrvMapping(resolved('st-abnoub'), byId.get('st-abnoub')!, 'Storage')
    expect(d.mappingStatus).toBe('needs_equipment_mapping')
    expect(d.unitId).toBe('u-abnoub-1')
    expect(d.storageVesselId).toBeNull()
  })

  it('SRV-D a station with NO known units never invents one', () => {
    const d = decideInstalledSrvMapping(resolved('st-nounits'), byId.get('st-nounits')!, 'Stage')
    expect(d.mappingStatus).toBe('needs_unit_mapping')
    expect(d.unitId).toBeNull()
  })

  it('SRV-E ambiguous station evidence holds for a human', () => {
    const d = decideInstalledSrvMapping(
      { ...unresolved, kind: 'ambiguous' }, null, 'Stage',
    )
    expect(d.mappingStatus).toBe('needs_station_mapping')
    expect(d.reason).toContain('ambiguous')
  })

  it('SRV-F NEGATIVE: Stage narrows the KIND and selects no compressor', () => {
    expect(expectedParentKindFromLocation('Stage')).toBe('compressor')
    const d = decideInstalledSrvMapping(resolved('st-abnoub'), byId.get('st-abnoub')!, 'Stage')
    expect(d.expectedParentKind).toBe('compressor')
    expect(d.compressorId).toBeNull()
  })

  it('SRV-G NEGATIVE: Storage narrows the KIND and selects no vessel', () => {
    expect(expectedParentKindFromLocation('Storage')).toBe('storage_vessel')
    const d = decideInstalledSrvMapping(resolved('st-abnoub'), byId.get('st-abnoub')!, 'Storage')
    expect(d.expectedParentKind).toBe('storage_vessel')
    expect(d.storageVesselId).toBeNull()
  })

  it('SRV-H NEGATIVE: no source value ever produces a dispenser SRV', () => {
    for (const loc of ['Stage', 'Storage', 'Dispenser', 'dispenser', 'DIS', null]) {
      const d = decideInstalledSrvMapping(resolved('st-abnoub'), byId.get('st-abnoub')!, loc)
      expect(d.dispenserId, `${loc} must not produce a dispenser parent`).toBeNull()
      expect(d.expectedParentKind).not.toBe('dispenser')
    }
  })

  it('SRV-I NEGATIVE: nothing distributes SRVs across a multi-unit station', () => {
    // Ten identical Stage rows at a 4-unit station must ALL stay unit-less.
    const results = Array.from({ length: 10 }, () =>
      decideInstalledSrvMapping(resolved('st-shobra'), byId.get('st-shobra')!, 'Stage'),
    )
    expect(new Set(results.map((r) => r.unitId))).toEqual(new Set([null]))
  })
})

describe('the Unit SRV tab rule', () => {
  it('TAB-1 shows resolved and needs_equipment_mapping when the unit is confirmed', () => {
    expect(visibleInUnitSrvTab('resolved', 'u-s1')).toBe(true)
    expect(visibleInUnitSrvTab('needs_equipment_mapping', 'u-s1')).toBe(true)
  })

  it('TAB-2 NEGATIVE: never shows unmapped or conflicting records', () => {
    expect(visibleInUnitSrvTab('needs_station_mapping', null)).toBe(false)
    expect(visibleInUnitSrvTab('needs_unit_mapping', null)).toBe(false)
    expect(visibleInUnitSrvTab('conflict', null)).toBe(false)
    // Even a conflict that somehow carries a unit id stays out.
    expect(visibleInUnitSrvTab('conflict', 'u-s1')).toBe(false)
  })
})

describe('idempotency and replay', () => {
  const p = { file: 'F.xlsx', sheet: 'S', row: 12 }
  const row = { A: 'x', B: 21586, C: null }

  it('REPLAY-1 identity is file+sheet+row, never a display name', () => {
    expect(sourceRowKey(p)).toBe('F.xlsx::S::12')
    expect(sourceRowKey({ ...p, file: 'G.xlsx' })).not.toBe(sourceRowKey(p))
  })

  it('REPLAY-2 the same row re-read hashes identically', () => {
    expect(sourceRowHash(row)).toBe(sourceRowHash({ C: null, B: 21586, A: 'x' }))
  })

  it('REPLAY-3 a number and the string of that number are distinguishable', () => {
    expect(sourceRowHash({ A: 21586 })).not.toBe(sourceRowHash({ A: '21586' }))
  })

  it('REPLAY-4 reprocessing the identical row is detected as a replay', () => {
    const prior = buildPriorIndex([{ sourceRowKey: sourceRowKey(p), sourceRowHash: sourceRowHash(row) }])
    const v = classifyReplay({ sourceRowKey: sourceRowKey(p), sourceRowHash: sourceRowHash(row) }, prior)
    expect(v.kind).toBe('replay')
  })

  it('REPLAY-5 a changed row at the same position is NOT a replay', () => {
    const prior = buildPriorIndex([{ sourceRowKey: sourceRowKey(p), sourceRowHash: sourceRowHash(row) }])
    const v = classifyReplay(
      { sourceRowKey: sourceRowKey(p), sourceRowHash: sourceRowHash({ ...row, A: 'changed' }) },
      prior,
    )
    expect(v.kind).toBe('changed')
  })

  it('REPLAY-6 an unseen row is new', () => {
    const v = classifyReplay(
      { sourceRowKey: sourceRowKey(p), sourceRowHash: sourceRowHash(row) }, new Map(),
    )
    expect(v.kind).toBe('new')
  })
})
