import { Search } from 'lucide-react'

import { filterControl, filterLabel } from '@/components/data/filterStyles'
import { cn } from '@/lib/utils'

/** The one free-text search of a tab: it covers serial, codes, manufacturer and Station, so no separate box repeats it. */
export function SearchBox({ id, value, onChange, placeholder, label }: {
  id: string
  value: string
  onChange: (v: string) => void
  placeholder: string
  /** Screen-reader name. */
  label: string
}) {
  return (
    <label className="relative flex min-w-40 flex-1 items-center sm:max-w-xs" htmlFor={id}>
      <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
      <span className="sr-only">{label}</span>
      <input id={id} name={id} type="search" value={value} onChange={(e) => onChange(e.target.value)} placeholder={placeholder}
             dir="auto" className={cn(filterControl, 'w-full pl-7 pr-2')} />
    </label>
  )
}

/**
 * A pressure as one value (30) or a range (30-35), with its unit in the same control — one filter, not two, so the
 * word "Unit" is never mistaken for a station Unit.
 */
export function PressureFilter({ id, label, value, unit, onChange }: {
  id: string
  label: string
  value: string
  unit: '' | 'BAR' | 'PSI'
  onChange: (patch: { value?: string; unit?: '' | 'BAR' | 'PSI' }) => void
}) {
  return (
    <span className={filterLabel}>
      <label htmlFor={`${id}-pressure`}>{label}</label>
      <span className="inline-flex">
        <input id={`${id}-pressure`} inputMode="decimal" className={cn(filterControl, 'w-28 rounded-r-none px-2 text-right tabular')}
               value={value} title="One value (30) or a range (30-35)" placeholder="30 or 30-35"
               onChange={(e) => onChange({ value: e.target.value.replace(/[^\d.\-– ]/g, '') })} />
        <select id={`${id}-unit`} aria-label={`${label} unit`} className={cn(filterControl, '-ml-px rounded-l-none')} value={unit}
                onChange={(e) => onChange({ unit: e.target.value as '' | 'BAR' | 'PSI' })}>
          <option value="">Any unit</option>
          <option value="BAR">BAR</option>
          <option value="PSI">PSI</option>
        </select>
      </span>
    </span>
  )
}
