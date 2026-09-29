import type { ReactNode } from 'react'

import { RegionChip } from '@/components/data/AssetChips'
import { DateRangeFilter } from '@/components/data/DateRangeFilter'
import type { DateOption } from '@/components/data/dateRange'
import { StatusBadge } from '@/components/data/StatusBadge'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { cn } from '@/lib/utils'
import { TONE, type ToneName } from '@/features/relief-valves/srvSort'
import { useRegions } from '@/features/admin/useMappingOptions'
import type { InstalledSrvRow, SrvSmartFilters } from '@/features/relief-valves/useSrvManagement'

/**
 * Presentation shared by the installed and warehouse tables. The technical
 * VALUE renderers (dates, pressures, serials, due status) are imported from
 * the Prompt-10 `assetDisplay` module rather than rewritten, so one field means
 * one thing everywhere in the product.
 */

/**
 * Mapping state, as a readable label with an icon and a word.
 *
 * `conflict` is deliberately NOT drawn like "needs mapping". They are different
 * problems: a needs-mapping record is missing evidence, a conflict is evidence
 * that disagrees with itself and needs a human to adjudicate. Collapsing them
 * would hide the second behind the first.
 *
 * None of these use Cargas green or NGV yellow: brand colour marks identity,
 * the semantic tokens state condition (CLAUDE.md §11.6).
 */
// Each carries its OWN screen-reader description. These badges borrow a kind
// for its colour and icon, but they describe MAPPING, not compliance — without
// the override, "Resolved" would be announced as "within its calibration or
// inspection date", which is a different fact entirely.
const MAPPING: Record<
  InstalledSrvRow['mapping_status'],
  { kind: 'ok' | 'unmapped' | 'conflict'; label: string; description: string }
> = {
  resolved: {
    kind: 'ok', label: 'Resolved',
    description: 'Station, Unit and equipment parent are all confirmed',
  },
  needs_equipment_mapping: {
    kind: 'unmapped', label: 'Needs equipment mapping',
    description: 'Station and Unit are confirmed; the equipment parent is not',
  },
  needs_unit_mapping: {
    kind: 'unmapped', label: 'Needs unit mapping',
    description: 'The Station is confirmed; the Unit is not',
  },
  needs_station_mapping: {
    kind: 'unmapped', label: 'Needs station mapping',
    description: 'The Station is not confirmed, so no hierarchy is shown',
  },
  conflict: {
    kind: 'conflict', label: 'Conflict',
    description: 'Source evidence disagrees and a human must resolve it',
  },
}

