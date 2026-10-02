import type { ReactNode } from 'react'

import { RegionChip } from '@/components/data/AssetChips'
import { DateRangePicker } from '@/components/data/DateRangePicker'
import { PressureFilter } from '@/components/data/FilterControls'
import { filterControl, filterLabel } from '@/components/data/filterStyles'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
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
      <span className="cell-note ml-1 text-xs text-muted-foreground">{note}</span>
    </span>
  )
}

/**
 * A compact metric in the attention strip. Deliberately not a KPI card.
 *
 * With `onSelect` it is a quick filter (owner request 2026-10-02): a toggle button that narrows the table
 * below to exactly the rows it counts; pressing it again clears that filter. The active state is a
 * brand-strong underline plus `aria-pressed`, never colour alone.
 */
export function Metric({
  label,
  value,
  tone = 'plain',
  hint,
  onSelect,
  active = false,
}: {
  label: string
  value: ReactNode
  tone?: 'plain' | 'overdue' | 'due' | 'unmapped'
  hint?: string
  onSelect?: () => void
  active?: boolean
}) {
  const body = (
    <>
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
    </>
  )
  if (!onSelect) return <div className="min-w-0">{body}</div>
  return (
    <button
      type="button"
      onClick={onSelect}
      aria-pressed={active}
      title={active ? `Showing ${label} only — press again to show all` : `Show ${label} only`}
      className={cn(
        '-mx-1.5 -my-1 min-w-0 rounded border-b-2 px-1.5 py-1 text-left transition-colors',
        'hover:bg-muted focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-strong',
        active ? 'border-b-brand-strong bg-brand-strong/10' : 'border-b-transparent',
      )}
    >
      {body}
    </button>
  )
}

/**
 * The dedicated SRV filters, drawn INSIDE the tab's toolbar beside its search (owner request 2026-09-29: one tidy
 * filter row, nothing repeated): Region where the tab has one, size, set pressure with its unit, manufacturer and
 * the tab's date range. Serial and Station are not repeated — the search box finds both. Each narrows one column
 * server-side; they combine with each other and with the search.
 */
export function SmartFilterBar({ id, value, onChange, regionLabel = 'Region', showRegion = true, date }: {
  id: string
  value: SrvSmartFilters
  onChange: (next: SrvSmartFilters) => void
  regionLabel?: string
  showRegion?: boolean
  /** The date this tab is filtered by; omit for no date filter. */
  date?: DateOption
}) {
  const regions = useRegions()
  const set = (patch: Partial<SrvSmartFilters>) => onChange({ ...value, ...patch })
  return (
    <>
      {showRegion ? (
        <MultiSelectFilter id={`${id}-region`} label={regionLabel} value={value.region} onChange={(region) => set({ region })}
                           options={regions.map((r) => ({ value: r.id, label: r.label }))} />
      ) : null}
      <label className={filterLabel} htmlFor={`${id}-size`}>
        Size
        <input id={`${id}-size`} list={`${id}-sizes`} className={cn(filterControl, 'w-32 px-2 font-technical')} value={value.size}
               placeholder={'M 3/4" X 1"'} title={'The full size (M 3/4" X 1") or part of it (Flange, 1/2")'}
               onChange={(e) => set({ size: e.target.value })} />
        <datalist id={`${id}-sizes`}>
          {['M 1/4" X 1/4"', 'M 1/4" X 1/2"', 'M 1/2" X 3/4"', 'M 1/2" X 1"', 'M 3/4" X 1"', 'M 1" X 1"', 'M 1" X 1-1/4"',
            'F 1/2" X 3/4"', 'F 1" X 1"', 'Flange 1" X 1"', 'Flange 1" X 1-1/4"', 'Flange'].map((s) => <option key={s} value={s} />)}
        </datalist>
      </label>
      <PressureFilter id={id} label="Set pressure" value={value.pressure} unit={value.pressureUnit}
                      onChange={(p) => set({ ...(p.value !== undefined ? { pressure: p.value } : {}), ...(p.unit !== undefined ? { pressureUnit: p.unit } : {}) })} />
      <MultiSelectFilter id={`${id}-manufacturer`} label="Manufacturer" value={value.manufacturer}
                         onChange={(manufacturer) => set({ manufacturer })} options={MANUFACTURERS.map((m) => ({ value: m, label: m }))} />
      {date ? <DateRangePicker id={id} value={value} onChange={set} option={date} /> : null}
    </>
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
