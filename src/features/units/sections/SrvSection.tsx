import { useMemo, useState } from 'react'
import { useParams } from 'react-router-dom'

import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { EquipmentSection, type Column } from '@/features/units/EquipmentSection'
import { DueBadge, PrecisionDate, PressureRange, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import { useUnitEquipment, type UnitSrvRow } from '@/features/units/useUnitWorkspace'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { DataToolbar } from '@/components/layout/PageContainer'

/**
 * Safety Relief Valves whose Unit is CONFIRMED.
 *
 * THE VISIBILITY RULE LIVES IN SQL, NOT HERE. `v_unit_srvs` is defined as
 *
 *     unit_id IS NOT NULL
 *     AND mapping_status IN ('resolved', 'needs_equipment_mapping')
 *
 * so this component cannot show a valve it should not, even if it tried. In the
 * lifecycle's terms:
 *
 *   resolved                 shown - Station, Unit and equipment parent proven
 *   needs_equipment_mapping  shown - Station and Unit proven, parent not
 *   needs_unit_mapping       NOT shown - the Unit is not proven
 *   needs_station_mapping    NOT shown - not even the Station is proven
 *   conflict                 NOT shown - excluded by the same SQL predicate
 *
 * A valve is never attributed to a Unit the source has not proven it belongs to
 * (CLAUDE.md section 4). Warehouse relief valves live in a different table with
 * no `unit_id` at all, so they cannot appear here by construction.
 *
 * THE PARENT IS NEVER GUESSED. For `needs_equipment_mapping` the equipment
 * parent is genuinely unknown, and that is stated. `location_raw` - the source's
 * `Stage` or `Storage` text - is shown only as labelled SOURCE CONTEXT, never as
 * a compressor or vessel identity, and `expected_parent_kind` is shown as the
 * hint it is. Neither ever populates an equipment foreign key.
 */

const PARENT_KIND_LABEL: Record<string, string> = {
  compressor: 'Compressor',
  storage_vessel: 'Storage Vessel',
  dispenser: 'Dispenser',
}

/** The equipment parent, or an explicit statement that it is unresolved. */
function ParentCell({ row }: { row: UnitSrvRow }) {
  if (row.mapping_status === 'resolved' && row.parent_kind) {
    return (
      <span className="whitespace-nowrap">
        <span className="text-muted-foreground">{PARENT_KIND_LABEL[row.parent_kind]}</span>{' '}
        {row.parent_label ? <Identifier value={row.parent_label} /> : <NullValue />}
      </span>
    )
  }
  return (
    <span className="whitespace-nowrap">
      <StatusBadge kind="unmapped" label="Needs equipment mapping" />
    </span>
  )
}

const COLUMNS: Column<UnitSrvRow>[] = [
  { header: 'Serial', rowHeader: true, render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
  // Part Number is its own column, never folded into Serial. `SS-4R3A` is
  // owner-confirmed as a Part Number, so it belongs here and the serial stays
  // NULL where no genuine serial exists.
  { header: 'Part number', render: (r) => (r.part_number ? <Identifier value={r.part_number} /> : <NullValue />) },
  { header: 'Tag', render: (r) => (r.tag_number ? <Identifier value={r.tag_number} /> : <NullValue />) },
  { header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  {
    header: 'Set pressure',
    align: 'right',
    render: (r) => (
      <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
    ),
  },
  { header: 'Equipment parent', render: (r) => <ParentCell row={r} /> },
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

type MappingFilter = 'all' | 'resolved' | 'needs_equipment_mapping'
type DueFilter = 'all' | 'attention'

export function SrvSection() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnitEquipment<UnitSrvRow>('srvs', unitId)
  const [mapping, setMapping] = useState<MappingFilter>('all')
  const [due, setDue] = useState<DueFilter>('all')

  // Derived inside the memo rather than above it: a conditional array built
  // during render is a new reference every time, which would defeat the memo.
  const rows = useMemo(() => (state.status === 'ready' ? state.data : []), [state])

  // Filtering happens in memory ON PURPOSE here, unlike the Stations browser:
  // a Unit holds a bounded handful of valves that are already loaded and
  // already RLS-scoped, so a round trip per filter click would buy nothing.
  // The BOUNDARY is still the database - these filters only narrow rows the
  // caller already legitimately has.
  const filtered = useMemo(
    () =>
      rows.filter(
        (r) =>
          (mapping === 'all' || r.mapping_status === mapping) &&
          (due === 'all' || (r.due_status !== 'valid' && r.due_status !== 'unknown')),
      ),
    [rows, mapping, due],
  )

  const filteredState =
    state.status === 'ready' ? ({ status: 'ready', data: filtered } as typeof state) : state
  const hasFilters = mapping !== 'all' || due !== 'all'

  return (
    <div className="flex min-w-0 flex-col gap-2">
      <DataToolbar label="Filter this Unit's relief valves">
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Mapping</span>
          <select
            value={mapping}
            onChange={(e) => setMapping(e.target.value as MappingFilter)}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All Unit-confirmed</option>
            <option value="resolved">Resolved</option>
            <option value="needs_equipment_mapping">Needs equipment mapping</option>
          </select>
        </label>
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Due</span>
          <select
            value={due}
            onChange={(e) => setDue(e.target.value as DueFilter)}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All</option>
            <option value="attention">Needs attention</option>
          </select>
        </label>
      </DataToolbar>

      <EquipmentSection
        title="Relief Valves"
        state={filteredState}
        reload={reload}
        rowKey={(r) => r.id}
        columns={COLUMNS}
        emptyTitle={
          hasFilters && rows.length > 0
            ? 'No relief valves match these filters'
            : 'No Unit-confirmed relief valves for this Unit'
        }
        emptyDescription={
          hasFilters && rows.length > 0
            ? 'Relief valves are recorded for this Unit, but none match the current filters.'
            : 'Only valves whose Unit is confirmed appear here. Valves still awaiting Station or Unit confirmation are held in Admin → Data Quality and are never attributed to a Unit.'
        }
        errorTitle="Could not load Relief Valves"
        detail={(r) => (
          <>
            <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
            <Fact label="Serial (source)">{r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}</Fact>
            <Fact label="Part number">{r.part_number ? <Identifier value={r.part_number} /> : <NullValue />}</Fact>
            <Fact label="Tag number">{r.tag_number ? <Identifier value={r.tag_number} /> : <NullValue />}</Fact>
            <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
            <Fact label="Size type"><Text value={r.size_type} /></Fact>
            <Fact label="Inlet size">{r.inlet_size ? <Identifier value={r.inlet_size} /> : <NullValue />}</Fact>
            <Fact label="Outlet size">{r.outlet_size ? <Identifier value={r.outlet_size} /> : <NullValue />}</Fact>
            <Fact label="Set pressure">
              <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
            </Fact>
            <Fact label="Set pressure (source)"><Text value={r.set_pressure_raw} /></Fact>
            <Fact label="Equipment parent"><ParentCell row={r} /></Fact>
            {/* The source hint, labelled as exactly that. `Stage` is never
              * rendered as though it named a compressor. */}
            <Fact label="Expected parent (source hint)">
              {r.expected_parent_kind ? (
                <span>
                  {PARENT_KIND_LABEL[r.expected_parent_kind]}
                  <span className="ml-1 text-xs text-muted-foreground">which one is unknown</span>
                </span>
              ) : (
                <NullValue />
              )}
            </Fact>
            <Fact label="Location (source text)">
              {r.location_raw ? (
                <span>
                  <Identifier value={r.location_raw} />
                  <span className="ml-1 text-xs text-muted-foreground">source context, not an identity</span>
                </span>
              ) : (
                <NullValue />
              )}
            </Fact>
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
        footnote="Only valves whose Unit is confirmed are listed. Valves awaiting Station or Unit confirmation, and warehouse stock, are never shown on a Unit."
      />
    </div>
  )
}
