/** Sorting and colour helpers shared by the SRV tables (kept out of component files for fast refresh). */

export type SortValue = string | number | null
export function compareValues(a: SortValue, b: SortValue): number {
  if (a === b) return 0
  if (a === null || a === '') return 1
  if (b === null || b === '') return -1
  if (typeof a === 'number' && typeof b === 'number') return a - b
  return String(a).localeCompare(String(b), 'ar', { numeric: true })
}

/** Rows ordered by several values in turn, nulls last at every level. */
export function byValues<T>(...fns: ((r: T) => SortValue)[]) {
  return (x: T, y: T) => {
    for (const f of fns) { const c = compareValues(f(x), f(y)); if (c !== 0) return c }
    return 0
  }
}

/** A coloured chip for any small status set (SRV Log, 3rd party). */
export const TONE = {
  sky: 'border-2 border-blue-600 bg-background text-blue-700 dark:text-blue-300',
  teal: 'border-2 border-emerald-600 bg-background text-emerald-700 dark:text-emerald-300',
  violet: 'border-2 border-purple-600 bg-background text-purple-700 dark:text-purple-300',
  orange: 'border-2 border-orange-500 bg-background text-orange-700 dark:text-orange-300',
  slate: 'border-2 border-slate-500 bg-background text-slate-700 dark:text-slate-300',
} as const

export type ToneName = keyof typeof TONE


/** Set pressure on one BAR scale for ordering only (PSI converted); never displayed. */
export function pressureBar(v: { pressure_max: number | null; pressure_unit: string | null }): number | null {
  if (v.pressure_max === null) return null
  if (v.pressure_unit === 'BAR') return v.pressure_max
  if (v.pressure_unit === 'PSI') return v.pressure_max * 0.0689476
  return null
}

/** Stage (compressor) relief valves first, then storage, then dispenser, then any whose position is not
 *  recorded. Ordering only: the expected-parent hint is read when no parent is confirmed, never stored. */
const SRV_GROUP_RANK: Record<string, number> = { compressor: 0, storage_vessel: 1, dispenser: 2 }
export function srvGroupRank(v: { parent_kind: string | null; expected_parent_kind: string | null }): number {
  return SRV_GROUP_RANK[v.parent_kind ?? v.expected_parent_kind ?? ''] ?? 3
}
