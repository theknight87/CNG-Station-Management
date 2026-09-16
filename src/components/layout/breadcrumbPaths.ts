/**
 * Breadcrumb data, separate from the component that draws it.
 *
 * Entity labels (an Arabic Station name, a Unit name) are supplied by the
 * screen that owns the entity. This module only names the SHELL's own routes —
 * it never guesses an entity name from a URL segment.
 */

export interface Crumb {
  label: string
  to?: string
  /** Entity labels get direction-aware rendering; route labels do not need it. */
  isEntity?: boolean
}

/**
 * Derives crumbs from a pathname for the shell's own routes.
 *
 * Screens that know their entities (a Station page, a Unit page) pass explicit
 * crumbs instead — this fallback exists so no route is ever crumb-less, not so
 * that entity names get guessed from URL segments.
 */
const ROUTE_LABELS: Record<string, string> = {
  dashboard: 'Dashboard',
  regions: 'Regions',
  stations: 'Stations',
  manage: 'Asset Management',
  srvs: 'SRV Management',
  vessels: 'Vessels Management',
  'gas-detectors': 'Gas Detector Management',
  hoses: 'Hoses Management',
  alerts: 'Alerts',
  reports: 'Reports',
  admin: 'Admin',
  settings: 'Settings',
  units: 'Units',
  compressor: 'Compressor',
  'recovery-tank': 'Recovery Tank',
  dispensers: 'Dispensers',
  storage: 'Storage',
  users: 'Users',
  'alert-settings': 'Alert Settings',
  'data-quality': 'Data Quality',
  'audit-log': 'Audit Log',
  import: 'Import',
}

export function crumbsFromPath(pathname: string): Crumb[] {
  const segments = pathname.split('/').filter(Boolean)
  const crumbs: Crumb[] = []
  let path = ''

  for (let i = 0; i < segments.length; i++) {
    const segment = segments[i]
    path += `/${segment}`
    const known = ROUTE_LABELS[segment]

    // An unknown segment is an id. It is NOT rendered as a fake entity name;
    // the screen that owns the entity supplies the real label instead.
    if (!known) continue

    // "manage" is a grouping prefix with no page of its own.
    const linkable = i < segments.length - 1 && segment !== 'manage'
    crumbs.push({ label: known, to: linkable ? path : undefined })
  }

  return crumbs
}
