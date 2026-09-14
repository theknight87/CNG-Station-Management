import { CANONICAL_REGIONS, type CanonicalRegion } from '@/types/domain'

/**
 * Deterministic region aliases only (CLAUDE.md, data principle #7).
 * Anything not listed here is NOT guessed: the raw value is preserved and the
 * record is flagged for review.
 */
const REGION_ALIASES: Readonly<Record<string, CanonicalRegion>> = {
  east: 'East',
  west: 'West',
  'غرب': 'West',
  canal: 'Canal',
  delta: 'Delta',
  alex: 'Alex',
  upper: 'Upper',
}

export interface RegionNormalizationResult {
  /** Canonical region, or null when no deterministic rule applies. */
  canonical: CanonicalRegion | null
  /** The untouched source value, preserved for traceability (principle #6). */
  raw: string | null
  /** True when the caller must retain the row and flag it for review. */
  needsReview: boolean
}

/**
 * Normalizes a source region value. Empty source data stays empty
 * (principle #14) — a blank input is not an error and is not reviewed.
 */
export function normalizeRegion(raw: string | null | undefined): RegionNormalizationResult {
  if (raw === null || raw === undefined || raw.trim() === '') {
    return { canonical: null, raw: raw ?? null, needsReview: false }
  }

  const key = raw.trim().toLowerCase()
  const canonical = REGION_ALIASES[key] ?? null

  return { canonical, raw, needsReview: canonical === null }
}

export function isCanonicalRegion(value: string): value is CanonicalRegion {
  return (CANONICAL_REGIONS as readonly string[]).includes(value)
}
