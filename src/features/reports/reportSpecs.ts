import type { CsvColumn } from './csv'

/**
 * The report registry.
 *
 * ONE DECLARATION PER REPORT, driving the table, the CSV and the server-side
 * query together. That is deliberate: if the table and the export were declared
 * separately they would drift, and an export that showed a column the table did
 * not — or worse, queried rows the table did not — is exactly the leak §15
 * warns about. One spec, one query shape, one column order.
 *
 * WHICH VIEW EACH REPORT READS is stated here and nowhere else. Every one is an
 * existing, RLS-bounded, `security_invoker` view (see migration 0042's header);
 * only `v_report_due_compliance` is new, and it too is built on those views.
 */

export type ReportId =
  | 'due' | 'srv' | 'srv-warehouse' | 'vessels'
  | 'gas-detectors' | 'hoses' | 'data-quality' | 'activity'

export type FilterKey =
  | 'region' | 'station' | 'unit' | 'assetType'
  | 'dueState' | 'mappingStatus' | 'dateRange' | 'search'

export interface ReportRow { [key: string]: unknown }

export interface ReportColumn {
  key: string
  header: string
  kind?: 'text' | 'number' | 'date'
  align?: 'left' | 'right'
  /** Rendered differently in the table (badge, date-with-precision, …). */
  render?: 'due_status' | 'mapping_status' | 'date_display' | 'serial' | 'plain'
  /** The sibling column carrying the precision label, for a date. */
  displayKey?: string
  /**
   * The sibling column carrying `serial_status`. Without it a serial that the
   * source says is NOT YET ASSIGNED would render as merely missing, losing the
   * distinction data principle #20 exists to keep.
   */
  statusKey?: string
}

export interface ReportSpec {
  id: ReportId
  label: string
  /** One-line statement of what question this report answers. */
  description: string
  view: string
  /** The row's stable identity, and the secondary sort key. */
  idColumn: string
  columns: ReportColumn[]
  filters: FilterKey[]
  /** Which physical column each filter targets in THIS view. */
  filterColumns: Partial<Record<Exclude<FilterKey, 'search'>, string>> & {
    search?: string[]
  }
  /** Primary ordering. The id column is always appended, for determinism. */
  orderBy: { column: string; ascending: boolean }[]
  /** Asset-type choices where the report covers more than one family. */
  assetTypeOptions?: { value: string; label: string }[]
  /**
   * Extra summary counts, each a value of one column.
   *
   * Used where the generic due-state breakdown says nothing useful — the Data
   * Quality report's meaningful split is by KIND of issue, and a lapsed
   * pre-import decision must be countable on its own rather than folded into a
   * general "unresolved" figure.
   */
  summaryBreakdown?: {
    column: string
    values: { value: string; label: string; description: string }[]
  }
  /** A row links into the workspace that owns the record, where one exists. */
  drillThrough?: (row: ReportRow) => string | null
}

