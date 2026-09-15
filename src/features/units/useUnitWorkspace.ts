import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { Loadable } from '@/features/hierarchy/useHierarchy'

/**
 * Equipment data for one Unit.
 *
 * THREE RULES THIS FILE ENFORCES.
 *
 * 1. **Ownership is proved by the database, never by the URL.** Every query
 *    filters `unit_id = :unitId` against an RLS-protected table or a
 *    `security_invoker` view. The `unitId` in the address bar is a lookup key,
 *    not a claim of authorization: if the caller cannot read that Unit's
 *    Region, the filter matches rows they cannot see and returns nothing. No
 *    asset is ever fetched by its own id and then assumed to belong here.
 *
 * 2. **A failed query is never an empty tab.** Each tab carries its own
 *    discriminated union, so "no Storage Vessels are recorded" and "Storage
 *    Vessels could not be loaded" cannot render the same way.
 *
 * 3. **No new database objects.** Everything below reads views that already
 *    exist (migrations 0001-0029 stay immutable):
 *
 *      Overview counts   v_unit_summary
 *      Compressors       compressors        (no dates on this table)
 *      Recovery tanks    v_vessel_management, asset_type = 'recovery_tank'
 *      Dispensers        dispensers         (no dates on this table)
 *      Storage vessels   v_vessel_management, asset_type = 'storage_vessel'
 *      Gas detectors     v_gas_detector_management
 *      Hoses             v_hose_management
 *      SRVs              v_unit_srvs
 *
 *    `v_unit_srvs` already encodes the Prompt-10 visibility rule in SQL:
 *    `unit_id IS NOT NULL AND mapping_status IN ('resolved',
 *    'needs_equipment_mapping')`. The rule is therefore enforced in PostgreSQL,
 *    not re-implemented here where it could drift. Warehouse relief valves live
 *    in a different table entirely and have no `unit_id`, so they cannot appear.
 */

export type DueStatus =
  | 'overdue' | 'due_today' | 'due_7' | 'due_15' | 'due_30' | 'due_60' | 'valid' | 'unknown'
export type DatePrecision = 'exact_date' | 'year_only' | 'unknown' | 'invalid'
export type PressureUnit = 'BAR' | 'PSI'

/** Fields every equipment row shares, so one detail renderer can handle them. */
interface AssetBase {
  id: string
  unit_id: string | null
  station_id: string | null
  mapping_status: string
  needs_review: boolean
  notes: string | null
  source_status_raw: string | null
}

export interface CompressorRow extends AssetBase {
  manufacturer: string | null
  manufacturer_raw: string | null
  model: string | null
  model_raw: string | null
  job_number: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  part_number: string | null
  total_running_hours: number | null
  average_hours_per_day: number | null
  average_gas_sales_per_day: number | null
  average_gas_sales_raw: string | null
}

export interface DispenserRow extends AssetBase {
  dispenser_name: string | null
  manufacturer: string | null
  model: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  number_of_hoses: number | null
  number_of_hoses_raw: string | null
}

/** Storage vessels and recovery tanks share one view and one shape. */
export interface VesselRow {
  asset_type: 'storage_vessel' | 'recovery_tank'
  id: string
  unit_id: string | null
  station_id: string | null
  mapping_status: string
  needs_mapping: boolean
  manufacturer: string | null
  model: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  compressor_type_raw: string | null
  last_inspection_date: string | null
  last_inspection_precision: DatePrecision | null
  last_inspection_display: string | null
  next_inspection_date: string | null
  next_inspection_precision: DatePrecision | null
  next_inspection_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
}

export interface DetectorRow {
  detector_id: string
  detector_presence: string | null
  unit_id: string | null
  station_id: string | null
  area_type: string | null
  area_type_raw: string | null
  mapping_status: string
  needs_mapping: boolean
  manufacturer: string | null
  model: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  last_calibration_date: string | null
  last_calibration_precision: DatePrecision | null
  last_calibration_display: string | null
  next_calibration_date: string | null
  next_calibration_precision: DatePrecision | null
  next_calibration_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
}

export interface HoseRow {
  id: string
  unit_id: string | null
  station_id: string | null
  dispenser_id: string | null
  dispenser_name: string | null
  mapping_status: string
  needs_mapping: boolean
  description: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  working_pressure_raw: string | null
  working_pressure_value: number | null
  working_pressure_unit: PressureUnit | null
  test_pressure_raw: string | null
  test_pressure_value: number | null
  test_pressure_unit: PressureUnit | null
  last_test_date: string | null
  last_test_precision: DatePrecision | null
  last_test_display: string | null
  next_test_date: string | null
  next_test_precision: DatePrecision | null
  next_test_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
}

export interface UnitSrvRow {
  id: string
  unit_id: string | null
  station_id: string | null
  mapping_status: 'resolved' | 'needs_equipment_mapping'
  mapping_label: string | null
  needs_mapping: boolean
  expected_parent_kind: 'compressor' | 'storage_vessel' | 'dispenser' | null
  location_raw: string | null
  parent_kind: 'compressor' | 'storage_vessel' | 'dispenser' | null
  parent_id: string | null
  parent_label: string | null
  tag_number: string | null
  serial_number: string | null
  serial_number_raw: string | null
  serial_status: string | null
  part_number: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  set_pressure_raw: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  last_calibration_date: string | null
  last_calibration_precision: DatePrecision | null
  last_calibration_display: string | null
  next_calibration_date: string | null
  next_calibration_precision: DatePrecision | null
  next_calibration_display: string | null
  days_left: number | null
  due_status: DueStatus
  source_status_raw: string | null
  needs_review: boolean
  notes: string | null
}

