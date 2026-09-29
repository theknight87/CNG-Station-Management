import { AVAILABILITY_LABEL } from '@/features/relief-valves/useSrvManagement'
import { sizeText } from '@/features/relief-valves/useSrvWorkflow'
import { DUE_LABEL } from '@/features/units/dueLabels'
import type { DueStatus } from '@/features/units/useUnitWorkspace'
import type { AnyRow, ExportColumn } from './exportData'

/**
 * What each equipment family exports, column by column. ONE definition per family, used by its registry page,
 * by the Unit tabs and by the Region / Station / Unit workbooks, so the same asset never exports two ways.
 *
 * Columns read the view's own values: `*_display` for dates (a year-only date exports as its year, never as a
 * fabricated 1 January), the view's `days_left` and `due_status` (the alert engine's own computation), and the
 * confirmed Station separately from the raw source Station name (evidence is never promoted to a mapping).
 */

const text = (header: string, key: string): ExportColumn => ({ header, value: (r) => r[key] })
const num = (header: string, key: string): ExportColumn => ({ header, kind: 'number', value: (r) => r[key] })
const date = (header: string, key: string): ExportColumn => ({ header, kind: 'date', value: (r) => r[key] })

const MAPPING_LABEL: Record<string, string> = {
  resolved: 'Resolved',
  needs_equipment_mapping: 'Needs equipment mapping',
  needs_unit_mapping: 'Needs unit mapping',
  needs_station_mapping: 'Needs station mapping',
  conflict: 'Conflict',
}

const PRESENCE_LABEL: Record<string, string> = { installed: 'Installed', not_installed: 'Not installed', unknown: 'Unknown' }

const mapping: ExportColumn = { header: 'Mapping status', value: (r) => (r.mapping_status ? MAPPING_LABEL[r.mapping_status] ?? r.mapping_status : null) }
const due: ExportColumn = { header: 'Due status', value: (r) => (r.due_status ? DUE_LABEL[r.due_status as DueStatus] ?? r.due_status : null) }
const daysLeft = num('Days left', 'days_left')
const hierarchy: ExportColumn[] = [text('Region', 'region_name'), text('Station', 'station_name'), text('Unit', 'unit_name')]

/** One set pressure exports as a number; a legacy range stays as recorded text ("270-280"); none falls back to the raw text. */
export function pressureValue(r: AnyRow): number | string | null {
  const min = r.pressure_min as number | null, max = r.pressure_max as number | null
  if (min === null && max === null) return (r.set_pressure_raw as string | null) ?? null
  if (min !== null && max !== null && min !== max) return `${min}-${max}`
  return min ?? max
}
const pressure: ExportColumn[] = [
  { header: 'Set pressure', kind: 'number', value: pressureValue },
  text('Pressure unit', 'pressure_unit'),
]
const size: ExportColumn = { header: 'Size', value: (r) => sizeText(r.size_type, r.inlet_size, r.outlet_size) || null }

export const INSTALLED_SRV_COLUMNS: ExportColumn[] = [
  text('Region', 'region_name'), text('Station', 'station_name'), text('Source station name', 'source_station_name_raw'),
  text('Unit', 'unit_name'), mapping, text('Parent equipment', 'parent_label'), text('Source location', 'location_raw'),
  text('Tag number', 'tag_number'), text('Serial', 'serial_number'), text('Part number', 'part_number'), text('Manufacturer', 'manufacturer'),
  size, ...pressure, text('Warehouse code', 'warehouse_code'),
  date('Last calibration', 'last_calibration_display'), date('Next calibration', 'next_calibration_display'), daysLeft, due,
  text('Source status', 'source_status_raw'), text('Notes', 'notes'),
]

export const WAREHOUSE_SRV_COLUMNS: ExportColumn[] = [
  text('Serial', 'serial_number'), text('Part number', 'part_number'), text('Manufacturer', 'manufacturer'), size, ...pressure,
  { header: 'Availability', value: (r) => (r.availability_status ? AVAILABILITY_LABEL[r.availability_status] ?? r.availability_status : null) },
  text('Warehouse code', 'warehouse_code'),
  { header: 'Destination station', value: (r) => (r.is_unassigned_stock ? 'Unassigned stock' : r.target_station_name) },
  text('Destination region', 'target_region_name'), date('Issued from warehouse', 'warehouse_issue_date'),
  text('Calibration location', 'calibration_location'),
  date('Last calibration', 'last_calibration_display'), date('Next calibration', 'next_calibration_display'), daysLeft, due,
  text('Source status', 'source_status_raw'), text('Notes', 'notes'),
]

export const VESSEL_COLUMNS: ExportColumn[] = [
  ...hierarchy,
  { header: 'Type', value: (r) => (r.asset_type === 'recovery_tank' ? 'Recovery tank' : r.asset_type === 'storage_vessel' ? 'Storage vessel' : null) },
  mapping, text('Serial', 'serial_number'), text('Manufacturer', 'manufacturer'), text('Model', 'model'),
  text('Compressor type (source)', 'compressor_type_raw'),
  date('Last inspection', 'last_inspection_display'), date('Next inspection', 'next_inspection_display'), daysLeft, due,
  { header: 'Duplicate serial candidate', value: (r) => (r.serial_duplicate ? 'Yes' : null) },
  text('Source status', 'source_status_raw'), text('Notes', 'notes'),
]

