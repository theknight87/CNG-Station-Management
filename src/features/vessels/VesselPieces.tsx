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
