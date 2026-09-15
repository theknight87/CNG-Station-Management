import type { MappingStatus } from '../types'
import type { CanonicalStation, StationResolution } from './stations'

/**
 * The installed-SRV mapping lifecycle (CLAUDE.md section 4, prompt section 12).
 *
 * The installed-SRV source has NO Unit column and NO equipment identifier, so
 * no installed SRV can arrive `resolved`. `Location` (`Stage` / `Storage`) is a
 * PARENT-KIND HINT and nothing more: it narrows what an engineer is offered, it
 * never names a specific Compressor, Vessel or Dispenser.
 *
 * Forbidden here, permanently: assigning a Stage SRV to a compressor, a Storage
 * SRV to a vessel, distributing SRVs across units by count/order/round-robin,
 * or inferring a dispenser SRV. No such code path exists in this file.
 */

export type ExpectedParentKind = 'compressor' | 'storage_vessel' | 'dispenser' | null

/**
 * Reads the source `Location` column into a hint. Only two values are
 * deterministic; anything else yields null rather than a guess.
 *
 * NOTE what this returns: a KIND, never an id. There is no variant of this
 * function that returns an equipment record.
 */
export function expectedParentKindFromLocation(location: string | null): ExpectedParentKind {
  if (location === null) return null
  const key = location.trim().toLowerCase()
  if (key === 'stage') return 'compressor'
  if (key === 'storage') return 'storage_vessel'
  // No dispenser value exists in any current source; none is invented.
  return null
}

export interface SrvMappingDecision {
  mappingStatus: MappingStatus
  stationId: string | null
  unitId: string | null
  /** Always all-null at import. Equipment parentage is a human decision (D3). */
  compressorId: null
  storageVesselId: null
  dispenserId: null
  expectedParentKind: ExpectedParentKind
  reason: string
}

/**
 * Decides the lifecycle state for ONE installed SRV row.
 *
 * A station whose structure proves exactly one Unit lets `unit_id` be set --
 * that is not a guess, it is the only Unit the Station has. A station with
 * several Units leaves `unit_id` NULL: choosing among them would be fabrication.
 */
export function decideInstalledSrvMapping(
  resolution: StationResolution,
  station: CanonicalStation | null,
  location: string | null,
): SrvMappingDecision {
  const expectedParentKind = expectedParentKindFromLocation(location)
  const common = {
    compressorId: null as null,
    storageVesselId: null as null,
    dispenserId: null as null,
    expectedParentKind,
  }

  // A. Station not confirmed -> the SRV is STILL imported, with everything NULL.
  //    An unresolved station is never a reason to drop an installed SRV.
  if (!resolution.resolved || station === null) {
    return {
      ...common,
      mappingStatus: 'needs_station_mapping',
      stationId: null,
      unitId: null,
      reason:
        resolution.kind === 'ambiguous'
          ? 'station evidence is ambiguous; held for human confirmation'
          : 'station name not resolved by any confirmed alias or canonical name',
    }
  }

  // B. Station confirmed, but the Station has no known Unit structure or has
  //    several Units -> Unit stays NULL (decision D7: no default Unit, ever).
  if (station.unitIds.length !== 1) {
    return {
      ...common,
      mappingStatus: 'needs_unit_mapping',
      stationId: station.id,
      unitId: null,
      reason:
        station.unitIds.length === 0
          ? 'station has no known unit structure'
          : `station has ${station.unitIds.length} units; the source names none`,
    }
  }

  // C. Station + exactly one Unit -> the Unit is proven, the equipment is not.
  return {
    ...common,
    mappingStatus: 'needs_equipment_mapping',
    stationId: station.id,
    unitId: station.unitIds[0],
    reason:
      'station has exactly one unit, so the unit is proven; the parent equipment is not named by the source',
  }
}

/**
 * The product rule for the Unit SRV tab (prompt section 13). Kept here, beside
 * the lifecycle, so the import and the UI cannot drift apart.
 */
export function visibleInUnitSrvTab(status: MappingStatus, unitId: string | null): boolean {
  if (unitId === null) return false
  return status === 'resolved' || status === 'needs_equipment_mapping'
}
