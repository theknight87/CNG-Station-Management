import { StatusBadge } from '@/components/data/StatusBadge'
import { NullValue } from '@/components/data/NullValue'
import type { VesselMappingStatus, VesselRegistryRow } from '@/features/vessels/useVesselManagement'

/**
 * Vessel-specific presentation. The technical VALUE renderers (dates,
 * pressures, serials, due status) come from the shared `assetDisplay` module,
 * so one field means one thing across the whole product.
 */

/**
 * Mapping state for a vessel.
 *
 * These are NOT the SRV states. `asset_mapping_status` has no
 * `needs_equipment_mapping`, because a vessel IS equipment — it has no
 * equipment parent to resolve. And `needs_station_mapping` is unreachable in
 * practice: `station_id` is NOT NULL on both tables. It is mapped here anyway
 * so that if the schema ever changes the UI states the truth instead of
 * rendering a blank badge.
 *
 * Each carries its own screen-reader description: these badges borrow a kind
 * for colour and icon but describe MAPPING, not compliance.
 */
const MAPPING: Record<VesselMappingStatus, { kind: 'ok' | 'unmapped' | 'conflict'; label: string; description: string }> = {
  resolved: {
    kind: 'ok', label: 'Resolved',
    description: 'Station and Unit are both confirmed',
  },
  needs_unit_mapping: {
    kind: 'unmapped', label: 'Needs unit mapping',
    description: 'The Station is confirmed; the Unit is not',
  },
  needs_station_mapping: {
    kind: 'unmapped', label: 'Needs station mapping',
    description: 'The Station is not confirmed, so no hierarchy is shown',
  },
  conflict: {
    kind: 'conflict', label: 'Conflict',
    description: 'Source evidence disagrees and a human must resolve it',
  },
}

export function VesselMappingBadge({ status }: { status: VesselMappingStatus }) {
  const spec = MAPPING[status] ?? MAPPING.conflict
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/** Station and Region, showing only levels the record actually proves. */
export function VesselStationCell({ row }: { row: VesselRegistryRow }) {
  if (row.mapping_status === 'needs_station_mapping') {
    return <span className="whitespace-nowrap text-muted-foreground">Station not confirmed</span>
  }
  return (
    <span className="whitespace-nowrap">
      {row.station_name ?? <NullValue />}
      {row.region_name ? <span className="ml-1.5 text-xs text-muted-foreground">{row.region_name}</span> : null}
    </span>
  )
}

/** The Unit, or an explicit statement that it is unresolved — never a guess. */
export function VesselUnitCell({ row }: { row: VesselRegistryRow }) {
  if (row.unit_name) return <span className="whitespace-nowrap">{row.unit_name}</span>
  return <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
}

/**
 * DUPLICATE SERIAL CANDIDATE — a review signal, never a verdict.
 *
 * Data principle 16: repeated values are not duplicates without supporting
 * evidence. Six identical relief valves on one station may be six real
 * devices, and two vessels recording the same serial may be two real vessels
 * whose serials were transcribed from the same source cell. This badge
 * therefore says CANDIDATE and nothing stronger. It never says "duplicate
 * asset", "invalid", "error" or "delete" — none of those is proven, and the
 * product offers no merge or delete for it.
 *
 * It borrows the `conflict` kind for its colour and icon because that is the
 * existing vocabulary for "held for human resolution", and overrides the
 * description, which is the documented contract for a badge that borrows a
 * kind but means something else.
 */
export function VesselDuplicateSerialBadge({ row }: { row: VesselRegistryRow }) {
  if (!row.serial_duplicate) return null
  const n = row.serial_duplicate_count
  return (
    <StatusBadge
      kind="conflict"
      label="Duplicate serial candidate"
      description={
        n && n > 1
          ? `${n} independent records visible to you record this same serial; each is kept as its own record and a human must review whether they are the same device`
          : 'another independent record visible to you records this same serial; each is kept as its own record and a human must review whether they are the same device'
      }
    />
  )
}
