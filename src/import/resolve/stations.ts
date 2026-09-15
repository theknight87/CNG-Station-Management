import type { CanonicalRegion, MatchProposal, Provenance } from '../types'
import { normalizeName, similarity, splitNumberedName } from '../normalize/text'

/**
 * Station and Unit resolution.
 *
 * THE RULE THAT GOVERNS THIS FILE: a Station is resolved by an EXPLICIT,
 * STORED mapping — a confirmed alias, an exact canonical name, or an
 * owner-confirmed equivalence. Nothing else resolves. Similarity produces a
 * PROPOSAL that a human confirms, and a proposal attaches no data and creates
 * no entity.
 *
 * There is deliberately no suffix rule, no governorate-stripping rule, no
 * number-stripping rule, and no confidence threshold that promotes a proposal
 * to a resolution.
 */

export interface CanonicalStation {
  id: string
  name: string
  region: CanonicalRegion
  unitIds: string[]
}

export interface CanonicalUnit {
  id: string
  name: string
  stationId: string
}

/** A stored alias row: raw source name -> canonical entity, with its status. */
export interface StoredAlias {
  rawName: string
  region: CanonicalRegion | null
  sourceFile: string | null
  stationId: string | null
  unitId: string | null
  status: 'proposed' | 'confirmed' | 'rejected'
}

/**
 * The owner-confirmed station equivalences. An EXACT-VALUE list mirroring
 * `owner_confirmed_station_aliases`, currently one pair.
 *
 * This authorizes exactly `ابنوب اسيوط` = `ابنوب` and NOTHING else. It is not a
 * rule about governorate suffixes: `ابو تيج- اسيوط` and `الادبيه - السويس` are
 * unaffected and still require human confirmation.
 */
export const OWNER_CONFIRMED_STATION_ALIASES: ReadonlyArray<{ from: string; to: string }> = [
  { from: 'ابنوب اسيوط', to: 'ابنوب' },
]

export type ResolutionKind =
  | 'exact_canonical'
  | 'confirmed_alias'
  | 'owner_confirmed'
  | 'proposal'
  | 'ambiguous'
  | 'unmatched'

export interface StationResolution {
  kind: ResolutionKind
  stationId: string | null
  unitId: string | null
  /** True only for exact_canonical, confirmed_alias and owner_confirmed. */
  resolved: boolean
  rawName: string
  rule: string | null
  proposals: MatchProposal[]
}

export interface ResolverInput {
  rawName: string
  region: CanonicalRegion | null
  sourceFile: string
  provenance?: Provenance
}

/** Similarity at or above this is worth SHOWING a human. It never resolves. */
const PROPOSAL_FLOOR = 0.6

export class StationResolver {
  private readonly stations: CanonicalStation[]
  private readonly units: CanonicalUnit[]
  private readonly aliases: StoredAlias[]

  constructor(stations: CanonicalStation[], units: CanonicalUnit[], aliases: StoredAlias[]) {
    this.stations = stations
    this.units = units
    this.aliases = aliases
  }

