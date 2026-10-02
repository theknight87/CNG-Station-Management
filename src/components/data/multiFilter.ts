/**
 * Multi-choice filters (owner request 2026-10-02): a filter may hold SEVERAL values, and may EXCLUDE them instead of
 * keeping only them — "overdue, every manufacturer except EKC".
 *
 * The choice is stored as one string so every existing query object keeps its shape:
 *   ''  (or 'all')      every row
 *   'a|b'               only rows whose column is a or b
 *   '!a|b'              every row EXCEPT a and b — rows with nothing recorded are kept, they are not a or b
 * A token may be an alias for a group (the due filter's legacy 'attention' = overdue up to 30 days), so values the
 * summary tiles already set keep their meaning.
 */

export interface MultiChoice {
  values: string[]
  exclude: boolean
}

export type MultiAliases = Record<string, readonly string[]>

const SEP = '|'

export function parseMulti(raw: string | null | undefined, aliases: MultiAliases = {}): MultiChoice {
  if (!raw || raw === 'all') return { values: [], exclude: false }
  const exclude = raw.startsWith('!')
  const values: string[] = []
  for (const token of (exclude ? raw.slice(1) : raw).split(SEP)) {
    if (!token || token === 'all') continue
    for (const v of aliases[token] ?? [token]) if (!values.includes(v)) values.push(v)
  }
  return { values, exclude: values.length > 0 && exclude }
}

/** The stored form; `empty` is what "every row" is called by the caller ('' or 'all'). */
export function encodeMulti(choice: MultiChoice, empty = ''): string {
  if (choice.values.length === 0) return empty
  return (choice.exclude ? '!' : '') + choice.values.join(SEP)
}

export function hasMulti(raw: string | null | undefined): boolean {
  return parseMulti(raw).values.length > 0
}

/** Quoted for PostgREST's list and logic grammar, so a value with a space or comma stays one value. */
function quote(v: string): string {
  return `"${v.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Filterable = { eq: (col: string, value: any) => any; ilike: (col: string, pattern: string) => any; in: (col: string, values: any[]) => any; or: (expr: string) => any }

/**
 * Applies a multi-choice to a PostgREST builder. Exact match by default; `caseInsensitive` matches the way a typed
 * name is compared (manufacturer: 'ekc' is EKC). An exclusion keeps rows where the column is not recorded.
 */
export function applyMulti<B extends Filterable>(b: B, column: string, raw: string | null | undefined,
  opts: { aliases?: MultiAliases; caseInsensitive?: boolean } = {}): B {
  const { values, exclude } = parseMulti(raw, opts.aliases)
  if (values.length === 0) return b
  // One chosen value is the plain comparison it always was.
  if (!exclude && values.length === 1) {
    return opts.caseInsensitive ? b.ilike(column, values[0].replace(/[%*,()]/g, ' ').trim()) : b.eq(column, values[0])
  }
  if (opts.caseInsensitive) {
    if (!exclude) return b.or(values.map((v) => `${column}.ilike.${quote(v)}`).join(','))
    return b.or(`${column}.is.null,and(${values.map((v) => `${column}.not.ilike.${quote(v)}`).join(',')})`)
  }
  if (!exclude) return b.in(column, values)
  return b.or(`${column}.is.null,${column}.not.in.(${values.map(quote).join(',')})`)
}

/** The same test in the browser, for screens that filter rows they already hold. */
export function matchesMulti(value: string | null | undefined, raw: string | null | undefined, aliases: MultiAliases = {}): boolean {
  const { values, exclude } = parseMulti(raw, aliases)
  if (values.length === 0) return true
  const hit = value != null && values.includes(value)
  return exclude ? !hit : hit
}

/** The due-status choices every registry offers, in severity order; 'attention' is the ≤30-day group of the tiles. */
export const DUE_OPTIONS = [
  { value: 'overdue', label: 'Overdue' },
  { value: 'due_today', label: 'Due today' },
  { value: 'due_7', label: 'Due ≤7d' },
  { value: 'due_15', label: 'Due ≤15d' },
  { value: 'due_30', label: 'Due ≤30d' },
  { value: 'due_60', label: 'Due ≤60d' },
  { value: 'valid', label: 'Valid' },
  { value: 'unknown', label: 'No exact date' },
] as const

export const DUE_ALIASES: MultiAliases = {
  attention: ['overdue', 'due_today', 'due_7', 'due_15', 'due_30'],
}
