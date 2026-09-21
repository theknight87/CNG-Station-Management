import {
  Building2,
  ClipboardList,
  Container,
  FileBarChart,
  Gauge,
  LayoutDashboard,
  Radar,
  ShieldAlert,
  ShieldCheck,
  Settings,
  Waves,
} from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

import type { AppRole } from '@/types/domain'

/**
 * Navigation reflects the authoritative structure: the physical hierarchy
 * (Region -> Station -> Unit -> Equipment -> SRV) plus the global aggregate
 * management modules, which are views over the same records and never own them.
 *
 * AUTHORIZATION NOTE. `roles` controls VISIBILITY ONLY. Hiding a link is UX,
 * never security (CLAUDE.md §10): the database refuses unauthorized reads and
 * writes whatever this file says, and a user who types the URL still sees the
 * permission state rather than data. No new role rule is invented here — the
 * lists below restate Prompt 5's roles, nothing more.
 */

export interface NavItem {
  label: string
  to: string
  Icon: LucideIcon
  /** Roles that see this item. Omitted means every authenticated role. */
  roles?: readonly AppRole[]
  /** Match the route prefix rather than the exact path, for nested routes. */
  matchPrefix?: boolean
}

export interface NavSection {
  /** Undefined for the ungrouped top-level items. */
  heading?: string
  items: NavItem[]
}

const ALL_ROLES: readonly AppRole[] = ['admin', 'manager', 'engineer', 'viewer']
const ADMIN_ONLY: readonly AppRole[] = ['admin']

export const NAV_SECTIONS: NavSection[] = [
  {
    items: [{ label: 'Dashboard', to: '/dashboard', Icon: LayoutDashboard }],
  },
  {
    heading: 'Stations',
    items: [
      { label: 'Regions', to: '/regions', Icon: Building2, matchPrefix: true },
      { label: 'Stations', to: '/stations', Icon: Container, matchPrefix: true },
    ],
  },
  {
    heading: 'Asset Management',
    items: [
      { label: 'SRV Management', to: '/manage/srvs', Icon: ShieldAlert },
      { label: 'Vessels Management', to: '/manage/vessels', Icon: Gauge },
      { label: 'Gas Detector Management', to: '/manage/gas-detectors', Icon: Radar },
      { label: 'Hoses Management', to: '/manage/hoses', Icon: Waves },
    ],
  },
  {
    items: [
      { label: 'Alerts', to: '/alerts', Icon: ClipboardList },
      { label: 'Reports', to: '/reports', Icon: FileBarChart },
    ],
  },
  {
    heading: 'System',
    items: [
      // Admin covers users, region access, imports and data quality — every one
      // of which is admin-only in Prompt 5's RLS. Manager deliberately does NOT
      // appear: it holds no authorization-management privilege, and inventing
      // one for the sake of a nav item would be inventing a business rule.
      { label: 'Admin', to: '/admin', Icon: ShieldCheck, roles: ADMIN_ONLY, matchPrefix: true },
      { label: 'Settings', to: '/settings', Icon: Settings },
    ],
  },
]

/**
 * The sections a role may SEE. Empty sections are dropped so no bare heading is
 * left hanging over nothing.
 */
export function visibleSections(role: AppRole | null): NavSection[] {
  if (role === null) return []
  return NAV_SECTIONS.map((section) => ({
    ...section,
    items: section.items.filter((item) => (item.roles ?? ALL_ROLES).includes(role)),
  })).filter((section) => section.items.length > 0)
}

/** Every path reachable from the sidebar, for tests and breadcrumb lookups. */
export function allNavPaths(): string[] {
  return NAV_SECTIONS.flatMap((s) => s.items.map((i) => i.to))
}

