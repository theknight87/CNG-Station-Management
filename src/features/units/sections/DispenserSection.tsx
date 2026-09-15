import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { Serial, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type DispenserRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'

/**
 * Dispensers on this Unit.
 *
 * A DISPENSER IS NEVER INFERRED FROM AN SRV. Source analysis proved no dispenser
 * SRV in any current workbook, so an SRV never creates, implies or confirms a
 * dispenser here - and a dispenser may perfectly well exist with no SRV mapped
 * to it (CLAUDE.md section 4).
 *
 * `number_of_hoses` is what the SOURCE reported. It is never reconciled against
 * the hoses actually recorded on the Unit: a workbook saying "4 hoses" is
 * evidence, not four hose records.
 */
const COLUMNS: Column<DispenserRow>[] = [
  { header: 'Dispenser', rowHeader: true, render: (r) => <Text value={r.dispenser_name} /> },
  { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  { header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  { header: 'Model', render: (r) => <Text value={r.model} /> },
  {
    header: 'Hoses (source)',
    align: 'right',
    numeric: true,
    render: (r) => (r.number_of_hoses === null ? <NullValue /> : <span>{r.number_of_hoses}</span>),
  },
]

export function DispenserSection() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnitEquipment<DispenserRow>('dispensers', unitId)

  return (
    <EquipmentSection
      title="Dispensers"
      state={state}
      reload={reload}
      rowKey={(r) => r.id}
      columns={COLUMNS}
      emptyTitle="No Dispensers are recorded for this Unit"
      emptyDescription="No dispenser record is mapped to this Unit. A dispenser is never inferred from a relief valve, and no source workbook proves one."
      errorTitle="Could not load Dispensers"
      detail={(r) => (
        <>
          <Fact label="Dispenser"><Text value={r.dispenser_name} /></Fact>
          <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
          <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
          <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
          <Fact label="Model"><Text value={r.model} /></Fact>
          <Fact label="Hoses reported by source">
            {r.number_of_hoses === null ? <NullValue /> : r.number_of_hoses}
          </Fact>
          <Fact label="Hoses (source text)"><Text value={r.number_of_hoses_raw} /></Fact>
          <Fact label="Notes"><Text value={r.notes} /></Fact>
        </>
      )}
      footnote="Hose counts here are what the source workbook reported. They are kept for traceability and never reconciled automatically against the Hoses tab."
    />
  )
}
