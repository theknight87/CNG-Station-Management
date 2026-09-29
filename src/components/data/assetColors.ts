/** Colour helpers shared by the registry tables (kept out of component files for fast refresh). */

/**
 * One colour per Region, the same everywhere in the product (owner request 2026-09-29). The hues are kept away from
 * the due-status red and amber and from the brand/"ok" green, so a Region never reads as a status. Every class is a
 * literal so Tailwind keeps it.
 */
export interface RegionTone {
  /** Small solid marker. */
  dot: string
  /** Tinted pill: border, background and text, light and dark. */
  chip: string
  /** Left edge of a row or a header. */
  stripe: string
}

const REGION_TONE: Record<string, RegionTone> = {
  east: {
    dot: 'bg-blue-600',
    chip: 'border-blue-300 bg-blue-50 text-blue-800 dark:border-blue-700 dark:bg-blue-950 dark:text-blue-200',
    stripe: 'border-l-blue-600',
  },
  west: {
    dot: 'bg-violet-600',
    chip: 'border-violet-300 bg-violet-50 text-violet-800 dark:border-violet-700 dark:bg-violet-950 dark:text-violet-200',
    stripe: 'border-l-violet-600',
  },
  canal: {
    dot: 'bg-cyan-500',
    chip: 'border-cyan-400 bg-cyan-50 text-cyan-800 dark:border-cyan-700 dark:bg-cyan-950 dark:text-cyan-200',
    stripe: 'border-l-cyan-500',
  },
  delta: {
    dot: 'bg-teal-700',
    chip: 'border-teal-600 bg-teal-100 text-teal-900 dark:border-teal-700 dark:bg-teal-950 dark:text-teal-200',
    stripe: 'border-l-teal-700',
  },
  alex: {
    dot: 'bg-fuchsia-600',
    chip: 'border-fuchsia-300 bg-fuchsia-50 text-fuchsia-800 dark:border-fuchsia-700 dark:bg-fuchsia-950 dark:text-fuchsia-200',
    stripe: 'border-l-fuchsia-600',
  },
  upper: {
    dot: 'bg-stone-600',
    chip: 'border-stone-300 bg-stone-100 text-stone-800 dark:border-stone-600 dark:bg-stone-900 dark:text-stone-200',
    stripe: 'border-l-stone-600',
  },
}

const NEUTRAL_REGION: RegionTone = {
  dot: 'bg-muted-foreground',
  chip: 'border-border bg-muted text-foreground',
  stripe: 'border-l-border',
}

export function regionTone(name: string | null | undefined): RegionTone {
  return (name && REGION_TONE[name.trim().toLowerCase()]) || NEUTRAL_REGION
}

export function regionDot(name: string): string {
  return regionTone(name).dot
}

/** Solid fills on hues far apart. Known SRV makers keep their agreed colour; others take a stable pick. */
const PALETTE = [
  'bg-blue-700 text-white', 'bg-purple-700 text-white', 'bg-teal-600 text-white', 'bg-orange-500 text-black',
  'bg-pink-600 text-white', 'bg-yellow-300 text-black', 'bg-lime-500 text-black', 'bg-stone-600 text-white',
  'bg-slate-900 text-white', 'bg-cyan-300 text-black', 'bg-indigo-500 text-white', 'bg-fuchsia-300 text-black',
  'bg-emerald-800 text-white', 'bg-sky-300 text-black', 'bg-violet-300 text-black', 'bg-zinc-400 text-black',
]
const FIXED: Record<string, number> = {
  technical: 0, mercer: 1, 'dk-lok': 2, coi: 3, anderson: 4, ekc: 5, farinola: 6, taylor: 7, aspro: 8, takei: 9,
}

export function makerKey(value: string): string {
  return value.replace(/\s+/g, ' ').trim().toLowerCase()
}

export function chipTone(value: string): string {
  const k = makerKey(value)
  if (k in FIXED) return PALETTE[FIXED[k]]
  let h = 0
  for (const ch of k) h = (h * 31 + ch.charCodeAt(0)) >>> 0
  return PALETTE[h % PALETTE.length]
}
