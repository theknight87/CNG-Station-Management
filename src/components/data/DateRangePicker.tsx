import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react'
import { CalendarRange, ChevronLeft, ChevronRight, ChevronsLeft, ChevronsRight, X } from 'lucide-react'

import { DATE_PRESETS, addDays, hasDateRange, presetRange, rangeText, type DateOption, type DatePreset, type DateRange } from '@/components/data/dateRange'
import { cairoBusinessDate } from '@/features/reports/csv'
import { cn } from '@/lib/utils'

/**
 * One date filter per tab (owner request 2026-09-29): a single button that opens a calendar where From and To are
 * picked together — first click starts the range, second click ends it — with quick ranges and exact From/To boxes
 * for typing a far date. The parent owns the value, so the table, its counts and its export read the same range.
 */

const WEEKDAYS = ['Sa', 'Su', 'Mo', 'Tu', 'We', 'Th', 'Fr']

function monthOf(iso: string): string { return iso.slice(0, 7) }
function shiftMonth(ym: string, n: number): string {
  const [y, m] = ym.split('-').map(Number)
  const t = new Date(Date.UTC(y, m - 1 + n, 1))
  return t.toISOString().slice(0, 7)
}
function monthTitle(ym: string): string {
  const [y, m] = ym.split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, 1)).toLocaleDateString('en-GB', { month: 'long', year: 'numeric', timeZone: 'UTC' })
}
/** The days shown for a month, Saturday first, padded with the neighbouring months' days. */
function monthGrid(ym: string): string[] {
  const first = `${ym}-01`
  const [y, m] = ym.split('-').map(Number)
  const lead = (new Date(Date.UTC(y, m - 1, 1)).getUTCDay() + 1) % 7 // Saturday = 0
  const start = addDays(first, -lead)
  return Array.from({ length: 42 }, (_, i) => addDays(start, i))
}