const DUE_COLUMNS: ReportColumn[] = [
  { key: 'due_status', header: 'Due State', render: 'due_status' },
  { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
  { key: 'next_due_date', header: 'Next Due', kind: 'date', render: 'date_display', displayKey: 'next_due_display' },
  { key: 'last_done_date', header: 'Last Done', kind: 'date', render: 'date_display', displayKey: 'last_done_display' },
]

const HIERARCHY_COLUMNS: ReportColumn[] = [
  { key: 'region_name', header: 'Region' },
  { key: 'station_display', header: 'Station' },
  { key: 'unit_name', header: 'Unit' },
]

/** A Unit link is the one drill-through every asset family shares. */
function unitDrill(row: ReportRow): string | null {
  const unitId = row.unit_id as string | null
  return unitId ? `/units/${unitId}` : null
}

export const REPORT_SPECS: ReportSpec[] = [
  {
    id: 'due',
    label: 'Due & Overdue',
    description:
      'Every asset family in one compliance list, classified from exact due dates only.',
    view: 'v_report_due_compliance',
    idColumn: 'asset_id',
    columns: [
      { key: 'asset_type', header: 'Asset Type' },
      ...HIERARCHY_COLUMNS,
      { key: 'parent_label', header: 'Equipment / Parent' },
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'unit_job_number', header: 'Unit Job No.' },
      { key: 'manufacturer', header: 'Manufacturer' },
      { key: 'model', header: 'Model' },
      ...DUE_COLUMNS,
      { key: 'mapping_status', header: 'Mapping Status', render: 'mapping_status' },
    ],
    filters: ['region', 'station', 'unit', 'assetType', 'dueState', 'mappingStatus', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      assetType: 'asset_type', dueState: 'due_status', mappingStatus: 'mapping_status',
      search: ['serial_number', 'serial_number_raw', 'station_name', 'source_station_name_raw', 'unit_job_number'],
    },
    orderBy: [{ column: 'next_due_date', ascending: true }],
    assetTypeOptions: [
      { value: 'installed_relief_valve', label: 'Installed SRV' },
      { value: 'storage_vessel', label: 'Storage Vessel' },
      { value: 'recovery_tank', label: 'Recovery Tank' },
      { value: 'gas_detector', label: 'Gas Detector' },
      { value: 'hose', label: 'Hose' },
    ],
    drillThrough: unitDrill,
  },
  {
    id: 'srv',
    label: 'SRV (Installed)',
    description:
      'Installed Safety Relief Valves, with their equipment parent and mapping lifecycle.',
    view: 'v_installed_srv_management',
    idColumn: 'id',
    columns: [
      ...HIERARCHY_COLUMNS,
      { key: 'parent_kind', header: 'Parent Type' },
      { key: 'parent_label', header: 'Equipment' },
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'part_number', header: 'Part Number', render: 'serial' },
      { key: 'manufacturer', header: 'Manufacturer' },
      { key: 'set_pressure_raw', header: 'Set Pressure' },
      { key: 'last_calibration_date', header: 'Last Calibration', kind: 'date', render: 'date_display', displayKey: 'last_calibration_display' },
      { key: 'next_calibration_date', header: 'Next Calibration', kind: 'date', render: 'date_display', displayKey: 'next_calibration_display' },
      { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
      { key: 'due_status', header: 'Due State', render: 'due_status' },
      { key: 'mapping_status', header: 'Mapping Status', render: 'mapping_status' },
      { key: 'source_file', header: 'Source File' },
      { key: 'source_row', header: 'Source Row', kind: 'number', align: 'right' },
    ],
    filters: ['region', 'station', 'unit', 'dueState', 'mappingStatus', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      dueState: 'due_status', mappingStatus: 'mapping_status',
      search: ['serial_number', 'serial_number_raw', 'part_number', 'manufacturer', 'station_name', 'source_station_name_raw'],
    },
    orderBy: [{ column: 'next_calibration_date', ascending: true }],
    drillThrough: unitDrill,
  },
  {
    id: 'srv-warehouse',
    label: 'SRV (Warehouse)',
    description:
      'Warehouse stock. A SEPARATE inventory — never counted with installed valves.',
    view: 'v_warehouse_srv_management',
    idColumn: 'id',
    columns: [
      { key: 'availability_status', header: 'Availability' },
      { key: 'warehouse_code', header: 'Warehouse Code' },
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'part_number', header: 'Part Number', render: 'serial' },
      { key: 'manufacturer', header: 'Manufacturer' },
      { key: 'set_pressure_raw', header: 'Set Pressure' },
      { key: 'target_region_name', header: 'Target Region' },
      { key: 'target_station_name', header: 'Target Station' },
      { key: 'last_calibration_date', header: 'Last Calibration', kind: 'date', render: 'date_display', displayKey: 'last_calibration_display' },
      { key: 'next_calibration_date', header: 'Next Calibration', kind: 'date', render: 'date_display', displayKey: 'next_calibration_display' },
      { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
      { key: 'due_status', header: 'Due State', render: 'due_status' },
    ],
    filters: ['dueState', 'search'],
    filterColumns: {
      dueState: 'due_status',
      search: ['serial_number', 'serial_number_raw', 'part_number', 'warehouse_code', 'manufacturer'],
    },
    orderBy: [{ column: 'next_calibration_date', ascending: true }],
  },
  {
    id: 'vessels',
    label: 'Vessels',
    description:
      'Storage Vessels and Recovery Tanks. Distinct entities, shown with their type.',
    view: 'v_vessel_management',
    idColumn: 'id',
    columns: [
      { key: 'asset_type', header: 'Vessel Type' },
      ...HIERARCHY_COLUMNS,
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'manufacturer', header: 'Manufacturer' },
      { key: 'model', header: 'Model' },
      { key: 'compressor_type_raw', header: 'Compressor Context' },
      { key: 'last_inspection_date', header: 'Last Inspection', kind: 'date', render: 'date_display', displayKey: 'last_inspection_display' },
      { key: 'next_inspection_date', header: 'Next Inspection', kind: 'date', render: 'date_display', displayKey: 'next_inspection_display' },
      { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
      { key: 'due_status', header: 'Due State', render: 'due_status' },
      { key: 'mapping_status', header: 'Mapping Status', render: 'mapping_status' },
    ],
    filters: ['region', 'station', 'unit', 'assetType', 'dueState', 'mappingStatus', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      assetType: 'asset_type', dueState: 'due_status', mappingStatus: 'mapping_status',
      search: ['serial_number', 'serial_number_raw', 'manufacturer', 'model', 'station_name'],
    },
    orderBy: [{ column: 'next_inspection_date', ascending: true }],
    assetTypeOptions: [
      { value: 'storage_vessel', label: 'Storage Vessel' },
      { value: 'recovery_tank', label: 'Recovery Tank' },
    ],
    drillThrough: unitDrill,
  },
  {
    id: 'gas-detectors',
    label: 'Gas Detectors',
    description: 'Installed detectors and their calibration state.',
    // `v_report_gas_detectors`, not `v_gas_detector_management`: the management
    // view deliberately UNIONs recorded ABSENCE, which is evidence that an area
    // has no detector rather than a device. Reporting absence as an installed
    // asset would be false, and its NULL `detector_id` would leave pagination
    // without a stable key (Prompt 20A).
    view: 'v_report_gas_detectors',
    idColumn: 'detector_id',
    columns: [
      ...HIERARCHY_COLUMNS,
      { key: 'area_type', header: 'Area Type' },
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'manufacturer', header: 'Manufacturer' },
      { key: 'model', header: 'Model' },
      { key: 'last_calibration_date', header: 'Last Calibration', kind: 'date', render: 'date_display', displayKey: 'last_calibration_display' },
      { key: 'next_calibration_date', header: 'Next Calibration', kind: 'date', render: 'date_display', displayKey: 'next_calibration_display' },
      { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
      { key: 'due_status', header: 'Due State', render: 'due_status' },
      { key: 'mapping_status', header: 'Mapping Status', render: 'mapping_status' },
    ],
    filters: ['region', 'station', 'unit', 'dueState', 'mappingStatus', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      dueState: 'due_status', mappingStatus: 'mapping_status',
      search: ['serial_number', 'serial_number_raw', 'manufacturer', 'model', 'station_name'],
    },
    orderBy: [{ column: 'next_calibration_date', ascending: true }],
    drillThrough: unitDrill,
  },
  {
    id: 'hoses',
    label: 'Hoses',
    description:
      'Hose hydrotest state. A hose with a proven Station but no proven Unit is normal.',
    view: 'v_hose_registry',
    idColumn: 'id',
    columns: [
      ...HIERARCHY_COLUMNS,
      { key: 'dispenser_name', header: 'Dispenser' },
      { key: 'serial_number', header: 'Serial', render: 'serial', statusKey: 'serial_status' },
      { key: 'description', header: 'Description' },
      { key: 'working_pressure_raw', header: 'Working Pressure' },
      { key: 'test_pressure_raw', header: 'Test Pressure' },
      { key: 'last_test_date', header: 'Last Test', kind: 'date', render: 'date_display', displayKey: 'last_test_display' },
      { key: 'next_test_date', header: 'Next Test', kind: 'date', render: 'date_display', displayKey: 'next_test_display' },
      { key: 'days_left', header: 'Days Remaining', kind: 'number', align: 'right' },
      { key: 'due_status', header: 'Due State', render: 'due_status' },
      { key: 'mapping_status', header: 'Mapping Status', render: 'mapping_status' },
    ],
    filters: ['region', 'station', 'unit', 'dueState', 'mappingStatus', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      dueState: 'due_status', mappingStatus: 'mapping_status',
      search: ['serial_number', 'serial_number_raw', 'description', 'station_name'],
    },
    orderBy: [{ column: 'next_test_date', ascending: true }],
    drillThrough: unitDrill,
  },
  {
    id: 'data-quality',
    label: 'Data Quality',
    description:
      'Unresolved and flagged records across canonical assets, staged pre-import rows and open import issues. Read-only: corrections stay in Admin.',
    // Three layers in one view, each keeping its OWN RLS. A viewer or engineer
    // reads the canonical layer within their Regions and nothing else; a
    // manager or admin reads all three. Reading only the canonical layer — as
    // this report did before Prompt 20A — made the report look clean while the
    // staged import carried real unresolved evidence.
    view: 'v_report_data_quality',
    idColumn: 'dq_key',
    columns: [
      { key: 'source_layer', header: 'Layer' },
      { key: 'issue_kind', header: 'Issue' },
      { key: 'asset_type', header: 'Asset Type' },
      { key: 'region_name', header: 'Region' },
      { key: 'station_name', header: 'Station' },
      { key: 'raw_station', header: 'Raw Source Value' },
      { key: 'detail', header: 'Detail' },
      { key: 'severity', header: 'Severity' },
      { key: 'source_file', header: 'Source File' },
      { key: 'source_row', header: 'Source Row', kind: 'number', align: 'right' },
      { key: 'observed_at', header: 'Last Updated', kind: 'date' },
    ],
    filters: ['region', 'station', 'unit', 'assetType', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', unit: 'unit_id',
      assetType: 'asset_type',
      search: ['issue_kind', 'detail', 'raw_station', 'source_file'],
    },
    orderBy: [{ column: 'observed_at', ascending: false }],
    assetTypeOptions: [
      { value: 'installed_relief_valve', label: 'Installed SRV' },
      { value: 'storage_vessel', label: 'Storage Vessel' },
      { value: 'recovery_tank', label: 'Recovery Tank' },
      { value: 'gas_detector', label: 'Gas Detector' },
      { value: 'hose', label: 'Hose' },
    ],
    summaryBreakdown: {
      column: 'issue_kind',
      values: [
        {
          value: 'stale_source_decision', label: 'Stale Source Decision',
          description:
            'A previous pre-import mapping decision no longer applies because the source content changed. Distinct from never having decided, and never treated as confirmed.',
        },
        {
          value: 'staged_awaiting_decision', label: 'Awaiting Decision',
          description: 'A staged row no human has ruled on yet',
        },
        {
          value: 'staged_decision_recorded', label: 'Decision Recorded',
          description: 'A staged row with a confirmed decision still matching its source content',
        },
        {
          value: 'needs_station_mapping', label: 'Needs Station Mapping',
          description: 'A canonical asset whose Station the source did not prove',
        },
        {
          value: 'needs_unit_mapping', label: 'Needs Unit Mapping',
          description: 'A canonical asset whose Unit the source did not prove',
        },
        {
          value: 'needs_equipment_mapping', label: 'Needs Equipment Mapping',
          description: 'A canonical SRV whose equipment parent the source did not prove',
        },
        {
          value: 'conflict', label: 'Conflict',
          description: 'Source evidence disagrees and a human must resolve it',
        },
      ],
    },
  },
  {
    id: 'activity',
    label: 'Notification Activity',
    description:
      'Alerts raised in a period, with the delivery evidence actually stored.',
    view: 'v_alert_inbox',
    idColumn: 'id',
    columns: [
      { key: 'generated_at', header: 'Raised', kind: 'date' },
      { key: 'subject', header: 'Subject' },
      { key: 'threshold', header: 'Threshold' },
      { key: 'asset_type', header: 'Asset Type' },
      { key: 'asset_serial', header: 'Serial', render: 'serial', statusKey: 'asset_serial_status' },
      { key: 'region_name', header: 'Region' },
      { key: 'station_name', header: 'Station' },
      { key: 'unit_name', header: 'Unit' },
      { key: 'due_date', header: 'Due Date', kind: 'date' },
      { key: 'state', header: 'Alert State' },
      { key: 'acknowledged_by_name', header: 'Acknowledged By' },
      { key: 'acknowledged_at', header: 'Acknowledged At', kind: 'date' },
      { key: 'email_status', header: 'Email Delivery' },
      { key: 'push_status', header: 'Web Push Delivery' },
    ],
    filters: ['region', 'station', 'dateRange', 'search'],
    filterColumns: {
      region: 'region_id', station: 'station_id', dateRange: 'generated_at',
      search: ['asset_serial', 'station_name', 'source_station_name_raw'],
    },
    orderBy: [{ column: 'generated_at', ascending: false }],
  },
]