  resolve(input: ResolverInput): StationResolution {
    const raw = input.rawName?.trim() ?? ''
    const base = {
      rawName: raw,
      stationId: null,
      unitId: null,
      resolved: false,
      rule: null,
      proposals: [] as MatchProposal[],
    }

    if (raw.length === 0) return { ...base, kind: 'unmatched' }

    // --- 1. Owner-confirmed equivalence. EXACT value match only. -----------
    const owner = OWNER_CONFIRMED_STATION_ALIASES.find((a) => a.from === raw)
    if (owner) {
      const target = this.stations.find(
        (s) => s.name === owner.to && (input.region === null || s.region === input.region),
      )
      if (target) {
        return {
          ...base,
          kind: 'owner_confirmed',
          stationId: target.id,
          resolved: true,
          rule: `owner_confirmed_station_alias:${owner.from}=${owner.to}`,
        }
      }
      // The ruling exists but its target does not: a proposal, never a guess.
    }

    // --- 2. A CONFIRMED stored alias. --------------------------------------
    const confirmed = this.aliases.find(
      (a) =>
        a.status === 'confirmed' &&
        a.rawName === raw &&
        (a.region === null || input.region === null || a.region === input.region) &&
        (a.sourceFile === null || a.sourceFile === input.sourceFile),
    )
    if (confirmed) {
      return {
        ...base,
        kind: 'confirmed_alias',
        stationId: confirmed.stationId,
        unitId: confirmed.unitId,
        resolved: true,
        rule: 'confirmed_alias',
      }
    }

    // A rejected alias is a decision too: never re-propose what a human refused.
    const rejected = this.aliases.some((a) => a.status === 'rejected' && a.rawName === raw)

    // --- 3. Exact canonical name, within the region when one is known. -----
    const exactStations = this.stations.filter(
      (s) => s.name === raw && (input.region === null || s.region === input.region),
    )
    if (exactStations.length === 1) {
      return {
        ...base,
        kind: 'exact_canonical',
        stationId: exactStations[0].id,
        resolved: true,
        rule: 'exact_canonical_name',
      }
    }
    if (exactStations.length > 1) {
      return { ...base, kind: 'ambiguous', proposals: this.proposalsFor(raw, input.region) }
    }

    const exactUnits = this.units.filter((u) => u.name === raw)
    if (exactUnits.length === 1) {
      const station = this.stations.find((s) => s.id === exactUnits[0].stationId)
      if (station && (input.region === null || station.region === input.region)) {
        return {
          ...base,
          kind: 'exact_canonical',
          stationId: station.id,
          unitId: exactUnits[0].id,
          resolved: true,
          rule: 'exact_canonical_unit_name',
        }
      }
    }
    if (exactUnits.length > 1) {
      return { ...base, kind: 'ambiguous', proposals: this.proposalsFor(raw, input.region) }
    }

    // --- 4. Nothing resolved. Everything below is ADVISORY. ----------------
    if (rejected) return { ...base, kind: 'unmatched' }

    const proposals = this.proposalsFor(raw, input.region)
    if (proposals.length === 0) return { ...base, kind: 'unmatched' }
    if (proposals.length > 1 && proposals[0].score === proposals[1].score) {
      return { ...base, kind: 'ambiguous', proposals }
    }
    // A proposal. stationId stays NULL: it attaches nothing and creates nothing.
    return { ...base, kind: 'proposal', proposals }
  }

  /**
   * Advisory candidates, scored and labelled with their method. Includes the
   * D2 `<base> <n>` reading — as a PROPOSAL, exactly like every other
   * suggestion. `autoAccepted` is typed `false` so no code path can flip it.
   */
  private proposalsFor(raw: string, region: CanonicalRegion | null): MatchProposal[] {
    const out: MatchProposal[] = []
    const inRegion = (r: CanonicalRegion) => region === null || r === region

    const numbered = splitNumberedName(raw)
    if (numbered) {
      for (const s of this.stations) {
        if (!inRegion(s.region)) continue
        if (normalizeName(s.name) === normalizeName(numbered.base)) {
          out.push({
            rawName: raw,
            candidateId: s.id,
            candidateName: s.name,
            score: 0.99,
            method: `d2_numbered_unit_candidate:unit_${numbered.index}_of_${s.name}`,
            autoAccepted: false,
          })
        }
      }
    }

    for (const s of this.stations) {
      if (!inRegion(s.region)) continue
      const score = similarity(raw, s.name)
      if (score >= PROPOSAL_FLOOR && score < 1) {
        out.push({
          rawName: raw,
          candidateId: s.id,
          candidateName: s.name,
          score: Number(score.toFixed(4)),
          method: 'dice_bigram_similarity',
          autoAccepted: false,
        })
      }
    }

    return out.sort((a, b) => b.score - a.score).slice(0, 5)
  }
}
