import type { WarehouseSrvRow } from '@/features/relief-valves/useSrvManagement'
import type { PressureUnit } from '@/features/units/useUnitWorkspace'

/** Which store valves may replace an installed one (see ReplaceValvePanel). Kept apart from the component for fast refresh. */

export interface ReplaceableValve {
  id: string
  serial_number: string | null
  station_id: string | null
  unit_id: string | null
  manufacturer: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  pressure_min: number | null
  pressure_max: number | null
  pressure_unit: PressureUnit | null
  set_pressure_raw: string | null
}

export type StockRow = Pick<WarehouseSrvRow, 'id' | 'serial_number' | 'warehouse_code' | 'manufacturer' | 'part_number' | 'size_type' |
  'inlet_size' | 'outlet_size' | 'pressure_min' | 'pressure_max' | 'pressure_unit' | 'set_pressure_raw' | 'availability_status' |
  'last_calibration_display' | 'next_calibration_display' | 'updated_at'>

export const STOCK_COLUMNS = 'id, serial_number, warehouse_code, manufacturer, part_number, size_type, inlet_size, outlet_size, pressure_min, ' +
  'pressure_max, pressure_unit, set_pressure_raw, availability_status, last_calibration_display, next_calibration_display, updated_at'

/** Size parts compared as written, ignoring spaces, quote marks and case: `1/2"` = `1/2 ”`. */
export const sizeKey = (v: string | null | undefined) => (v ?? '').toLowerCase().replace(/[\s"'“”″]/g, '')

/** Keep a store valve when every part the installed valve records is the same. */
export function matchesSpec(valve: ReplaceableValve, s: StockRow, sameMaker: boolean): boolean {
  const same = (a: string | null | undefined, b: string | null | undefined) => !sizeKey(a) || sizeKey(a) === sizeKey(b)
  return same(valve.size_type, s.size_type) && same(valve.inlet_size, s.inlet_size) && same(valve.outlet_size, s.outlet_size)
    && (!sameMaker || same(valve.manufacturer, s.manufacturer))
}
