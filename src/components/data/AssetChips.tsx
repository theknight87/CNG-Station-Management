import { NullValue } from '@/components/data/NullValue'
import { cn } from '@/lib/utils'
import { chipTone, regionDot } from '@/components/data/assetColors'

/**
 * Owner request 2026-09-28: colour so the eye tells regions and manufacturers apart. The text is always shown, so
 * colour is never the only signal; red and amber stay reserved for due status.
 */

/** Region: a coloured dot beside the name (its own shape, so it never reads as a manufacturer or a status). */
export function RegionChip({ name }: { name: string | null }) {
  if (!name) return <NullValue />
  return (
    <span className="inline-flex items-center gap-1.5 whitespace-nowrap font-medium">
      <span aria-hidden="true" className={cn('h-2.5 w-2.5 shrink-0 rounded-full', regionDot(name))} />
      {name}
    </span>
  )
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
