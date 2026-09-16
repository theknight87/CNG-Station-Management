import { StatusBadge } from '@/components/data/StatusBadge'
import { NullValue } from '@/components/data/NullValue'
import { Identifier } from '@/components/data/TechnicalText'
import type {
  AlertRow, AlertSubject, AlertThreshold, DeliveryStatus,
} from '@/features/alerts/useAlerts'

/**
 * Alert-specific presentation.
 *
 * WHAT IS DELIBERATELY ABSENT: any language of danger. A 7-day threshold is a
 * scheduling fact, not a statement that equipment is unsafe, so there is no
 * "Critical", no "Emergency", no siren, no pulsing red. The schema records
 * thresholds and dates; inventing a safety severity on top of them would assert
 * something the data does not say.
 */

/** The five subjects, in the schema's own terminology. */
const SUBJECT_LABEL: Record<AlertSubject, string> = {
  srv_calibration: 'SRV calibration',
  storage_inspection: 'Storage vessel inspection',
  recovery_tank_inspection: 'Recovery tank inspection',
  gas_detector_calibration: 'Gas detector calibration',
  hose_hydrotest: 'Hose hydrotest',
}

export function SubjectLabel({ value }: { value: AlertSubject }) {
  return <span className="whitespace-nowrap">{SUBJECT_LABEL[value] ?? value}</span>
}

/**
 * The threshold that raised this alert.
 *
 * This is the RULE that fired, which is a historical fact about the alert. It
 * is not the asset's live due status — an alert raised at 30 days keeps saying
 * "30 days" even once the asset is overdue, because that is what happened. The
 * live position is the separate Days left column.
 */
const THRESHOLD: Record<AlertThreshold, { kind: 'overdue' | 'due' | 'due_soon'; label: string; description: string }> = {
  overdue: { kind: 'overdue', label: 'Overdue', description: 'raised because the due date had passed' },
  due_today: { kind: 'due', label: 'Due today', description: 'raised on the due date itself' },
  due_7: { kind: 'due_soon', label: '7 days', description: 'raised 7 days before the due date' },
  due_15: { kind: 'due_soon', label: '15 days', description: 'raised 15 days before the due date' },
  due_30: { kind: 'due_soon', label: '30 days', description: 'raised 30 days before the due date' },
  due_60: { kind: 'due_soon', label: '60 days', description: 'raised 60 days before the due date' },
}

export function ThresholdBadge({ value }: { value: AlertThreshold }) {
  const spec = THRESHOLD[value] ?? THRESHOLD.due_60
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/**
 * Read state — this caller's own.
 *
 * Not conveyed by weight alone: unread carries a word as well, so it survives a
 * screenshot, a colourblind reader and a screen reader equally.
 */
export function ReadState({ row }: { row: AlertRow }) {
  if (row.is_read) {
    return (
      <span className="whitespace-nowrap text-xs text-muted-foreground">
        Read<span className="sr-only"> — you have marked this alert as read</span>
      </span>
    )
  }
  return (
    <span className="whitespace-nowrap text-xs font-semibold text-foreground">
      Unread<span className="sr-only"> — you have not marked this alert as read</span>
    </span>
  )
}

/**
 * Acknowledgement — a shared operational fact, unlike read state.
 *
 * The actor shown here was stamped by the database, not supplied by a browser.
 */
export function AckState({ row }: { row: AlertRow }) {
  if (!row.acknowledged_at) {
    return (
      <span className="whitespace-nowrap text-xs text-muted-foreground">
        Not acknowledged
        <span className="sr-only"> — no one has yet recorded operational recognition of this alert</span>
      </span>
    )
  }
  return (
    <span className="whitespace-nowrap text-xs">
      Acknowledged
      {row.acknowledged_by_name ? (
        <span className="ml-1 text-muted-foreground">{row.acknowledged_by_name}</span>
      ) : null}
      <span className="sr-only"> — recorded by the server with the acting user and time</span>
    </span>
  )
}

/**
 * Delivery outcome for THIS caller, on one channel.
 *
 * The distinction that matters: "the alert exists and its email failed" is a
 * completely different statement from "there is no alert". A failure is stated
 * in words, never left as an empty cell, and never allowed to look like absence.
 *
 * `null` means no delivery was attempted for this caller at all — which is the
 * normal state while external delivery is unconfigured, not a failure.
 */
const DELIVERY: Record<string, { kind: 'ok' | 'overdue' | 'info'; label: string; description: string }> = {
  sent: { kind: 'ok', label: 'Sent', description: 'the notification reached the provider successfully' },
  failed: { kind: 'overdue', label: 'Failed', description: 'the notification could not be delivered; the alert itself is unaffected' },
  pending: { kind: 'info', label: 'Pending', description: 'delivery has not yet been attempted' },
  skipped: { kind: 'info', label: 'Skipped', description: 'delivery was deliberately not attempted for you' },
}

export function DeliveryState({ value }: { value: DeliveryStatus }) {
  if (!value) {
    return (
      <span className="whitespace-nowrap text-xs text-muted-foreground">
        Not attempted
        <span className="sr-only"> — no delivery was attempted to you for this alert</span>
      </span>
    )
  }
  const spec = DELIVERY[value]
  if (!spec) return <NullValue />
  return <StatusBadge kind={spec.kind} label={spec.label} description={spec.description} />
}

/**
 * Station and Region — only levels the alert actually proves.
 *
 * AN SRV MAY HAVE NO CONFIRMED STATION and still be alertable: an exact due
 * date is enough to know a calibration is coming due. Migration 0015 made that
 * deliberate. Such an alert shows the RAW source place name, clearly labelled
 * as unconfirmed, because naming where the source put it is useful and
 * promoting it to a canonical Station would be a fabrication.
 *
 * These rows are admin/manager only — `alerts_select` routes them through
 * `cng_can_access_unmapped_srv()`, since an unconfirmed region is evidence, not
 * permission. The UI does not enforce that; it just does not contradict it.
 */
export function AlertStationCell({ row }: { row: AlertRow }) {
  if (row.needs_station_mapping) {
    return (
      <span className="whitespace-nowrap">
        <span className="text-muted-foreground">Station not confirmed</span>
        {row.source_station_name_raw ? (
          <span className="ml-1.5 text-xs text-muted-foreground" dir="auto">
            source: {row.source_station_name_raw}
          </span>
        ) : null}
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

/**
 * The Unit, or an explicit statement that it is unresolved.
 *
 * An alert may legitimately exist for an asset whose Unit is not yet mapped —
 * `needs_mapping` says so. No Unit is guessed, and no Unit link is offered for
 * one that does not exist.
 */
export function AlertUnitCell({ row }: { row: AlertRow }) {
  if (row.unit_name) return <span className="whitespace-nowrap">{row.unit_name}</span>
  return (
    <span className="whitespace-nowrap text-muted-foreground">
      Not confirmed
      {row.needs_mapping ? <span className="sr-only"> — this asset still needs mapping</span> : null}
    </span>
  )
}

/** The asset's own identifier. Never synthesized when the source recorded none. */
export function AlertAssetCell({ row }: { row: AlertRow }) {
  if (row.asset_serial) return <Identifier value={row.asset_serial} />
  if (row.asset_serial_status === 'not_yet_assigned') {
    return <span className="text-sm text-muted-foreground">not yet assigned</span>
  }
  return <NullValue />
}
