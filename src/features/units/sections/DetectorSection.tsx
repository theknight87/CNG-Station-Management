import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { DueBadge, PrecisionDate, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type DetectorRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'

/**
 * Gas Detectors on this Unit.
 *
 * THERE IS NO FREE-TEXT "LOCATION" COLUMN. What the schema records is
 * `area_type` - an enum of `open` / `closed` - plus the raw source text it was
 * derived from. A detector's physical position is not recorded anywhere, so no
 * Location column is drawn and none is guessed.
 *
 * `detector_presence` distinguishes a detector that is recorded as NOT INSTALLED
 * from one whose presence is simply unknown. Those are different facts and are
 * worded differently.
 */
const COLUMNS: Column<DetectorRow>[] = [
  { header: 'Serial', rowHeader: true, render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  { header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  { header: 'Model', render: (r) => <Text value={r.model} /> },
  { header: 'Area', render: (r) => <Text value={r.area_type} /> },
  {
    header: 'Last calibration',
    render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />,
  },
  {
    header: 'Next calibration',
    render: (r) => (
      <>
        <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
        {!r.next_calibration_display ? <SourceStatus value={r.source_status_raw} /> : null}
      </>
    ),
  },
  {
    header: 'Days left',
    align: 'right',
    numeric: true,
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
  { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
]

export function DetectorSection() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnitEquipment<DetectorRow>('gas-detectors', unitId)

  return (
    <EquipmentSection
      record={(r) => (r.detector_id ? { table: 'gas_detectors', id: r.detector_id } : null)}
      title="Gas Detectors"
      state={state}
      reload={reload}
      rowKey={(r) => r.detector_id}
      columns={COLUMNS}
      emptyTitle="No Gas Detectors are recorded for this Unit"
      emptyDescription="No gas detector record is mapped to this Unit."
      errorTitle="Could not load Gas Detectors"
      detail={(r) => (
        <>
          <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
          <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
          <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
          <Fact label="Model"><Text value={r.model} /></Fact>
          <Fact label="Area type"><Text value={r.area_type} /></Fact>
          <Fact label="Area (source)"><Text value={r.area_type_raw} /></Fact>
          <Fact label="Presence"><Text value={r.detector_presence} /></Fact>
          <Fact label="Last calibration">
            <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />
          </Fact>
          <Fact label="Next calibration">
            <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
          </Fact>
          <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
          <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
          <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
          <Fact label="Notes"><Text value={r.notes} /></Fact>
        </>
      )}
      footnote="The schema records an area type (open or closed), not a physical position. No detector location is inferred."
    />
  )
}
