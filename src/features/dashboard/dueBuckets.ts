/**
 * Due-status vocabulary for the dashboard.
 *
 * These are the buckets `cng_due_status()` already produces in PostgreSQL, so
 * the dashboard and the asset screens can never drift into different
 * definitions of "overdue".
 *
 * THE BUCKETS ARE MUTUALLY EXCLUSIVE, not cumulative. `due_7` is "within 7
 * days"; `due_15` is "8 to 15 days"; `due_30` is "16 to 30". Every asset falls
 * in exactly one, so the columns sum to the total and nothing is counted twice.
 * The labels say so explicitly — "8–15 days", never "within 15 days" — because
 * a cumulative reading of a non-cumulative number is the classic dashboard lie.
 *
 * `unknown` is deliberately distinct from `valid`. A year-only, invalid or
 * missing date is NOT compliant and NOT overdue: it is simply not known, and
 * conflating it with "current" would quietly mark unverifiable equipment safe.
 */

import type { StatusKind } from '@/components/data/statusSemantics'

export type DueStatus =
  | 'overdue'
  | 'due_today'
  | 'due_7'
  | 'due_15'
  | 'due_30'
  | 'due_60'
  | 'valid'
  | 'unknown'

export interface DueBucket {
  status: DueStatus
  /** Column heading. States the RANGE, so the bucket cannot be read as cumulative. */
  label: string
  /** Longer wording for assistive technology and tooltips. */
  description: string
  statusKind: StatusKind
  /** Counts toward "needs attention": overdue plus everything due within 60 days. */
  attention: boolean
}

export const DUE_BUCKETS: readonly DueBucket[] = [
  {
    status: 'overdue',
    label: 'Overdue',
    description: 'past its due date',
    statusKind: 'overdue',
    attention: true,
  },
  {
    status: 'due_today',
    label: 'Today',
    description: 'due today',
    statusKind: 'due',
    attention: true,
  },
  {
    status: 'due_7',
    label: '1–7 days',
    description: 'due within the next 7 days',
    statusKind: 'due',
    attention: true,
  },
  {
    status: 'due_15',
    label: '8–15 days',
    description: 'due in 8 to 15 days',
    statusKind: 'due_soon',
    attention: true,
  },
  {
    status: 'due_30',
    label: '16–30 days',
    description: 'due in 16 to 30 days',
    statusKind: 'due_soon',
    attention: true,
  },
  {
    status: 'due_60',
    label: '31–60 days',
    description: 'due in 31 to 60 days',
    statusKind: 'due_soon',
    attention: true,
  },
  {
    status: 'valid',
    label: 'Current',
    description: 'more than 60 days until due',
    statusKind: 'ok',
    attention: false,
  },
  {
    status: 'unknown',
    label: 'No exact date',
    // The wording matters: this is not "fine" and not "late".
    description:
      'no exact due date exists — the source gave a year only, an unreadable value, or nothing. Never counted as current and never as overdue',
    statusKind: 'info',
    attention: false,
  },
]

export const ATTENTION_STATUSES: readonly DueStatus[] = DUE_BUCKETS.filter((b) => b.attention).map(
  (b) => b.status,
)

/** Asset kinds that carry an inspection or calibration due date. */
export const DUE_ASSET_KINDS = [
  'installed_relief_valve',
  'storage_vessel',
  'recovery_tank',
  'gas_detector',
  'hose',
] as const

export type DueAssetKind = (typeof DUE_ASSET_KINDS)[number]

export const ASSET_LABELS: Record<string, string> = {
  station: 'Stations',
  unit: 'Units',
  compressor: 'Compressors',
  dispenser: 'Dispensers',
  storage_vessel: 'Storage Vessels',
  recovery_tank: 'Recovery Tanks',
  gas_detector: 'Gas Detectors',
  hose: 'Hoses',
  installed_relief_valve: 'Installed SRVs',
  warehouse_relief_valve: 'Warehouse SRVs',
}

/** Where each summary drills down to. Only routes that already exist. */
export const ASSET_ROUTES: Record<string, string | undefined> = {
  station: '/stations',
  unit: '/stations',
  storage_vessel: '/manage/vessels',
  recovery_tank: '/manage/vessels',
  gas_detector: '/manage/gas-detectors',
  hose: '/manage/hoses',
  installed_relief_valve: '/manage/srvs',
  // Compressors and dispensers have no management module of their own; they are
  // reached through the hierarchy. No dead link is created for them.
  compressor: undefined,
  dispenser: undefined,
}