export function DateRangePicker({ id, value, onChange, option }: {
  id: string
  value: DateRange
  onChange: (patch: DateRange) => void
  /** The date this tab filters by; its label names the button. */
  option: DateOption
}) {
  const today = cairoBusinessDate()
  const [open, setOpen] = useState(false)
  const [month, setMonth] = useState(monthOf(value.dateFrom || value.dateTo || today))
  const [alignRight, setAlignRight] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  const pop = useRef<HTMLDivElement>(null)
  const active = hasDateRange(value)
  const from = value.dateFrom, to = value.dateTo

  useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false) }
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => { document.removeEventListener('mousedown', onDown); document.removeEventListener('keydown', onKey) }
  }, [open])

  // Keep the calendar on screen: open it leftwards when it would run past the right edge.
  useLayoutEffect(() => {
    if (!open || !box.current || !pop.current) return
    const left = box.current.getBoundingClientRect().left
    setAlignRight(left + pop.current.offsetWidth > window.innerWidth - 8)
  }, [open])

  function pick(day: string) {
    if (!from || to) onChange({ dateFrom: day, dateTo: '' })
    else if (day < from) onChange({ dateFrom: day, dateTo: from })
    else onChange({ dateFrom: from, dateTo: day })
  }

  const lo = from && to && from > to ? to : from
  const hi = from && to && from > to ? from : to
  const input = 'h-7 w-full rounded border bg-background px-1.5 text-sm tabular text-foreground'

  return (
    <div ref={box} className="relative">
      <button type="button" id={`${id}-dates`} aria-haspopup="dialog" aria-expanded={open}
              onClick={() => { setOpen((o) => !o); setMonth(monthOf(from || to || today)) }}
              className={cn('inline-flex h-7 items-center gap-1.5 rounded border px-2 text-sm transition-colors',
                'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                active ? 'border-brand-strong bg-background text-foreground' : 'bg-background text-muted-foreground hover:text-foreground')}>
        <CalendarRange aria-hidden="true" className={cn('h-3.5 w-3.5', active && 'text-brand-strong')} />
        <span className="text-xs text-muted-foreground">{option.label}:</span>
        <span className={cn('tabular whitespace-nowrap', active && 'font-medium')}>{rangeText(value)}</span>
      </button>
      {active ? (
        <button type="button" aria-label={`Clear the ${option.label} dates`} title="Clear the dates"
                onClick={() => onChange({ dateFrom: '', dateTo: '' })}
                className="absolute -right-2 -top-2 inline-flex h-4 w-4 items-center justify-center rounded-full border bg-background text-muted-foreground shadow-sm hover:text-foreground">
          <X className="h-3 w-3" aria-hidden="true" />
        </button>
      ) : null}

      {open ? (
        <div ref={pop} role="dialog" aria-label={`${option.label} dates`}
             className={cn('absolute top-full z-40 mt-1 w-[18.5rem] max-w-[calc(100vw-1.5rem)] rounded-lg border bg-card p-2.5 text-card-foreground shadow-lg',
                           alignRight ? 'right-0' : 'left-0')}>
          <div className="mb-2 flex flex-wrap gap-1">
            {DATE_PRESETS.map((p) => (
              <button key={p.value} type="button" onClick={() => { const r = presetRange(p.value as DatePreset, today); onChange(r); setMonth(monthOf(r.dateFrom || r.dateTo)) }}
                      className="rounded-full border px-2 py-0.5 text-xs hover:border-brand-strong hover:text-brand-strong">
                {p.label}
              </button>
            ))}
          </div>

          <div className="flex items-center justify-between">
            <span className="flex">
              <NavBtn label="Previous year" onClick={() => setMonth(shiftMonth(month, -12))}><ChevronsLeft className="h-4 w-4" /></NavBtn>
              <NavBtn label="Previous month" onClick={() => setMonth(shiftMonth(month, -1))}><ChevronLeft className="h-4 w-4" /></NavBtn>
            </span>
            <span className="text-sm font-semibold" aria-live="polite">{monthTitle(month)}</span>
            <span className="flex">
              <NavBtn label="Next month" onClick={() => setMonth(shiftMonth(month, 1))}><ChevronRight className="h-4 w-4" /></NavBtn>
              <NavBtn label="Next year" onClick={() => setMonth(shiftMonth(month, 12))}><ChevronsRight className="h-4 w-4" /></NavBtn>
            </span>
          </div>
          <div className="mt-1 grid grid-cols-7 text-center text-[11px] font-medium text-muted-foreground" aria-hidden="true">
            {WEEKDAYS.map((d) => <span key={d} className="py-0.5">{d}</span>)}
          </div>
          <div className="grid grid-cols-7 gap-y-0.5">
            {monthGrid(month).map((day) => {
              const inMonth = monthOf(day) === month
              const edge = day === lo || day === hi
              const inside = lo && hi && day > lo && day < hi
              return (
                <button key={day} type="button" aria-label={day} aria-pressed={edge || Boolean(inside)} onClick={() => pick(day)}
                        className={cn('h-7 text-xs tabular transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring',
                          edge ? 'rounded bg-brand-strong font-semibold text-brand-strong-fg'
                            : inside ? 'bg-muted text-foreground' : 'rounded hover:bg-muted',
                          !edge && !inside && (inMonth ? 'text-foreground' : 'text-muted-foreground/50'),
                          day === today && !edge && 'font-bold underline underline-offset-2')}>
                  {Number(day.slice(8))}
                </button>
              )
            })}
          </div>

          <div className="mt-2 grid grid-cols-2 gap-2 border-t pt-2">
            <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-datefrom`}>
              From
              <input id={`${id}-datefrom`} type="date" className={input} value={from}
                     onChange={(e) => { onChange({ dateFrom: e.target.value, dateTo: to }); if (e.target.value) setMonth(monthOf(e.target.value)) }} />
            </label>
            <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-dateto`}>
              To
              <input id={`${id}-dateto`} type="date" className={input} value={to}
                     onChange={(e) => { onChange({ dateFrom: from, dateTo: e.target.value }); if (e.target.value) setMonth(monthOf(e.target.value)) }} />
            </label>
          </div>
          <div className="mt-2 flex items-center justify-between">
            <button type="button" className="text-xs text-muted-foreground hover:text-foreground disabled:opacity-40" disabled={!active}
                    onClick={() => onChange({ dateFrom: '', dateTo: '' })}>Clear</button>
            <button type="button" className="rounded bg-brand-strong px-3 py-1 text-xs font-medium text-brand-strong-fg" onClick={() => setOpen(false)}>Done</button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

function NavBtn({ label, onClick, children }: { label: string; onClick: () => void; children: ReactNode }) {
  return (
    <button type="button" aria-label={label} title={label} onClick={onClick}
            className="inline-flex h-7 w-7 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground">
      {children}
    </button>
  )
}
