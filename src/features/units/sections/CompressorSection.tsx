import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { Serial, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type CompressorRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'

/**
 * Compressors on this Unit.
 *
 * CARDINALITY IS NOT ASSUMED. `compressors.unit_id` is a plain nullable foreign
 * key with no unique constraint, so the schema permits more than one compressor
 * per Unit. This renders a table, not a single record - assuming "one
 * compressor per Unit" would silently hide the second one.
 *
 * NO INSPECTION OR CALIBRATION COLUMNS. The `compressors` table carries no date
 * fields at all; its periodic data is running hours and gas sales. There is
 * therefore no due status here, and none is invented.
 */
const COLUMNS: Column<CompressorRow>[] = [
  { header: 'Serial', rowHeader: true, render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  { header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  { header: 'Model', render: (r) => <Text value={r.model} /> },
  { header: 'Job number', render: (r) => (r.job_number ? <Identifier value={r.job_number} /> : <NullValue />) },
  {
    header: 'Running hours',
    align: 'right',
    numeric: true,
    render: (r) =>
      r.total_running_hours === null ? <NullValue /> : <span>{r.total_running_hours.toLocaleString()}</span>,
  },
  {
    header: 'Hours / day',
    align: 'right',
    numeric: true,
    render: (r) =>
      r.average_hours_per_day === null ? <NullValue /> : <span>{r.average_hours_per_day.toLocaleString()}</span>,
  },
]

export function CompressorSection() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnitEquipment<CompressorRow>('compressor', unitId)

  return (
    <EquipmentSection
      record={(r) => ({ table: 'compressors', id: r.id })}
      title="Compressors"
      state={state}
      reload={reload}
      rowKey={(r) => r.id}
      columns={COLUMNS}
      emptyTitle="No Compressor is recorded for this Unit"
      emptyDescription="No compressor record is mapped to this Unit. That is a statement about the records, not a fault: a Unit whose compressor has not been mapped yet is a complete record with unknown equipment."
      errorTitle="Could not load Compressors"
      detail={(r) => (
        <>
          <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
          <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
          <Fact label="Part number">{r.part_number ? <Identifier value={r.part_number} /> : <NullValue />}</Fact>
          <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
          <Fact label="Manufacturer (source)"><Text value={r.manufacturer_raw} /></Fact>
          <Fact label="Model"><Text value={r.model} /></Fact>
          <Fact label="Model (source)"><Text value={r.model_raw} /></Fact>
          <Fact label="Job number">{r.job_number ? <Identifier value={r.job_number} /> : <NullValue />}</Fact>
          <Fact label="Total running hours">
            {r.total_running_hours === null ? <NullValue /> : r.total_running_hours.toLocaleString()}
          </Fact>
          <Fact label="Average hours / day">
            {r.average_hours_per_day === null ? <NullValue /> : r.average_hours_per_day.toLocaleString()}
          </Fact>
          {/* No unit is attached to gas sales: the schema stores a number and
            * the raw source text, and nothing proves the measure. Showing the
            * raw value beside it is the honest answer. */}
          <Fact label="Average gas sales / day">
            {r.average_gas_sales_per_day === null ? <NullValue /> : r.average_gas_sales_per_day.toLocaleString()}
          </Fact>
          <Fact label="Gas sales (source)"><Text value={r.average_gas_sales_raw} /></Fact>
          <Fact label="Notes"><Text value={r.notes} /></Fact>
        </>
      )}
      footnote="The compressor record carries running hours and gas sales, not inspection or calibration dates, so no due status is shown."
    />
  )
}
