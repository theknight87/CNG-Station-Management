import type { NormalizedIdentifier, Provenance } from '../types'

/**
 * Identifier normalization — TEXT, always (CLAUDE.md principle #11, #15).
 *
 * Excel damage is preserved, never repaired. A lost leading zero is not
 * recoverable from the source and is therefore not guessed.
 */

/**
 * The ONLY owner-confirmed part numbers. This is an exact-value list, mirroring
 * `owner_confirmed_part_numbers` in the database. There is no pattern, no
 * regex, no suffix rule, and no shape heuristic anywhere in this file.
 */
export const OWNER_CONFIRMED_PART_NUMBERS: ReadonlyArray<string> = ['SS-4R3A']

/** Placeholders that mean "nothing here". `0` is deliberately NOT one. */
const PLACEHOLDERS = new Set(['-', '--', 'n/a', 'na', 'n\\a', '______', '__________', '#n/a'])

/**
 * Renders a raw Excel cell as TEXT without numeric formatting.
 *
 * An integer 21586 becomes "21586"; a float 1803.02075 stays "1803.02075".
 * Scientific notation is refused outright rather than silently accepted,
 * because a value that reached that form has already lost digits.
 */
export function cellToText(value: unknown): string | null {
  if (value === null || value === undefined) return null

  if (typeof value === 'string') {
    const trimmed = value.trim()
    return trimmed.length === 0 ? null : trimmed
  }

  if (typeof value === 'number') {
    if (!Number.isFinite(value)) return null
    const text = String(value)
    if (/e/i.test(text)) {
      // Never "expand" this: the digits are already gone. The caller raises
      // identifier_numeric_coercion and the raw cell is kept.
      throw new IdentifierCoercionError(text)
    }
    return text
  }

  if (typeof value === 'boolean') return String(value)
  if (value instanceof Date) return value.toISOString()

  // ExcelJS rich text / formula / hyperlink cells.
  const obj = value as { text?: unknown; result?: unknown; richText?: Array<{ text: string }> }
  if (Array.isArray(obj.richText)) return cellToText(obj.richText.map((r) => r.text).join(''))
  if (obj.text !== undefined) return cellToText(obj.text)
  if (obj.result !== undefined) return cellToText(obj.result)

  return null
}

export class IdentifierCoercionError extends Error {
  readonly rendered: string

  constructor(rendered: string) {
    super(`identifier rendered in scientific notation: ${rendered}`)
    this.name = 'IdentifierCoercionError'
    this.rendered = rendered
  }
}

export function isPlaceholder(text: string | null): boolean {
  if (text === null) return false
  return PLACEHOLDERS.has(text.trim().toLowerCase())
}

/**
 * Classifies one identifier cell from a SERIAL column.
 *
 * The only reclassification that can happen is an EXACT, case-sensitive match
 * against the owner-confirmed list. Everything else stays a serial, however
 * much it looks like a part number — shape is not evidence (CLAUDE.md §8).
 */
export function classifySerialCell(
  raw: unknown,
  _provenance?: Provenance,
): NormalizedIdentifier {
  let text: string | null
  try {
    text = cellToText(raw)
  } catch (err) {
    if (err instanceof IdentifierCoercionError) {
      return {
        serialNumber: null,
        partNumber: null,
        serialStatus: 'unknown',
        raw: err.rendered,
      }
    }
    throw err
  }

  if (text === null) {
    return { serialNumber: null, partNumber: null, serialStatus: 'unknown', raw: null }
  }

  if (isPlaceholder(text)) {
    // The literal value is preserved as raw evidence and classified unusable.
    return { serialNumber: null, partNumber: null, serialStatus: 'unknown', raw: text }
  }

  // EXACT match only. No trimming variants, no case folding, no shape rules.
  if (OWNER_CONFIRMED_PART_NUMBERS.includes(text)) {
    return {
      serialNumber: null,
      partNumber: text,
      // D4: this asset type has no serial assigned YET — a fact, not a gap.
      serialStatus: 'not_yet_assigned',
      raw: text,
      ownerConfirmedRule: `owner_confirmed_part_number:${text}`,
    }
  }

  return {
    serialNumber: text,
    partNumber: null,
    serialStatus: 'assigned',
    raw: text,
    // Advisory flag ONLY. It changes no column; a human decides.
    suspectedPartNumber: looksLikePartNumber(text),
  }
}

/**
 * A REPORTING heuristic, never an action. Its result is surfaced as
 * `suspected_part_number_in_serial_column` and nothing else. It must never be
 * wired to a write.
 */
export function looksLikePartNumber(text: string): boolean {
  return /^[A-Z]{2,}-[A-Z0-9]+$/.test(text)
}

/** A plain identifier column (job number, warehouse code, part number). */
export function readIdentifier(raw: unknown): { value: string | null; raw: string | null } {
  try {
    const text = cellToText(raw)
    if (text === null || isPlaceholder(text)) return { value: null, raw: text }
    return { value: text, raw: text }
  } catch (err) {
    if (err instanceof IdentifierCoercionError) return { value: null, raw: err.rendered }
    throw err
  }
}
