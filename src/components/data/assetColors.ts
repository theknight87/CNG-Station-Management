/** Colour helpers shared by the registry tables (kept out of component files for fast refresh). */

const REGION_DOT: Record<string, string> = {
  east: 'bg-blue-600', west: 'bg-purple-600', delta: 'bg-emerald-600',
  canal: 'bg-cyan-500', alex: 'bg-orange-500', upper: 'bg-stone-600',
}

export function regionDot(name: string): string {
  return REGION_DOT[name.trim().toLowerCase()] ?? 'bg-muted-foreground'
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
