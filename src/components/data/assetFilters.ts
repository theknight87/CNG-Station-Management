/**
 * The dedicated registry filters (owner request 2026-09-28), shared by Vessels, Gas Detectors and Hoses the same way
 * the SRV screens have them: serial contains, Station name contains, manufacturer, and — where the asset has one — a
 * pressure given as one value (30) or a range (30-35), matching every record whose recorded value falls in it.
 */
import { applyDateRange, EMPTY_DATE_RANGE, hasDateRange, type DateOption, type DateRange } from '@/components/data/dateRange'

export interface AssetFilters extends DateRange {
  serial: string
  station: string
  maker: string
  pressure: string
  pressureUnit: '' | 'BAR' | 'PSI'
}

export const EMPTY_ASSET_FILTERS: AssetFilters = { serial: '', station: '', maker: '', pressure: '', pressureUnit: '', ...EMPTY_DATE_RANGE }

export function hasAssetFilters(f: AssetFilters): boolean {
  return Boolean(f.serial.trim() || f.station.trim() || f.maker || f.pressure.trim() || f.pressureUnit || hasDateRange(f))
}

export function parseRange(value: string): { lo: number; hi: number } | null {
  const m = /^\s*(\d+(?:\.\d+)?)\s*(?:[-–]\s*(\d+(?:\.\d+)?))?\s*$/.exec(value)
  if (!m) return null
  const a = Number(m[1]), b = m[2] === undefined ? a : Number(m[2])
  return { lo: Math.min(a, b), hi: Math.max(a, b) }
}

export interface AssetFilterColumns {
  serial?: string
  station?: string
  maker?: string
  /** A single recorded value column (hoses: working_pressure_value). */
  pressure?: string
  pressureUnit?: string
  /** The dates the registry can be filtered by. */
  dates?: DateOption[]
}

/** Applies the filters to a PostgREST builder; a column the dataset lacks is simply not filtered. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function applyAssetFilters<B extends { ilike: any; lte: any; gte: any; lt: any; eq: any }>(b: B, f: AssetFilters, c: AssetFilterColumns): B {
  const clean = (v: string) => v.trim().replace(/[%*,()]/g, ' ').trim()
  if (c.serial && clean(f.serial)) b = b.ilike(c.serial, `%${clean(f.serial)}%`)
  if (c.station && clean(f.station)) b = b.ilike(c.station, `%${clean(f.station)}%`)
  if (c.maker && f.maker) b = b.ilike(c.maker, clean(f.maker))
  const range = parseRange(f.pressure)
  if (c.pressure && range) b = b.gte(c.pressure, range.lo).lte(c.pressure, range.hi)
  if (c.pressureUnit && f.pressureUnit) b = b.eq(c.pressureUnit, f.pressureUnit)
  return applyDateRange(b, f, c.dates)
}
