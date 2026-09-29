import { NullValue } from '@/components/data/NullValue'
import { cn } from '@/lib/utils'
import { chipTone, regionTone } from '@/components/data/assetColors'

/**
 * Owner request 2026-09-28: colour so the eye tells regions and manufacturers apart. The text is always shown, so
 * colour is never the only signal; red and amber stay reserved for due status.
 */

/**
 * Region: a tinted pill with a dot, in the Region's own colour — the same on every screen (owner request
 * 2026-09-29). Its rounded pill shape is its own, so it never reads as a manufacturer (square, filled) or a status.
 */
export function RegionChip({ name, size = 'sm' }: { name: string | null; size?: 'sm' | 'md' }) {
  if (!name) return <NullValue />
  const tone = regionTone(name)
  return (
    <span className={cn('inline-flex items-center gap-1.5 whitespace-nowrap rounded-full border font-semibold', tone.chip,
                        size === 'md' ? 'px-2.5 py-0.5 text-sm' : 'px-2 py-px text-xs')}>
      <span aria-hidden="true" className={cn('shrink-0 rounded-full', tone.dot, size === 'md' ? 'h-2.5 w-2.5' : 'h-2 w-2')} />
      {name}
    </span>
  )
}

/** Just the Region's dot, for tight spots (a filter option row, a legend). */
export function RegionDot({ name, className }: { name: string | null; className?: string }) {
  return <span aria-hidden="true" className={cn('inline-block h-2.5 w-2.5 shrink-0 rounded-full', regionTone(name).dot, className)} />
}

/** Manufacturer (or any maker name): a filled chip, the same name always the same colour. */
export function MakerChip({ value }: { value: string | null }) {
  if (!value || !value.trim()) return <NullValue />
  return (
    <span dir="auto" className={cn('inline-flex items-center whitespace-nowrap rounded px-1.5 py-0.5 text-xs font-semibold', chipTone(value))}>
      {value.replace(/\s+/g, ' ').trim()}
    </span>
  )
}
