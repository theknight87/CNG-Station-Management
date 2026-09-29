import { cn } from '@/lib/utils'

/** Classes of one tab, shared with the button tabs of a dialog so both look the same. */
export function sectionTabClass(active: boolean, compact = false): string {
  return cn(
    'group relative flex shrink-0 select-none items-center gap-2 whitespace-nowrap rounded-md text-left transition-[background-color,color,box-shadow,transform] duration-150',
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 active:scale-[0.98]',
    compact ? 'min-h-9 px-3 py-1.5' : 'min-h-11 px-3.5 py-2',
    // The brand underline of the active tab; transparent on the others so the height never jumps.
    'after:absolute after:inset-x-3 after:bottom-0 after:h-[3px] after:rounded-full after:transition-colors',
    active
      ? 'bg-background text-foreground shadow-sm ring-1 ring-border after:bg-brand-strong'
      : 'text-muted-foreground after:bg-transparent hover:bg-background/70 hover:text-foreground hover:shadow-sm',
  )
}


/** The strip's frame: a recessed track the raised active tab sits in. Scrolls sideways rather than wrapping. */
export const sectionTabTrack = 'scrollbar-none flex w-full max-w-full items-stretch gap-1 overflow-x-auto rounded-lg border bg-muted/60 p-1'