export function MappingBadge({ status }: { status: InstalledSrvRow['mapping_status'] }) {
  const spec = MAPPING[status]
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/**
 * The hierarchy, showing ONLY levels the source actually proved.
 *
 * - Station unresolved → no Region or Station is rendered from raw text. The
 *   raw source name is shown separately, labelled as source text.
 * - Unit unresolved → the Unit column states that, rather than being blank in a
 *   way that reads like missing data.
 * - Equipment unresolved → no parent is guessed, ever.
 */
export function HierarchyCell({ row }: { row: InstalledSrvRow }) {
  if (row.mapping_status === 'needs_station_mapping') {
    return (
      <span className="whitespace-nowrap text-muted-foreground">
        Station not confirmed
      </span>
    )
  }
  return (
    <span className="whitespace-nowrap">
      {row.station_name ?? <NullValue />}
      {row.region_name ? <span className="ml-1.5"><RegionChip name={row.region_name} /></span> : null}
    </span>
  )
}

const PARENT_LABEL: Record<string, string> = {
  compressor: 'Compressor',
  storage_vessel: 'Storage Vessel',
  dispenser: 'Dispenser',
}

/** The equipment parent, or an explicit statement that it is not proven. */
export function ParentCell({ row }: { row: InstalledSrvRow }) {
  if (row.parent_kind && row.parent_id) {
    return (
      <span className="whitespace-nowrap">
        <span className="text-muted-foreground">{PARENT_LABEL[row.parent_kind]}</span>{' '}
        {row.parent_label ? <Identifier value={row.parent_label} /> : <NullValue />}
      </span>
    )
  }
  return <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
}

/**
 * Raw source text, always labelled as source context.
 *
 * `Stage` and `Storage` are parent-KIND hints. Neither is an equipment
 * identity, and the label is what stops the UI implying otherwise.
 */
export function SourceContext({ value, note }: { value: string | null; note: string }) {
  if (!value) return <NullValue />
  return (
    <span>
      <Identifier value={value} />
      <span className="ml-1 text-xs text-muted-foreground">{note}</span>
    </span>
  )
}

/** A compact metric in the attention strip. Deliberately not a KPI card. */
export function Metric({
  label,
  value,
  tone = 'plain',
  hint,
}: {
  label: string
  value: ReactNode
  tone?: 'plain' | 'overdue' | 'due' | 'unmapped'
  hint?: string
}) {
  return (
    <div className="min-w-0">
      <div className="text-xs uppercase tracking-wide text-muted-foreground">{label}</div>
      <div
        className={cn(
          'tabular text-lg font-semibold',
          tone === 'overdue' && 'text-status-overdue',
          tone === 'due' && 'text-status-due-soon',
          tone === 'unmapped' && 'text-status-unmapped',
        )}
      >
        {value}
      </div>
      {hint ? <div className="text-xs text-muted-foreground">{hint}</div> : null}
    </div>
  )
}

/**
 * The dedicated SRV filters: serial, Station, size and set pressure. Each input
 * narrows one column server-side; they combine with each other and with search.
 */
export function SmartFilterBar({ id, value, onChange, stationLabel = 'Station', regionLabel = 'Region', showRegion = true, showStation = true, dates }: {
  id: string
  /** The dates this tab can be filtered by; omit for no date filter. */
  dates?: DateOption[]
  value: SrvSmartFilters
  onChange: (next: SrvSmartFilters) => void
  stationLabel?: string
  regionLabel?: string
  showRegion?: boolean
  showStation?: boolean
}) {
  const regions = useRegions()
  const set = (patch: Partial<SrvSmartFilters>) => onChange({ ...value, ...patch })
  const input = 'h-7 rounded border bg-background px-2 text-sm placeholder:text-muted-foreground'
  return (
    <div role="group" aria-label="Filter by serial, region, station, size and set pressure" className="flex flex-wrap items-end gap-2">
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-serial`}>
        Serial
        <input id={`${id}-serial`} className={cn(input, 'w-32 font-technical')} value={value.serial} placeholder="contains…"
               onChange={(e) => set({ serial: e.target.value })} />
      </label>
      {showRegion ? (
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-region`}>
          {regionLabel}
          <select id={`${id}-region`} className={cn(input, 'px-1.5 text-foreground')} value={value.region}
                  onChange={(e) => set({ region: e.target.value })}>
            <option value="">All</option>
            {regions.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}
          </select>
        </label>
      ) : null}
      {showStation ? (
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-station`}>
          {stationLabel}
          <input id={`${id}-station`} dir="auto" className={cn(input, 'w-40')} value={value.station} placeholder="name contains…"
                 onChange={(e) => set({ station: e.target.value })} />
        </label>
      ) : null}
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-size`}>
        Size
        <input id={`${id}-size`} list={`${id}-sizes`} className={cn(input, 'w-36 font-technical')} value={value.size} placeholder='e.g. M 3/4" X 1" or Flange'
               onChange={(e) => set({ size: e.target.value })} />
        <datalist id={`${id}-sizes`}>
          {['M 1/4" X 1/4"', 'M 1/4" X 1/2"', 'M 1/2" X 3/4"', 'M 1/2" X 1"', 'M 3/4" X 1"', 'M 1" X 1"', 'M 1" X 1-1/4"',
            'F 1/2" X 3/4"', 'F 1" X 1"', 'Flange 1" X 1"', 'Flange 1" X 1-1/4"', 'Flange'].map((s) => <option key={s} value={s} />)}
        </datalist>
      </label>
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-pressure`}>
        Set pressure
        <input id={`${id}-pressure`} inputMode="decimal" className={cn(input, 'w-28 text-right tabular')} value={value.pressure}
               title="One value (30) or a range (30-35)"
               placeholder="30 or 30-35" onChange={(e) => set({ pressure: e.target.value.replace(/[^\d.\-– ]/g, '') })} />
      </label>
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-unit`}>
        Unit
        <select id={`${id}-unit`} className={cn(input, 'px-1.5 text-foreground')} value={value.pressureUnit}
                onChange={(e) => set({ pressureUnit: e.target.value as SrvSmartFilters['pressureUnit'] })}>
          <option value="">Any</option>
          <option value="BAR">BAR</option>
          <option value="PSI">PSI</option>
        </select>
      </label>
      <label className="flex flex-col gap-0.5 text-xs text-muted-foreground" htmlFor={`${id}-manufacturer`}>
        Manufacturer
        <select id={`${id}-manufacturer`} className={cn(input, 'px-1.5 text-foreground')} value={value.manufacturer}
                onChange={(e) => set({ manufacturer: e.target.value })}>
          <option value="">All</option>
          {MANUFACTURERS.map((m) => <option key={m} value={m}>{m}</option>)}
        </select>
      </label>
      {dates ? <DateRangeFilter id={id} value={value} onChange={set} options={dates} /> : null}
    </div>
  )
}

