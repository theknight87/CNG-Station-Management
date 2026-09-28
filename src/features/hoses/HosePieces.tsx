import { StatusBadge } from '@/components/data/StatusBadge'
import { NullValue } from '@/components/data/NullValue'
import { Identifier } from '@/components/data/TechnicalText'
import type { HoseMappingStatus, HoseRegistryRow } from '@/features/hoses/useHoseManagement'

/**
 * Hose-specific presentation. The technical VALUE renderers — dates, pressures,
 * due status — come from the shared `assetDisplay` module, so one field means
 * one thing across the whole product.
 */

/**
 * Mapping state for a hose.
 *
 * `asset_mapping_status`, NOT the SRV lifecycle. There is no
 * `needs_equipment_mapping`: a hose's optional parent is a Dispenser, reached
 * through the Unit. `needs_station_mapping` is unreachable in practice
 * (`station_id` is NOT NULL) but is mapped so the UI would state the truth
 * rather than render a blank if that ever changed.
 */
const MAPPING: Record<
  HoseMappingStatus,
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

export function HoseMappingBadge({ status }: { status: HoseMappingStatus }) {
  const spec = MAPPING[status] ?? MAPPING.conflict
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/**
 * A hose serial, with its identity condition.
 *
 * IDENTITY IS THIS ASSET'S POINT, so the two failure modes are shown distinctly
 * and never merged into one "bad serial" flag:
 *
 *   missing    — the source recorded nothing. It stays NULL. No serial is
 *                generated from a row number, a station, a unit, or anything
 *                else, however much operational policy wants one.
 *   duplicate  — another hose the caller may see carries the same value. It is
 *                REPORTED, never merged, never silently suffixed, never
 *                "repaired". Six identical values may be six real devices
 *                (principle #16); the database holds no UNIQUE constraint and
 *                none was added.
 *
 * `not_yet_assigned` is a third, different thing: the source states explicitly
 * that no serial has been issued yet (principle #20). That is a fact, not a gap.
 */
export function HoseSerial({ row }: { row: HoseRegistryRow }) {
  if (row.serial_number) {
    return (
      <span className="inline-flex items-center gap-1.5">
        <Identifier value={row.serial_number} />
        {row.serial_duplicate ? (
          <span className="whitespace-nowrap rounded border border-status-unmapped/40 px-1 py-px text-xs font-medium text-status-unmapped">
            duplicate
            <span className="sr-only"> — another hose you can see carries this same serial; both records are kept</span>
          </span>
        ) : null}
      </span>
    )
  }
  if (row.serial_status === 'not_yet_assigned') {
    return (
      <span className="text-sm text-muted-foreground">
        not yet assigned
        <span className="sr-only"> — the source states no serial has been issued for this hose yet</span>
      </span>
    )
  }
  return <NullValue />
}

/** Station and Region. Only levels the record actually proves. */
export function HoseStationCell({ row }: { row: HoseRegistryRow }) {
  return (
    <span className="whitespace-nowrap">
      {row.station_name ?? <NullValue />}
      {row.region_name ? <span className="ml-1.5 text-xs text-muted-foreground">{row.region_name}</span> : null}
    </span>
  )
}

/**
 * The Unit, and the Dispenser beneath it where one is confirmed.
 *
 * NEVER a guess. A hose recorded at Station level shows "Not confirmed" for the
 * Unit; it is not attributed to the station's only unit, to an adjacent hose's
 * unit, or to a unit inferred from its description or serial. A Dispenser can
 * only appear once the Unit is known — the database enforces that with
 * `hoses_dispenser_needs_unit_ck`.
 */
export function HoseUnitCell({ row }: { row: HoseRegistryRow }) {
  if (!row.unit_name) return <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
  return (
    <span className="whitespace-nowrap">
      {row.unit_name}
      {row.dispenser_name ? (
        <span className="ml-1.5 text-xs text-muted-foreground">{row.dispenser_name}</span>
      ) : null}
    </span>
  )
}

/**
 * The free-text description, kept as free text.
 *
 * It is NOT parsed into manufacturer, model, bay or dispenser. A value such as
 * `خرطوم غاز C` hints at a bay letter, but reading that as a dispenser
 * identity is not deterministic and would fabricate a physical relationship.
 */
export function HoseDescription({ value }: { value: string | null }) {
  if (!value) return <NullValue />
  return (
    <span className="block max-w-[22rem] truncate" dir="auto" title={value}>
      {value}
    </span>
  )
}