export const GAS_DETECTOR_COLUMNS: ExportColumn[] = [
  ...hierarchy,
  { header: 'Presence', value: (r) => (r.detector_presence ? PRESENCE_LABEL[r.detector_presence] ?? r.detector_presence : null) },
  text('Area type', 'area_type'), mapping, text('Serial', 'serial_number'), text('Manufacturer', 'manufacturer'), text('Model', 'model'),
  date('Last calibration', 'last_calibration_display'), date('Next calibration', 'next_calibration_display'), daysLeft, due,
  text('Source status', 'source_status_raw'), text('Notes', 'notes'),
]

export const HOSE_COLUMNS: ExportColumn[] = [
  ...hierarchy, text('Dispenser', 'dispenser_name'), mapping, text('Description', 'description'), text('Serial', 'serial_number'),
  num('Working pressure', 'working_pressure_value'), text('Working pressure unit', 'working_pressure_unit'),
  num('Test pressure', 'test_pressure_value'), text('Test pressure unit', 'test_pressure_unit'),
  date('Last test', 'last_test_display'), date('Next test', 'next_test_display'), daysLeft, due,
  text('Source status', 'source_status_raw'), text('Notes', 'notes'),
]

export const COMPRESSOR_COLUMNS: ExportColumn[] = [
  ...hierarchy, text('Manufacturer', 'manufacturer'), text('Model', 'model'), text('Serial', 'serial_number'),
  text('Job number', 'job_number'), text('Part number', 'part_number'), num('Total running hours', 'total_running_hours'),
  num('Average hours per day', 'average_hours_per_day'), num('Average gas sales per day', 'average_gas_sales_per_day'),
  text('Notes', 'notes'),
]

export const DISPENSER_COLUMNS: ExportColumn[] = [
  ...hierarchy, text('Dispenser', 'dispenser_name'), text('Manufacturer', 'manufacturer'), text('Model', 'model'),
  text('Serial', 'serial_number'), num('Number of hoses', 'number_of_hoses'), text('Notes', 'notes'),
]

export const STATION_COLUMNS: ExportColumn[] = [
  text('Region', 'region_name'), text('Station', 'station_name'), num('Units', 'units'), num('Assets', 'assets'),
  num('Overdue', 'overdue'), num('Due within 60 days', 'approaching_due'), num('Unresolved mapping', 'unresolved_mapping'),
  text('Bay status', 'bay_status'), text('Notes', 'notes'),
]

export const UNIT_COLUMNS: ExportColumn[] = [
  ...hierarchy, text('Job number', 'job_number'), num('Compressors', 'compressors'), num('Recovery tanks', 'recovery_tanks'),
  num('Gas detectors', 'gas_detectors'), num('Dispensers', 'dispensers'), num('Storage vessels', 'storage_vessels'),
  num('Hoses', 'hoses'), num('Installed SRVs', 'installed_srvs'), num('Overdue', 'overdue'), text('Notes', 'notes'),
]

// --- SRV workflow tabs ------------------------------------------------------------------------------------------

const valve: ExportColumn[] = [text('Serial', 'serial_number'), text('Warehouse code', 'warehouse_code'), ...pressure,
  text('Manufacturer', 'manufacturer'), size]
const day = (header: string, key: string): ExportColumn => ({ header, kind: 'date', value: (r) => (r[key] ? String(r[key]).slice(0, 10) : null) })

const LOG_STATUS: Record<string, string> = {
  at_station: 'At station — awaiting return', location_unconfirmed: 'Location unconfirmed', returned: 'Returned to warehouse',
}
const LOG_REASON: Record<string, string> = {
  replaced_on_issue: 'Replaced by an issued valve',
  reconcile_other_serial: 'Sent to this Station, but the Station records a different valve',
  reconcile_station_not_found: 'Sent to this Station, but no valves are recorded there',
}
export const SRV_LOG_COLUMNS: ExportColumn[] = [
  ...valve, text('Region', 'region_name'), text('Station', 'station_display'), text('Unit', 'unit_name'),
  { header: 'Status', value: (r) => LOG_STATUS[r.status] ?? r.status },
  { header: 'Emergency', value: (r) => (r.is_emergency ? 'Yes' : null) },
  { header: 'Reason', value: (r) => LOG_REASON[r.reason] ?? r.reason },
  { header: 'Since', kind: 'date', value: (r) => String((r.reason === 'replaced_on_issue' ? r.logged_at : r.warehouse_issue_date ?? r.logged_at) ?? '').slice(0, 10) || null },
  day('Returned', 'returned_at'),
]

const CAL_STATUS: Record<string, string> = {
  sent: 'At the calibration company', returned_awaiting_certificate: 'Returned — certificate awaited', certified: 'Returned with certificate',
}
export const CALIBRATION_COLUMNS: ExportColumn[] = [
  ...valve, { header: 'Status', value: (r) => CAL_STATUS[r.status] ?? r.status },
  day('Sent', 'sent_at'), day('Returned', 'returned_at'), day('Certificate date', 'certificate_date'),
  text('Certificate number', 'certificate_number'), day('Next calibration', 'next_calibration_date'),
]

export const EMERGENCY_COLUMNS: ExportColumn[] = [
  day('Issued', 'issued_at'), text('Region', 'region_name'), text('Station', 'station_name'), text('Unit', 'unit_name'),
  text('Issued valve serial', 'issued_serial'), text('Issued valve code', 'issued_code'), ...pressure,
  text('Manufacturer', 'manufacturer'), size, text('Replaced valve serial', 'replaced_serial'), text('Replaced valve code', 'replaced_code'),
  { header: 'Replaced valve status', value: (r) => (r.replaced_status ? LOG_STATUS[r.replaced_status] ?? r.replaced_status : null) },
  text('Notes', 'notes'),
]
