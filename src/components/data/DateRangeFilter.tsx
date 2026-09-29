import { CalendarRange, X } from 'lucide-react'

import { DATE_PRESETS, dateOptionFor, hasDateRange, presetRange, type DateOption, type DatePreset, type DateRange } from '@/components/data/dateRange'
import { cn } from '@/lib/utils'

const input = 'h-7 rounded border bg-background px-2 text-sm text-foreground'
const label = 'flex flex-col gap-0.5 text-xs text-muted-foreground'

/**
 * Date filter for a registry or workflow tab (owner request 2026-09-29): which date, From, To, a quick range, clear.
 * The browser's own date picker opens on From and To. The parent owns the value, so the table, its counts and its
 * export all read the same range.
 */
export function DateRangeFilter({ id, value, onChange, options }: {
  id: string
  value: DateRange
  onChange: (patch: Partial<DateRange>) => void
  options: DateOption[]
}) {
  if (options.length === 0) return null
  const current = dateOptionFor(value, options)
  const active = hasDateRange(value)
  // The chosen column is written with the dates so the range never applies to a different date than the one shown.
  const setDates = (patch: Pick<DateRange, 'dateFrom' | 'dateTo'> | Partial<DateRange>) =>
    onChange({ dateField: current?.column ?? '', ...patch })
  return (
    <div role="group" aria-label="Filter by date"
         className={cn('flex flex-wrap items-end gap-2 rounded-md border border-dashed px-2 pb-1.5 pt-1',
                       active ? 'border-solid border-brand-strong bg-card' : 'border-border')}>
      <CalendarRange aria-hidden="true" className={cn('mb-1.5 h-4 w-4', active ? 'text-brand-strong' : 'text-muted-foreground')} />
      {options.length > 1 ? (
        <label className={label} htmlFor={`${id}-datefield`}>
          Date
          <select id={`${id}-datefield`} className={cn(input, 'px-1.5')} value={current?.column ?? ''}
                  onChange={(e) => onChange({ dateField: e.target.value })}>
            {options.map((o) => <option key={o.column} value={o.column}>{o.label}</option>)}
          </select>
        </label>
      ) : (
        <span className="mb-1.5 text-xs font-medium text-muted-foreground">{options[0].label}</span>
      )}
      <label className={label} htmlFor={`${id}-datefrom`}>
        From
        <input id={`${id}-datefrom`} type="date" className={cn(input, 'w-36 tabular')} value={value.dateFrom}
               max={value.dateTo || undefined} onChange={(e) => setDates({ dateFrom: e.target.value })} />
      </label>
      <label className={label} htmlFor={`${id}-dateto`}>
        To
        <input id={`${id}-dateto`} type="date" className={cn(input, 'w-36 tabular')} value={value.dateTo}
               min={value.dateFrom || undefined} onChange={(e) => setDates({ dateTo: e.target.value })} />
      </label>
      <label className={label} htmlFor={`${id}-datepreset`}>
        Quick
        <select id={`${id}-datepreset`} className={cn(input, 'px-1.5')} value=""
                onChange={(e) => { if (e.target.value) setDates(presetRange(e.target.value as DatePreset)) }}>
          <option value="">Choose…</option>
          {DATE_PRESETS.map((p) => <option key={p.value} value={p.value}>{p.label}</option>)}
        </select>
      </label>
      {active ? (
        <button type="button" aria-label="Clear the date filter" title="Clear the date filter"
                className="mb-0.5 inline-flex h-6 w-6 items-center justify-center rounded text-muted-foreground hover:bg-muted hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                onClick={() => onChange({ dateFrom: '', dateTo: '' })}>
          <X className="h-3.5 w-3.5" aria-hidden="true" />
        </button>
      ) : null}
    </div>
  )
}
