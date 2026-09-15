import {
  AlertTriangle,
  CircleDashed,
  CircleHelp,
  CircleSlash,
  Clock,
  GitPullRequestArrow,
  ShieldCheck,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

/**
 * Status vocabulary (CLAUDE.md §11.3, prompt §15).
 *
 * Kept in a module of its own, separate from the component that renders it, so
 * the meanings can be imported by tests, tables and future filters without
 * pulling in React rendering.
 *
 * Two rules decide this vocabulary:
 *
 * 1. **Colour is never the only signal.** Every status carries an icon AND a
 *    word, so it survives greyscale printing, colour blindness, and a
 *    screenshot pasted into a report.
 * 2. **No rainbow.** Eight meanings, muted tones, one visual weight. A badge
 *    that shouts competes with the badge that should.
 *
 * Statuses are named by MEANING, never by hue, so changing the palette cannot
 * silently change what a badge asserts.
 */

export type StatusKind =
  | 'ok'            // current / within date
  | 'due_soon'      // approaching due
  | 'due'           // due now
  | 'overdue'       // overdue / critical
  | 'unmapped'      // mapping unresolved — NOT an error
  | 'conflict'      // source evidence disagrees
  | 'inactive'      // inactive
  | 'info'          // informational / unknown

export interface StatusSpec {
  label: string
  Icon: LucideIcon
  className: string
  /** Read by assistive technology when the short label is ambiguous alone. */
  description: string
}

const STATUS: Record<StatusKind, StatusSpec> = {
  ok: {
    label: 'Current',
    Icon: ShieldCheck,
    className: 'bg-status-ok-bg text-status-ok border-status-ok/25',
    description: 'within its calibration or inspection date',
  },
  due_soon: {
    label: 'Due soon',
    Icon: Clock,
    className: 'bg-status-due-soon-bg text-status-due-soon border-status-due-soon/25',
    description: 'approaching its due date',
  },
  due: {
    label: 'Due',
    Icon: Clock,
    className: 'bg-status-due-soon-bg text-status-due-soon border-status-due-soon/40',
    description: 'due now',
  },
  overdue: {
    label: 'Overdue',
    Icon: AlertTriangle,
    className: 'bg-status-overdue-bg text-status-overdue border-status-overdue/30',
    description: 'past its due date',
  },
  unmapped: {
    // Deliberately NOT styled as an error. An unresolved mapping is missing
    // evidence, not a fault in the asset (principle #19).
    label: 'Needs mapping',
    Icon: GitPullRequestArrow,
    className: 'bg-status-unmapped-bg text-status-unmapped border-status-unmapped/25',
    description: 'awaiting human confirmation of its place in the hierarchy',
  },
  conflict: {
    label: 'Conflict',
    Icon: CircleSlash,
    className: 'bg-status-conflict-bg text-status-conflict border-status-conflict/25',
    description: 'source evidence disagrees; held for human resolution',
  },
  inactive: {
    label: 'Inactive',
    Icon: CircleDashed,
    className: 'bg-status-inactive-bg text-status-inactive border-status-inactive/25',
    description: 'not in service',
  },
  info: {
    label: 'Unknown',
    Icon: CircleHelp,
    className: 'bg-status-inactive-bg text-status-inactive border-status-inactive/20',
    description: 'the source does not say',
  },
}


export { STATUS as STATUS_SPECS }

export type MappingStatus =
  | 'needs_station_mapping'
  | 'needs_unit_mapping'
  | 'needs_equipment_mapping'
  | 'resolved'
  | 'conflict'

/** The import lifecycle rendered as a status. Kept beside the vocabulary so the
 * import and the UI cannot drift apart. An unresolved mapping is NOT an error:
 * it is missing evidence, and it never renders as a failure (principle #19). */
export function mappingStatusKind(status: MappingStatus): StatusKind {
  switch (status) {
    case 'resolved':
      return 'ok'
    case 'conflict':
      return 'conflict'
    default:
      return 'unmapped'
  }
}

export function mappingStatusLabel(status: MappingStatus): string {
  switch (status) {
    case 'needs_station_mapping':
      return 'Needs station mapping'
    case 'needs_unit_mapping':
      return 'Needs unit mapping'
    case 'needs_equipment_mapping':
      return 'Needs equipment mapping'
    case 'resolved':
      return 'Resolved'
    case 'conflict':
      return 'Conflict'
  }
}
