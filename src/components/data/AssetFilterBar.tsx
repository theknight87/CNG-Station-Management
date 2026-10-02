import type { AssetFilters } from '@/components/data/assetFilters'
import { DateRangePicker } from '@/components/data/DateRangePicker'
import { PressureFilter } from '@/components/data/FilterControls'
import type { DateOption } from '@/components/data/dateRange'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'

/**
 * The registry filters of Vessels, Gas Detectors and Hoses, drawn INSIDE the page's toolbar beside its search:
 * manufacturer, pressure (value or range, with its unit) and the tab's date range. Serial and Station are not
 * repeated here — the search box already finds both.
 */
export function AssetFilterBar({ id, value, onChange, makers, pressureLabel, date }: {
  id: string
  value: AssetFilters
  onChange: (next: AssetFilters) => void
  /** Manufacturer choices; omit to hide the manufacturer filter (no data to filter on). */
  makers?: string[]
  /** Label of the pressure filter; omit to hide it. */
  pressureLabel?: string
  /** The date this registry can be filtered by; omit for no date filter. */
  date?: DateOption
}) {
  const set = (patch: Partial<AssetFilters>) => onChange({ ...value, ...patch })
  return (
    <>
      {makers ? (
        <MultiSelectFilter id={`${id}-maker`} label="Manufacturer" value={value.maker} onChange={(maker) => set({ maker })}
                           options={makers.map((m) => ({ value: m, label: m }))} />
      ) : null}
      {pressureLabel ? (
        <PressureFilter id={id} label={pressureLabel} value={value.pressure} unit={value.pressureUnit}
                        onChange={(p) => set({ ...(p.value !== undefined ? { pressure: p.value } : {}), ...(p.unit !== undefined ? { pressureUnit: p.unit } : {}) })} />
      ) : null}
      {date ? <DateRangePicker id={id} value={value} onChange={set} option={date} /> : null}
    </>
  )
}
