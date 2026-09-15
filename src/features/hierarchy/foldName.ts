/**
 * Search-only name folding.
 *
 * Mirrors the SQL `cng_normalize_name()` (migration 0028) so a query typed with
 * one spelling matches a station stored with another - taa marbuta against
 * haa, the hamzated alefs against bare alef, alef maqsura against yaa -
 * without the server having to fold the search term on every keystroke.
 *
 * IT IS A SEARCH AID AND NOTHING ELSE. It never decides that two names are the
 * same Station, never creates an alias, and never writes anything. Canonical
 * identity is decided in PostgreSQL by the generated `normalized_name` column
 * and the unique constraints over it; resolving an unmatched name is a human
 * decision recorded in `station_aliases` (CLAUDE.md section 8). A false
 * positive here shows an engineer one extra row; it cannot merge two Stations.
 *
 * Written as code-point lookups rather than a regular expression: a character
 * class of adjacent Arabic combining marks is genuinely ambiguous (eslint's
 * no-misleading-character-class says so, and it is right), and a table of code
 * points states exactly which characters are meant.
 */

/** Tatweel and the Arabic diacritics. They carry no identity, so they go. */
const STRIPPED = new Set([
  0x0640, // tatweel
  0x064b, 0x064c, 0x064d, // tanween
  0x064e, 0x064f, 0x0650, // short vowels
  0x0651, // shadda
  0x0652, // sukun
  0x0670, // superscript alef
  0x0653, // madda above
])

/** Orthographic variants that are the same letter for matching purposes. */
const FOLDED = new Map([
  [0x0623, "\u0627"], // alef with hamza above -> alef
  [0x0625, "\u0627"], // alef with hamza below -> alef
  [0x0622, "\u0627"], // alef with madda      -> alef
  [0x0671, "\u0627"], // alef wasla           -> alef
  [0x0649, "\u064a"], // alef maqsura         -> yaa
  [0x0629, "\u0647"], // taa marbuta          -> haa
])

export function foldName(value: string): string {
  let out = ""
  // Iterating the string yields whole code points, so an astral character is
  // never split in half on the way through.
  for (const ch of value.normalize("NFKC").toLowerCase()) {
    const code = ch.codePointAt(0)
    if (code === undefined || STRIPPED.has(code)) continue
    out += FOLDED.get(code) ?? ch
  }
  // Collapse runs of whitespace, then trim - same order as the SQL.
  return out.replace(/\s+/g, " ").trim()
}