const COMPRESSOR_COLUMNS =
  'id, unit_id, station_id, mapping_status, needs_review, notes, source_status_raw, manufacturer, ' +
  'manufacturer_raw, model, model_raw, job_number, serial_number, serial_number_raw, serial_status, ' +
  'part_number, total_running_hours, average_hours_per_day, average_gas_sales_per_day, average_gas_sales_raw'

const DISPENSER_COLUMNS =
  'id, unit_id, station_id, mapping_status, needs_review, notes, source_status_raw, dispenser_name, ' +
  'manufacturer, model, serial_number, serial_number_raw, serial_status, number_of_hoses, number_of_hoses_raw'

const VESSEL_COLUMNS =
  'asset_type, id, unit_id, station_id, mapping_status, needs_mapping, manufacturer, model, serial_number, ' +
  'serial_number_raw, serial_status, compressor_type_raw, last_inspection_date, last_inspection_precision, ' +
  'last_inspection_display, next_inspection_date, next_inspection_precision, next_inspection_display, ' +
  'days_left, due_status, source_status_raw, needs_review, notes'

const DETECTOR_COLUMNS =
  'detector_id, detector_presence, unit_id, station_id, area_type, area_type_raw, mapping_status, ' +
  'needs_mapping, manufacturer, model, serial_number, serial_number_raw, serial_status, ' +
  'last_calibration_date, last_calibration_precision, last_calibration_display, next_calibration_date, ' +
  'next_calibration_precision, next_calibration_display, days_left, due_status, source_status_raw, ' +
  'needs_review, notes'

const HOSE_COLUMNS =
  'id, unit_id, station_id, dispenser_id, dispenser_name, mapping_status, needs_mapping, description, ' +
  'serial_number, serial_number_raw, serial_status, working_pressure_raw, working_pressure_value, ' +
  'working_pressure_unit, test_pressure_raw, test_pressure_value, test_pressure_unit, last_test_date, ' +
  'last_test_precision, last_test_display, next_test_date, next_test_precision, next_test_display, ' +
  'days_left, due_status, source_status_raw, needs_review, notes'

const SRV_COLUMNS =
  'id, unit_id, station_id, mapping_status, mapping_label, needs_mapping, expected_parent_kind, ' +
  'location_raw, parent_kind, parent_id, parent_label, tag_number, serial_number, serial_number_raw, ' +
  'serial_status, part_number, manufacturer, size_type, inlet_size, outlet_size, set_pressure_raw, ' +
  'pressure_min, pressure_max, pressure_unit, last_calibration_date, last_calibration_precision, ' +
  'last_calibration_display, next_calibration_date, next_calibration_precision, next_calibration_display, ' +
  'days_left, due_status, source_status_raw, needs_review, notes'

/** Which source each tab reads, and how it is narrowed to this Unit. */
const SOURCES = {
  compressor: { table: 'compressors', columns: COMPRESSOR_COLUMNS, order: 'serial_number', discriminator: null },
  'recovery-tank': { table: 'v_vessel_management', columns: VESSEL_COLUMNS, order: 'serial_number', discriminator: 'recovery_tank' },
  dispensers: { table: 'dispensers', columns: DISPENSER_COLUMNS, order: 'dispenser_name', discriminator: null },
  storage: { table: 'v_vessel_management', columns: VESSEL_COLUMNS, order: 'serial_number', discriminator: 'storage_vessel' },
  'gas-detectors': { table: 'v_gas_detector_management', columns: DETECTOR_COLUMNS, order: 'serial_number', discriminator: null },
  hoses: { table: 'v_hose_management', columns: HOSE_COLUMNS, order: 'serial_number', discriminator: null },
  srvs: { table: 'v_unit_srvs', columns: SRV_COLUMNS, order: 'serial_number', discriminator: null },
} as const

export type EquipmentTab = keyof typeof SOURCES

/**
 * Loads one tab's rows for one Unit.
 *
 * One query per tab, set-based. Nothing fetches a row in order to count it, and
 * nothing loads company-wide assets to filter them down in JavaScript.
 */
export function useUnitEquipment<T>(
  tab: EquipmentTab,
  unitId: string | undefined,
): { state: Loadable<T[]>; reload: () => void } {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<Loadable<T[]>>({ status: 'loading' })
  const [nonce, setNonce] = useState(0)
  const reload = useCallback(() => setNonce((n) => n + 1), [])

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!supabase) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (!unitId) {
        if (!cancelled) setState({ status: 'ready', data: [] })
        return
      }
      if (!cancelled) setState({ status: 'loading' })

      const source = SOURCES[tab]
      // `.eq('unit_id', unitId)` is the ownership proof. Combined with RLS on
      // the underlying tables it is impossible to receive a row belonging to
      // another Unit, or to a Region the caller cannot read.
      let request = supabase.from(source.table).select(source.columns).eq('unit_id', unitId)
      if (source.discriminator) request = request.eq('asset_type', source.discriminator)

      const { data, error } = await request.order(source.order, { nullsFirst: false })
      if (cancelled) return
      if (error) setState({ status: 'error', message: error.message })
      else setState({ status: 'ready', data: (data ?? []) as unknown as T[] })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, tab, unitId, nonce])

  return { state, reload }
}
