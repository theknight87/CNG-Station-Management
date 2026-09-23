import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { DueBadge, PrecisionDate, Pressure, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type HoseRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'

/**
 * Hoses on this Unit.
 *
 * ONLY UNIT-MAPPED HOSES. The query filters `unit_id`, so a hose recorded at
 * Station level with no confirmed Unit does not appear here and is not forced
 * into a Unit it has not been proven to belong to.
 *
 * SERIALS ARE NEVER SYNTHESIZED. Each hose's own serial is its identifier; where
 * the source recorded none the cell reads "not recorded", or "not yet assigned"
 * where the source states that explicitly (principle #20).
 *
 * PRESSURES CARRY THEIR STORED UNIT. `working_pressure_unit` and
 * `test_pressure_unit` are real enum columns (BAR or PSI). Nothing is converted,
 * and where no unit was proven the number is shown without one rather than
 * dressed in a guess.
 *
 * The schema records a free-text `description`, not manufacturer and model
 * columns - so neither is displayed.
 */
const COLUMNS: Column<HoseRow>[] = [
  { header: 'Serial', rowHeader: true, render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  { header: 'Description', render: (r) => <Text value={r.description} /> },
  { header: 'Dispenser', render: (r) => <Text value={r.dispenser_name} /> },
  {
    header: 'Working pressure',
    align: 'right',
    render: (r) => (
      <Pressure value={r.working_pressure_value} unit={r.working_pressure_unit} raw={r.working_pressure_raw} />
    ),
  },
  {
    header: 'Test pressure',
    align: 'right',
    render: (r) => <Pressure value={r.test_pressure_value} unit={r.test_pressure_unit} raw={r.test_pressure_raw} />,
  },
  {
    header: 'Last test',
    render: (r) => <PrecisionDate display={r.last_test_display} precision={r.last_test_precision} />,
  },
  {
    header: 'Next test',
    render: (r) => (
      <>
        <PrecisionDate display={r.next_test_display} precision={r.next_test_precision} />
        {!r.next_test_display ? <SourceStatus value={r.source_status_raw} /> : null}
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

export function HoseSection() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnitEquipment<HoseRow>('hoses', unitId)

  return (
    <EquipmentSection
      record={(r) => ({ table: 'hoses', id: r.id })}
      title="Hoses"
      state={state}
      reload={reload}
      rowKey={(r) => r.id}
      columns={COLUMNS}
      emptyTitle="No Hoses are recorded for this Unit"
      emptyDescription="No hose record is mapped to this Unit. Hoses recorded at Station level without a confirmed Unit are not shown here, and are never forced into a Unit."
      errorTitle="Could not load Hoses"
      detail={(r) => (
        <>
          <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
          <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
          <Fact label="Description"><Text value={r.description} /></Fact>
          <Fact label="Dispenser"><Text value={r.dispenser_name} /></Fact>
          <Fact label="Working pressure">
            <Pressure value={r.working_pressure_value} unit={r.working_pressure_unit} raw={r.working_pressure_raw} />
          </Fact>
          <Fact label="Working pressure (source)"><Text value={r.working_pressure_raw} /></Fact>
          <Fact label="Test pressure">
            <Pressure value={r.test_pressure_value} unit={r.test_pressure_unit} raw={r.test_pressure_raw} />
          </Fact>
          <Fact label="Test pressure (source)"><Text value={r.test_pressure_raw} /></Fact>
          <Fact label="Last test"><PrecisionDate display={r.last_test_display} precision={r.last_test_precision} /></Fact>
          <Fact label="Next test"><PrecisionDate display={r.next_test_display} precision={r.next_test_precision} /></Fact>
          <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
          <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
          <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
          <Fact label="Notes"><Text value={r.notes} /></Fact>
        </>
      )}
      footnote="Pressures are shown in the unit the source proved. Nothing is converted, and no unit is inferred from magnitude."
    />
  )
}
