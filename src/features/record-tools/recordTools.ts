/** Shared types and pure helpers for admin record editing and photos. */

export type EditableTable =
  | 'stations' | 'units' | 'compressors' | 'dispensers' | 'storage_vessels' | 'recovery_tanks'
  | 'gas_detectors' | 'hoses' | 'installed_relief_valves' | 'warehouse_relief_valves'

export interface RecordRef { table: EditableTable; id: string }

export interface ColumnMeta { name: string; type: string; enum_values: string[] | null; nullable: boolean }
export type Row = Record<string, unknown>

export const PHOTO_BUCKET = 'asset-photos'
export const MAX_PHOTO_BYTES = 5 * 1024 * 1024
export const PHOTO_TYPES = ['image/jpeg', 'image/png', 'image/webp']

/** Human label from a column name: "next_calibration_date" -> "Next calibration date". */
export function columnLabel(name: string): string {
  const s = name.replace(/_/g, ' ')
  return s.charAt(0).toUpperCase() + s.slice(1)
}

export function asText(v: unknown): string {
  return v === null || v === undefined ? '' : String(v)
}

/** Form text -> the value sent to the database. Blank means NULL. */
export function toValue(meta: ColumnMeta, text: string): unknown {
  const t = text.trim()
  if (t === '') return null
  if (meta.type === 'boolean') return t === 'true'
  if (meta.type === 'integer' || meta.type === 'numeric') return Number(t)
  return t
}
