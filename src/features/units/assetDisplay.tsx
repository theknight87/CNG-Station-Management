import { Identifier } from '@/components/data/TechnicalText'
import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import type { StatusKind } from '@/components/data/statusSemantics'
import type { DatePrecision, DueStatus, PressureUnit } from '@/features/units/useUnitWorkspace'

/**
 * How one technical value is drawn. Shared by every equipment section so a
 * serial, a date and a pressure mean the same thing on all eight tabs.
 */

/**
 * Due status, mapped to the semantic vocabulary.
 *
 * `unknown` is its own state and is NEVER shown as current. A valve whose next
 * calibration date is a bare year cannot be said to be within date — that is
 * the whole point of `date_precision` (principle #17).
 *
 * Note what is absent: no mapping to Cargas green. "Within date" is the teal
 * `ok` token. Brand colour is identity; it never states compliance.
 */
const DUE_KIND: Record<DueStatus, StatusKind> = {
  overdue: 'overdue',
  due_today: 'due',
  due_7: 'due_soon',
  due_15: 'due_soon',
  due_30: 'due_soon',
  due_60: 'due_soon',
  valid: 'ok',
  unknown: 'info',
}

const DUE_LABEL: Record<DueStatus, string> = {
  overdue: 'Overdue',
  due_today: 'Due today',
  due_7: 'Due ≤7d',
  due_15: 'Due ≤15d',
  due_30: 'Due ≤30d',
  due_60: 'Due ≤60d',
  valid: 'Within date',
  unknown: 'No exact date',
}

export function DueBadge({ status }: { status: DueStatus | null | undefined }) {
  if (!status) return <NullValue />
  return <StatusBadge kind={DUE_KIND[status]} label={DUE_LABEL[status]} />
}

/**
 * A due date, honouring its precision.
 *
 * The views already compute a `*_display` string that renders a `year_only`
 * date as its year alone and never as a full calendar date (§11.5). It is used
 * verbatim rather than re-derived here, so the UI cannot disagree with SQL.
 */
export function PrecisionDate({
  display,
  precision,
}: {
  display: string | null
  precision: DatePrecision | null
}) {
  if (!display) return <NullValue />
  return (
    <span className="tabular">
      {display}
      {precision === 'year_only' ? (
        <span className="ml-1 text-xs text-muted-foreground">year only</span>
      ) : null}
      {precision === 'invalid' ? (
        <span className="ml-1 text-xs text-muted-foreground">unreadable in source</span>
      ) : null}
    </span>
  )
}

/**
 * A serial number.
 *
 * `not_yet_assigned` is a FACT, not a gap (principle #20): the source states
 * that no serial has been issued yet. It is worded differently from a NULL,
 * where the source simply said nothing. Serials are never generated.
 */
export function Serial({
  value,
  status,
}: {
  value: string | null
  status: string | null
}) {
  if (value) return <Identifier value={value} />
  if (status === 'not_yet_assigned')
    return <span className="text-sm text-muted-foreground">not yet assigned</span>
  return <NullValue />
}

/**
 * A pressure, with the unit the source proved.
 *
 * The unit is NEVER inferred from magnitude and never converted (§32). Where
 * the schema stores no unit, the number is shown alone rather than dressed in
 * a guessed BAR or PSI.
 */
export function Pressure({
  value,
  unit,
  raw,
}: {
  value: number | null
  unit: PressureUnit | null
  raw?: string | null
}) {
  if (value === null || value === undefined) {
    // The raw source text is still worth showing when it exists: it may say
    // something a number cannot (principle #6).
    return raw ? <Identifier value={raw} /> : <NullValue />
  }
  return (
    <span className="tabular">
      {value.toLocaleString()}
      {unit ? <span className="ml-1 text-xs text-muted-foreground">{unit}</span> : null}
    </span>
  )
}

/** A pressure RANGE, as SRVs record it (set pressure min–max). */
export function PressureRange({
  min,
  max,
  unit,
  raw,
}: {
  min: number | null
  max: number | null
  unit: PressureUnit | null
  raw: string | null
}) {
  if (min === null && max === null) return raw ? <Identifier value={raw} /> : <NullValue />
  if (min !== null && max !== null && min !== max) {
    return (
      <span className="tabular">
        {min.toLocaleString()}–{max.toLocaleString()}
        {unit ? <span className="ml-1 text-xs text-muted-foreground">{unit}</span> : null}
      </span>
    )
  }
  return <Pressure value={min ?? max} unit={unit} raw={raw} />
}

/**
 * Source status text kept verbatim beside a missing date (principle #21,
 * decision D6). Values such as `منتهي` never become a date and never become a
 * computed compliance status.
 */
export function SourceStatus({ value }: { value: string | null }) {
  if (!value) return null
  return (
    <span className="ml-1.5 text-xs text-muted-foreground">
      source says <Identifier value={value} />
    </span>
  )
}

/** Plain text that may be absent. */
export function Text({ value }: { value: string | null | undefined }) {
  return <ValueOrNull value={value} />
}
