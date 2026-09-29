import { useEffect, useId, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { Info } from 'lucide-react'

import { cn } from '@/lib/utils'

/**
 * An explanation kept out of the way (owner request 2026-09-29): only a small (i) shows; the text opens when it is
 * clicked (or focused and Enter/Space pressed) and closes on a second click, a click elsewhere or Escape.
 */
export function InfoTip({ label, children, className }: {
  /** What the (i) explains, for screen readers ("About the SRV Log"). */
  label: string
  children: ReactNode
  className?: string
}) {
  const [open, setOpen] = useState(false)
  const [alignRight, setAlignRight] = useState(false)
  const box = useRef<HTMLSpanElement>(null)
  const pop = useRef<HTMLSpanElement>(null)
  const id = useId()

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey) }
  }, [open])

  // Stay on screen: open leftwards when the text would run past the right edge.
  useLayoutEffect(() => {
    if (!open || !box.current || !pop.current) return
    setAlignRight(box.current.getBoundingClientRect().left + pop.current.offsetWidth > window.innerWidth - 8)
  }, [open])

  return (
    <span ref={box} className={cn('relative inline-flex align-middle', className)}>
      <button type="button" aria-label={label} title={label} aria-expanded={open} aria-controls={open ? id : undefined}
              onClick={() => setOpen((o) => !o)}
              className={cn('inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full transition-colors',
                'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                open ? 'bg-brand-strong text-brand-strong-fg' : 'text-muted-foreground hover:bg-muted hover:text-foreground')}>
        <Info className="h-4 w-4" aria-hidden="true" />
      </button>
      {open ? (
        <span ref={pop} id={id} role="note"
              className={cn('absolute top-full z-40 mt-1 w-72 max-w-[calc(100vw-1.5rem)] rounded-md border bg-card px-3 py-2 text-left text-sm font-normal leading-snug text-card-foreground shadow-lg',
                            alignRight ? 'right-0' : 'left-0')}>
          {children}
        </span>
      ) : null}
    </span>
  )
}