/**
 * Owner request 2026-09-28: each manufacturer and each availability state gets its own colour so they can be told
 * apart at a glance. Categorical colour only — the text is always shown, so colour is never the only signal, and
 * red/amber stay reserved for due status.
 */
const CHIP = 'inline-flex items-center whitespace-nowrap rounded border px-1.5 py-0.5 text-xs font-semibold'
// Owner: every manufacturer must be told apart by eye. Solid fills on hues far apart (blue, purple, teal, orange,
// pink, yellow, lime, brown, black, cyan). Red and amber stay reserved for due status.
const MANUFACTURER_TONE: Record<string, string> = {
  technical: 'border-blue-700 bg-blue-700 text-white',
  mercer: 'border-purple-700 bg-purple-700 text-white',
  'dk-lok': 'border-teal-600 bg-teal-600 text-white',
  coi: 'border-orange-500 bg-orange-500 text-black',
  anderson: 'border-pink-600 bg-pink-600 text-white',
  'tyco anderson': 'border-pink-300 bg-pink-200 text-black',
  ekc: 'border-yellow-300 bg-yellow-300 text-black',
  farinola: 'border-lime-500 bg-lime-500 text-black',
  taylor: 'border-stone-600 bg-stone-600 text-white',
  aspro: 'border-slate-900 bg-slate-900 text-white dark:border-slate-200 dark:bg-slate-200 dark:text-black',
  takei: 'border-cyan-300 bg-cyan-300 text-black',
}
const MANUFACTURERS = ['Anderson', 'Aspro', 'COI', 'DK-LOK', 'EKC', 'Farinola', 'Mercer', 'TAKEI', 'Taylor', 'Technical', 'Tyco Anderson']
const NEUTRAL_TONE = 'border-border bg-muted text-foreground'

export function ManufacturerChip({ value }: { value: string | null }) {
  if (!value) return <NullValue />
  return <span className={cn(CHIP, MANUFACTURER_TONE[value.trim().toLowerCase()] ?? NEUTRAL_TONE)}>{value}</span>
}

// Availability is OUTLINED (manufacturer is filled), so the two columns never look alike.
const AVAILABILITY_TONE: Record<string, string> = {
  available_new: 'border-2 border-blue-600 bg-background text-blue-700 dark:text-blue-300',
  available_calibrated: 'border-2 border-emerald-600 bg-background text-emerald-700 dark:text-emerald-300',
  available_in_store_uc: 'border-2 border-orange-500 bg-background text-orange-700 dark:text-orange-300',
  sent_to_station_received: 'border-2 border-slate-500 bg-background text-slate-700 dark:text-slate-300',
  sent_to_station_not_received: 'border-2 border-purple-600 bg-background text-purple-700 dark:text-purple-300',
}

export function AvailabilityChip({ status, label }: { status: string | null; label: string | null }) {
  if (!status) return <NullValue />
  return <span className={cn(CHIP, AVAILABILITY_TONE[status] ?? NEUTRAL_TONE)}>{label ?? status}</span>
}

export function ToneChip({ tone, children }: { tone: ToneName; children: ReactNode }) {
  return <span className={cn(CHIP, TONE[tone])}>{children}</span>
}

/** Region: the product-wide Region chip (one colour per Region everywhere). */
export { RegionChip }
