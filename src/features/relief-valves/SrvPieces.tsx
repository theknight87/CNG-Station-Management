import type { ReactNode } from 'react'

import { StatusBadge } from '@/components/data/StatusBadge'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { cn } from '@/lib/utils'
import type { InstalledSrvRow } from '@/features/relief-valves/useSrvManagement'

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
      {row.region_name ? <span className="ml-1.5 text-xs text-muted-foreground">{row.region_name}</span> : null}
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
