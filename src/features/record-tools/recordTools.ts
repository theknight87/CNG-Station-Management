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

/**
 * Tables whose next calibration is always one year after the last (owner ruling 2026-09-29: relief valves and gas
 * detectors). It is never typed: the editor and the add forms derive it from the last calibration date.
 */
export const ANNUAL_CALIBRATION_TABLES: readonly EditableTable[] = ['installed_relief_valves', 'warehouse_relief_valves', 'gas_detectors']

/** `YYYY-MM-DD` + one year, as PostgreSQL `date + interval '1 year'` does it (29 Feb -> 28 Feb). Blank or invalid -> null. */
export function oneYearAfter(date: string): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(date.trim())
  if (!m) return null
  const y = Number(m[1]) + 1, mo = Number(m[2]), d = Number(m[3])
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate()
  return `${y}-${m[2]}-${String(Math.min(d, last)).padStart(2, '0')}`
}

/** One set-pressure value (no range, owner ruling 2026-09-29). Blank -> null; anything not a number -> undefined. */
export function parsePressure(text: string): number | null | undefined {
  const t = text.trim()
  if (t === '') return null
  return /^\d+(\.\d+)?$/.test(t) ? Number(t) : undefined
}

/** Columns the editor never shows: precision and serial status follow the value typed; review flags are the system's. */
export function hiddenInEditor(table: EditableTable, name: string): boolean {
  if (name.endsWith('_precision') || name === 'serial_status' || name === 'needs_review' || name === 'review_reason') return true
  return name === 'next_calibration_date' && ANNUAL_CALIBRATION_TABLES.includes(table)
}
