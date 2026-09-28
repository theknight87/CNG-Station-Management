import type { AssetFilters } from '@/components/data/assetFilters'
import { cn } from '@/lib/utils'

const input = 'h-7 rounded border bg-background px-2 text-sm'

/** Serial, Station, manufacturer and (optionally) pressure-range filters, laid out like the SRV screens. */
export function AssetFilterBar({ id, value, onChange, makers, pressureLabel }: {
  id: string
  value: AssetFilters
  onChange: (next: AssetFilters) => void
  /** Manufacturer choices; omit to hide the manufacturer filter (no data to filter on). */
  makers?: string[]
  /** Label of the pressure filter; omit to hide it. */
  pressureLabel?: string
}) {
  const set = (patch: Partial<AssetFilters>) => onChange({ ...value, ...patch })
  const label = 'flex flex-col gap-0.5 text-xs text-muted-foreground'
  return (
    <div role="group" aria-label="Filter by serial, station, manufacturer and pressure" className="flex flex-wrap items-end gap-2">
      <label className={label} htmlFor={`${id}-serial`}>
        Serial
        <input id={`${id}-serial`} className={cn(input, 'w-36 font-technical')} value={value.serial}
               placeholder="contains…" onChange={(e) => set({ serial: e.target.value })} />
      </label>
      <label className={label} htmlFor={`${id}-station`}>
        Station
        <input id={`${id}-station`} dir="auto" className={cn(input, 'w-44')} value={value.station}
               placeholder="name contains…" onChange={(e) => set({ station: e.target.value })} />
      </label>
      {makers ? (
        <label className={label} htmlFor={`${id}-maker`}>
          Manufacturer
          <select id={`${id}-maker`} className={cn(input, 'px-1.5 text-foreground')} value={value.maker}
                  onChange={(e) => set({ maker: e.target.value })}>
            <option value="">All</option>
            {makers.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
        </label>
      ) : null}
      {pressureLabel ? (
        <>
          <label className={label} htmlFor={`${id}-pressure`}>
            {pressureLabel}
            <input id={`${id}-pressure`} inputMode="decimal" className={cn(input, 'w-28 text-right tabular')} value={value.pressure}
                   title="One value (30) or a range (30-35)" placeholder="30 or 30-35"
                   onChange={(e) => set({ pressure: e.target.value.replace(/[^\d.\-– ]/g, '') })} />
          </label>
          <label className={label} htmlFor={`${id}-unit`}>
            Unit
            <select id={`${id}-unit`} className={cn(input, 'px-1.5 text-foreground')} value={value.pressureUnit}
                    onChange={(e) => set({ pressureUnit: e.target.value as AssetFilters['pressureUnit'] })}>
              <option value="">Any</option>
              <option value="BAR">BAR</option>
              <option value="PSI">PSI</option>
            </select>
          </label>
        </>
      ) : null}
    </div>
  )
}
