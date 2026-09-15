import type { CanonicalRegion } from '../types'
import { cellToText } from './identifiers'

/**
 * Region normalization (CLAUDE.md §6).
 *
 * There are SIX canonical Regions and there will not be a seventh. An
 * unrecognized value becomes an import issue; it never creates a Region.
 */

export const CANONICAL_REGIONS: ReadonlyArray<CanonicalRegion> = [
  'East',
  'West',
  'Canal',
  'Delta',
  'Alex',
  'Upper',
]

/**
 * Deterministic aliases only: case folding plus the one Arabic name the source
 * actually contains. This table is exhaustive by enumeration, not by pattern.
 */
const ALIASES = new Map<string, CanonicalRegion>([
  ['east', 'East'],
  ['west', 'West'],
  ['غرب', 'West'],
  ['canal', 'Canal'],
  ['delta', 'Delta'],
  ['alex', 'Alex'],
  ['upper', 'Upper'],
])

export interface NormalizedRegion {
  value: CanonicalRegion | null
  raw: string | null
  rule: string | null
}

export function normalizeRegion(raw: unknown): NormalizedRegion {
  let text: string | null
  try {
    text = cellToText(raw)
  } catch {
    return { value: null, raw: String(raw), rule: null }
  }
  if (text === null) return { value: null, raw: null, rule: null }

  const key = text.trim().toLowerCase()
  const match = ALIASES.get(key)
  if (match) return { value: match, raw: text, rule: `region_alias:${key}->${match}` }

  // Unrecognized. The raw value is preserved and the caller raises
  // `unknown_region`. No Region is created and nothing is guessed.
  return { value: null, raw: text, rule: null }
}
