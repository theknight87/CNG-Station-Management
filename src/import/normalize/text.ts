/**
 * Text normalization used to PROPOSE matches. It never resolves anything on
 * its own (CLAUDE.md §8: "Normalization may propose an alias; it never creates
 * one silently").
 */

/** Arabic presentation/diacritic marks that carry no identity information. */
const TASHKEEL = /[ؐ-ًؚ-ٰٟۖ-ۭ]/g
const TATWEEL = /ـ/g

/**
 * NFKC, whitespace collapse, Arabic letter folding. The result is a COMPARISON
 * KEY only. It is never stored as a name and never written to a canonical row.
 */
export function normalizeName(input: string): string {
  return input
    .normalize('NFKC')
    .replace(TASHKEEL, '')
    .replace(TATWEEL, '')
    .replace(/[أإآٱ]/g, 'ا')
    .replace(/ى/g, 'ي')
    .replace(/ة/g, 'ه')
    .replace(/‏|‎/g, '')
    .replace(/\s+/g, ' ')
    .trim()
    .toLowerCase()
}

/**
 * Splits `<base> <n>` into its parts — decision D2, e.g. `الخمائل 2`.
 *
 * This RECOGNIZES the shape. It does not act on it: the caller may only turn it
 * into a proposal for a human to confirm, never into a resolution.
 */
export function splitNumberedName(input: string): { base: string; index: number } | null {
  const m = input.trim().match(/^(.*\S)\s+(\d{1,2})$/)
  if (!m) return null
  return { base: m[1].trim(), index: Number(m[2]) }
}

/** Dice coefficient over bigrams. Advisory scoring for review only. */
export function similarity(a: string, b: string): number {
  const na = normalizeName(a)
  const nb = normalizeName(b)
  if (na === nb) return 1
  if (na.length < 2 || nb.length < 2) return 0

  const bigrams = (s: string) => {
    const out = new Map<string, number>()
    for (let i = 0; i < s.length - 1; i++) {
      const g = s.slice(i, i + 2)
      out.set(g, (out.get(g) ?? 0) + 1)
    }
    return out
  }

  const A = bigrams(na)
  const B = bigrams(nb)
  let shared = 0
  for (const [g, countA] of A) shared += Math.min(countA, B.get(g) ?? 0)

  const total = [...A.values()].reduce((s, n) => s + n, 0) + [...B.values()].reduce((s, n) => s + n, 0)
  return total === 0 ? 0 : (2 * shared) / total
}
