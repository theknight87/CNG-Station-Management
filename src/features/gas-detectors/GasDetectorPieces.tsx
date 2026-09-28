import { StatusBadge } from '@/components/data/StatusBadge'
import { NullValue } from '@/components/data/NullValue'
import type {
  DetectorAreaType, DetectorMappingStatus, DetectorPresence, DetectorRegistryRow,
} from '@/features/gas-detectors/useGasDetectorManagement'

/**
 * Gas-detector-specific presentation. The technical VALUE renderers — dates,
 * serials, due status — come from the shared `assetDisplay` module, so one
 * field means one thing across the whole product.
 */

/**
 * Mapping state for a gas detector.
 *
 * These are `asset_mapping_status`, NOT the SRV lifecycle: there is no
 * `needs_equipment_mapping`, because a detector hangs off a Unit and has no
 * equipment parent to resolve. `needs_station_mapping` is unreachable in
 * practice (`station_id` is NOT NULL) but is mapped so the UI would state the
 * truth rather than render a blank if that ever changed.
 *
 * Each carries its own screen-reader description: these badges borrow a kind
 * for colour and icon but describe MAPPING, not compliance.
 */
const MAPPING: Record<
  DetectorMappingStatus,
  { kind: 'ok' | 'unmapped' | 'conflict'; label: string; description: string }
> = {
  resolved: {
    kind: 'ok', label: 'Resolved',
    description: 'Station and Unit are both confirmed',
  },
  needs_unit_mapping: {
    kind: 'unmapped', label: 'Needs unit mapping',
    description: 'The Station is confirmed; the Unit is not, and none is guessed',
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

export function DetectorMappingBadge({ status }: { status: DetectorMappingStatus | null }) {
  // A presence-evidence row is not an asset, so it has no mapping lifecycle.
  // That is genuinely "not applicable", not a missing value.
  if (!status) return <NullValue />
  const spec = MAPPING[status] ?? MAPPING.conflict
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/**
 * Area classification — `open` or `closed`.
 *
 * DELIBERATELY NOT A STATUS. Open and Closed are area classifications, not
 * compliance states, so both render in exactly the SAME neutral treatment:
 * identical border, identical background, identical weight. Only the word
 * differs. Colouring "Closed" as a warning would invent a judgement the data
 * does not make — an enclosed area is a design fact, not a fault.
 *
 * It is also NOT a location. `area_type` is stored on `gas_detector_presence`
 * and describes the AREA, shared by every detector in that unit; this schema
 * records no physical position for a detector, and none is inferred.
 */
const AREA_LABEL: Record<DetectorAreaType, string> = { open: 'Open', closed: 'Closed' }

export function AreaType({ value }: { value: DetectorAreaType | null }) {
  if (!value) return <NullValue />
  return (
    <span className="inline-flex items-center whitespace-nowrap rounded border border-border bg-muted/40 px-1.5 py-0.5 text-xs font-medium text-foreground">
      {AREA_LABEL[value] ?? value}
      <span className="sr-only"> area classification</span>
    </span>
  )
}

/**
 * Presence.
 *
 * `not_installed` is EVIDENCE that 138 source rows state explicitly, not a
 * missing detector and not a fabricated one. `unknown` is different again: the
 * source said nothing either way. The two are worded differently on purpose.
 */
const PRESENCE: Record<DetectorPresence, { kind: 'ok' | 'unmapped' | 'info'; label: string; description: string }> = {
  installed: {
    kind: 'ok', label: 'Installed',
    description: 'A detector asset is recorded here',
  },
  not_installed: {
    kind: 'unmapped', label: 'Not installed',
    description: 'The source states explicitly that no detector exists at this location',
  },
  unknown: {
    kind: 'info', label: 'Presence unknown',
    description: 'The source does not say whether a detector exists here',
  },
}

export function PresenceBadge({ value }: { value: DetectorPresence }) {
  const spec = PRESENCE[value] ?? PRESENCE.unknown
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/** Station and Region. Only levels the record actually proves. */
export function DetectorStationCell({ row }: { row: DetectorRegistryRow }) {
  return (
    <span className="whitespace-nowrap">
      {row.station_name ?? <NullValue />}
      {row.region_name ? <span className="ml-1.5 text-xs text-muted-foreground">{row.region_name}</span> : null}
    </span>
  )
}

/**
 * The Unit, or an explicit statement that it is unresolved.
 *
 * NEVER a guess. A detector whose `unit_id` is NULL shows "Not confirmed"; it
 * is not attributed to the station's only unit, nor to the unit a similar
 * detector sits on.
 */
export function DetectorUnitCell({ row }: { row: DetectorRegistryRow }) {
  if (row.unit_name) return <span className="whitespace-nowrap">{row.unit_name}</span>
  return <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
}
