/**
 * Domain vocabulary for the CNG Station Management System.
 *
 * These types mirror the authoritative hierarchy documented in CLAUDE.md and
 * docs/architecture.md. They are intentionally independent of any generated
 * database types — those arrive in the schema phase as src/types/database.ts.
 *
 * Physical hierarchy: Region -> Station -> Unit -> Equipment -> SRV
 */

export const CANONICAL_REGIONS = [
  'East',
  'West',
  'Canal',
  'Delta',
  'Alex',
  'Upper',
] as const

export type CanonicalRegion = (typeof CANONICAL_REGIONS)[number]

/** Equipment types that hang directly off a Unit. */
export type UnitEquipmentKind =
  | 'compressor'
  | 'recovery_tank'
  | 'gas_detector'
  | 'dispenser'
  | 'storage_vessel'

/** The three equipment kinds that may parent a Safety Relief Valve. */
export type SrvParentKind = 'compressor' | 'storage_vessel' | 'dispenser'

/**
 * How far the source evidence goes for an installed SRV's placement.
 * See docs/architecture.md, "Safety Relief Valves — parentage and mapping status".
 */
export type SrvMappingStatus =
  | 'resolved'
  | 'needs_unit_mapping'
  | 'needs_equipment_mapping'
  | 'conflict'

export const SRV_MAPPING_STATUSES: readonly SrvMappingStatus[] = [
  'resolved',
  'needs_unit_mapping',
  'needs_equipment_mapping',
  'conflict',
] as const

/** An SRV is shown inside a Unit's SRV tab only when its Unit mapping is confirmed. */
export function hasConfirmedUnitMapping(status: SrvMappingStatus): boolean {
  return status === 'resolved' || status === 'needs_equipment_mapping'
}

export function needsMapping(status: SrvMappingStatus): boolean {
  return status !== 'resolved'
}

/**
 * Application roles. Authorization is enforced in the database (RLS); these
 * values exist so the UI can *describe* what the user may do, never to decide it.
 */
export type AppRole = 'admin' | 'manager' | 'engineer' | 'viewer'

export const APP_ROLES: readonly AppRole[] = ['admin', 'manager', 'engineer', 'viewer'] as const

/** Roles whose authority is company-wide rather than region-scoped. */
export function isCompanyWideRole(role: AppRole): boolean {
  return role === 'admin' || role === 'manager'
}
