import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { ChevronDown, Search, X } from 'lucide-react'

import { encodeMulti, parseMulti, type MultiAliases } from '@/components/data/multiFilter'
import { cn } from '@/lib/utils'

export interface MultiOption {
  value: string
  label: string
}

/**
 * A filter that holds several values and can exclude them (owner request 2026-10-02). One button in the toolbar
 * shows what is chosen ("Manufacturer: All except EKC"); it opens a short list of checkboxes with a switch between
 * "Only these" and "All except". The value is the encoded string of `multiFilter.ts`, so the page's query, its
 * counts and its export all read the same choice.
 */
export function MultiSelectFilter({ id, label, value, onChange, options, aliases, empty = '', allLabel = 'All' }: {
  id: string
  label: string
  value: string | null | undefined
  onChange: (next: string) => void
  options: readonly MultiOption[]
  /** Group tokens a stored value may carry (the due tiles' 'attention'). */
  aliases?: MultiAliases
  /** What "every row" is stored as on this page ('' or 'all'). */
  empty?: string
  allLabel?: string
}) {
  const [open, setOpen] = useState(false)
  const [find, setFind] = useState('')
  const [alignRight, setAlignRight] = useState(false)
  // The mode picked before any value is ticked; once something is chosen the stored value carries it.
  const [pendingExclude, setPendingExclude] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  const pop = useRef<HTMLDivElement>(null)
  const choice = parseMulti(value, aliases)
  const active = choice.values.length > 0
  const exclude = active ? choice.exclude : pendingExclude
  const nameOf = (v: string) => options.find((o) => o.value === v)?.label ?? v

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey) }
  }, [open])

  useLayoutEffect(() => {
    if (!open || !box.current || !pop.current) return
    setAlignRight(box.current.getBoundingClientRect().left + pop.current.offsetWidth > window.innerWidth - 8)
  }, [open])

  const emit = (values: string[], exclude: boolean) =>
    // Keep the options' own order, so the same choice is always stored the same way.
    onChange(encodeMulti({ values: options.map((o) => o.value).filter((v) => values.includes(v))
      .concat(values.filter((v) => !options.some((o) => o.value === v))), exclude }, empty))
  const toggle = (v: string) =>
    emit(choice.values.includes(v) ? choice.values.filter((x) => x !== v) : [...choice.values, v], exclude)

  const first = choice.values[0] ? nameOf(choice.values[0]) : ''
  const more = choice.values.length > 1 ? ` +${choice.values.length - 1}` : ''
  const summary = !active ? allLabel : choice.exclude ? `All except ${first}${more}` : `${first}${more}`
  const shown = find.trim()
    ? options.filter((o) => o.label.toLowerCase().includes(find.trim().toLowerCase()))
    : options

  return (
    <div ref={box} className="relative">
      <button type="button" id={id} aria-haspopup="dialog" aria-expanded={open} title={active ? `${label}: ${summary}` : undefined}
              onClick={() => { setOpen((o) => !o); setFind('') }}
              className={cn('inline-flex h-7 max-w-[16rem] items-center gap-1.5 rounded border bg-background px-2 text-sm transition-colors',
                'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                active ? 'border-brand-strong text-foreground' : 'text-muted-foreground hover:text-foreground')}>
        <span className="shrink-0 text-xs text-muted-foreground">{label}:</span>
        <span dir="auto" className={cn('truncate', active && 'font-medium')}>{summary}</span>
        <ChevronDown className="h-3.5 w-3.5 shrink-0" aria-hidden="true" />
      </button>
      {active ? (
        <button type="button" aria-label={`Clear the ${label} filter`} title={`Clear the ${label} filter`}
                onClick={() => onChange(empty)}
                className="absolute -right-2 -top-2 inline-flex h-4 w-4 items-center justify-center rounded-full border bg-background text-muted-foreground shadow-sm hover:text-foreground">
          <X className="h-3 w-3" aria-hidden="true" />
        </button>
      ) : null}

      {open ? (
        <div ref={pop} role="dialog" aria-label={`${label} filter`}
             className={cn('absolute top-full z-40 mt-1 w-60 max-w-[calc(100vw-1.5rem)] rounded-lg border bg-card p-2 text-card-foreground shadow-lg',
                           alignRight ? 'right-0' : 'left-0')}>
          <div role="group" aria-label="Match" className="mb-2 grid grid-cols-2 rounded border p-0.5 text-xs">
            {([false, true] as const).map((ex) => (
              <button key={String(ex)} type="button" aria-pressed={exclude === ex}
                      onClick={() => { setPendingExclude(ex); if (active) emit(choice.values, ex) }}
                      className={cn('rounded px-2 py-1 font-medium',
                        exclude === ex ? 'bg-brand-strong text-brand-strong-fg' : 'text-muted-foreground hover:text-foreground')}>
                {ex ? 'All except' : 'Only these'}
              </button>
            ))}
          </div>
          {options.length > 10 ? (
            <label className="relative mb-1.5 flex items-center">
              <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
              <span className="sr-only">Find a {label}</span>
              <input type="search" value={find} onChange={(e) => setFind(e.target.value)} dir="auto" placeholder="Find…"
                     className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground" />
            </label>
          ) : null}
          <ul className="max-h-64 overflow-y-auto">
            {shown.map((o) => (
              <li key={o.value}>
                <label className="flex cursor-pointer items-center gap-2 rounded px-1.5 py-1 text-sm hover:bg-muted">
                  <input type="checkbox" checked={choice.values.includes(o.value)} onChange={() => toggle(o.value)}
                         className="h-3.5 w-3.5 accent-brand-strong" />
                  <span dir="auto">{o.label}</span>
                </label>
              </li>
            ))}
            {shown.length === 0 ? <li className="px-1.5 py-1 text-sm text-muted-foreground">No match</li> : null}
          </ul>
          <div className="mt-1.5 flex justify-between border-t pt-1.5 text-xs">
            <span className="text-muted-foreground">{active ? `${choice.values.length} chosen` : 'Nothing chosen: all shown'}</span>
            <button type="button" onClick={() => onChange(empty)} disabled={!active}
                    className="font-medium text-brand-strong hover:underline disabled:text-muted-foreground disabled:no-underline">
              Clear
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}
