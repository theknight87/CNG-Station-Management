import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { DueBadge, PrecisionDate, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type VesselRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'

/**
 * Storage Vessels and Recovery Tanks.
 *
 * ONE COMPONENT, TWO TABS. Both read `v_vessel_management`, which unions the two
 * tables behind an `asset_type` discriminator and computes `due_status` with the
 * same `cng_due_status()` the Dashboard uses. Giving them one renderer is what
 * stops "overdue" drifting apart between two nearly identical screens.
 *
 * WHAT THE SCHEMA DOES NOT CARRY. Neither table has capacity, design pressure,
 * working pressure, manufacture year, or a certificate reference. Those columns
 * do not exist, so they are not displayed and not invented - a plausible-looking
 * empty "Capacity" column would imply the data is merely missing rather than
 * never recorded (principle #1).
 */
const columns = (kind: 'storage_vessel' | 'recovery_tank'): Column<VesselRow>[] => [
  { header: 'Serial', rowHeader: true, render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  { header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  { header: 'Model', render: (r) => <Text value={r.model} /> },
  {
    header: 'Last inspection',
    render: (r) => <PrecisionDate display={r.last_inspection_display} precision={r.last_inspection_precision} />,
  },
  {
    header: 'Next inspection',
    render: (r) => (
      <>
        <PrecisionDate display={r.next_inspection_display} precision={r.next_inspection_precision} />
        {/* A source status such as "منتهي" is shown beside the missing date, */}
        {/* never converted into one (principle #21). */}
        {!r.next_inspection_display ? <SourceStatus value={r.source_status_raw} /> : null}
      </>
    ),
  },
  {
    header: 'Days left',
    align: 'right',
    numeric: true,
    // Only an exact date produces a countdown. A year-only date has no day.
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
  { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  ...(kind === 'storage_vessel'
    ? []
    : ([] as Column<VesselRow>[])),
]

export function VesselSection({ kind }: { kind: 'storage_vessel' | 'recovery_tank' }) {
  const { unitId } = useParams<{ unitId: string }>()
  const tab = kind === 'storage_vessel' ? 'storage' : 'recovery-tank'
  const { state, reload } = useUnitEquipment<VesselRow>(tab, unitId)
  const label = kind === 'storage_vessel' ? 'Storage Vessels' : 'Recovery Tanks'

  return (
    <EquipmentSection
      title={label}
      state={state}
      reload={reload}
      rowKey={(r) => r.id}
      columns={columns(kind)}
      emptyTitle={`No ${label} are recorded for this Unit`}
      emptyDescription={`No ${label.toLowerCase()} record is mapped to this Unit. Absence of a record is not missing data — nothing in the schema says this Unit must have one.`}
      errorTitle={`Could not load ${label}`}
      detail={(r) => (
        <>
          <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
          <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
          <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
          <Fact label="Model"><Text value={r.model} /></Fact>
          <Fact label="Type (source)"><Text value={r.compressor_type_raw} /></Fact>
          <Fact label="Last inspection">
            <PrecisionDate display={r.last_inspection_display} precision={r.last_inspection_precision} />
          </Fact>
          <Fact label="Next inspection">
            <PrecisionDate display={r.next_inspection_display} precision={r.next_inspection_precision} />
          </Fact>
          <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
          <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
          <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
          <Fact label="Mapping">
            {r.needs_mapping ? <StatusBadge kind="unmapped" label={r.mapping_status} /> : <span>Resolved</span>}
          </Fact>
          <Fact label="Notes"><Text value={r.notes} /></Fact>
        </>
      )}
      footnote="Capacity, design pressure and certificate reference are not columns this schema carries, so they are not shown here."
    />
  )
}
