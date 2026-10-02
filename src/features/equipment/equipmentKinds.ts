/**
 * Hoses and Gas Detectors share the relief-valve workflow (owner request 2026-10-02): Installed, Warehouse, Log,
 * a 3rd-party step and Emergency. One set of screens serves both; this is everything that differs between them.
 *
 * A hose is TESTED (hydrotest) and a detector is CALIBRATED — the schema's own words, kept apart here so a hose is
 * never described as calibrated.
 */
export type EquipmentKind = 'hose' | 'gas_detector'

export interface KindSpec {
  kind: EquipmentKind
  /** Route base: /manage/hoses, /manage/gas-detectors. */
  base: string
  title: string
  description: string
  one: string
  many: string
  /** The 3rd-party step's tab and its route segment. */
  jobTab: string
  jobPath: string
  jobVerb: string
  lastLabel: string
  nextLabel: string
  /** In-store state labels: the calibrated state reads "TESTED" for a hose. */
  stateLabel: Record<'available_new' | 'available_calibrated' | 'available_in_store_uc', string>
}

export const KINDS: Record<EquipmentKind, KindSpec> = {
  hose: {
    kind: 'hose',
    base: '/manage/hoses',
    title: 'Hoses Management',
    description: 'Hoses across every Region you are authorized for, their test status, warehouse stock and movements.',
    one: 'hose',
    many: 'hoses',
    jobTab: 'Hydrotest (3rd party)',
    jobPath: 'testing',
    jobVerb: 'Send for hydrotest',
    lastLabel: 'Last test',
    nextLabel: 'Next test',
    stateLabel: { available_new: 'NEW', available_calibrated: 'TESTED', available_in_store_uc: 'UNDER TEST' },
  },
  gas_detector: {
    kind: 'gas_detector',
    base: '/manage/gas-detectors',
    title: 'Gas Detector Management',
    description: 'Gas detectors across every Region you are authorized for, their calibration status, warehouse stock and movements.',
    one: 'gas detector',
    many: 'gas detectors',
    jobTab: 'Calibration (3rd party)',
    jobPath: 'calibration',
    jobVerb: 'Send for calibration',
    lastLabel: 'Last calibration',
    nextLabel: 'Next calibration',
    stateLabel: { available_new: 'NEW', available_calibrated: 'CALIBRATED', available_in_store_uc: 'UNDER CALIBRATION' },
  },
}

export const STORE_STATES = ['available_new', 'available_calibrated', 'available_in_store_uc'] as const
export type StoreState = (typeof STORE_STATES)[number]