export function reportSpec(id: ReportId): ReportSpec {
  const spec = REPORT_SPECS.find((s) => s.id === id)
  if (!spec) throw new Error(`unknown report: ${id}`)
  return spec
}

/** The CSV columns for a report: the same columns, in the same order. */
export function csvColumnsFor(spec: ReportSpec): CsvColumn<ReportRow>[] {
  return spec.columns.map((c) => ({
    header: c.header,
    kind: c.kind ?? 'text',
    // The RAW value, not the rendered badge. A CSV carries data, not labels —
    // and a date is exported as its exact ISO date or blank, never as
    // "2022 (year only)" masquerading as a date.
    value: (row: ReportRow) => row[c.key],
  }))
}

/** Every column the report needs, including the sibling display/id columns. */
export function selectColumnsFor(spec: ReportSpec): string[] {
  const keys = new Set<string>([spec.idColumn])
  for (const c of spec.columns) {
    keys.add(c.key)
    if (c.displayKey) keys.add(c.displayKey)
    if (c.statusKey) keys.add(c.statusKey)
    // A precision-rendered date needs its sibling precision column.
    if (c.render === 'date_display') keys.add(`${c.key.replace(/_date$/, '')}_precision`)
  }
  // Drill-through needs the Unit id even when the Unit column is not shown —
  // but only where the report HAS one. `v_warehouse_srv_management` carries no
  // unit_id at all, because warehouse stock hangs off no Unit, and selecting a
  // column a view does not have is an error, not an empty value.
  if (spec.drillThrough) keys.add('unit_id')
  return [...keys]
}
