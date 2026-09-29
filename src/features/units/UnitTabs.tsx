import { SectionTabs } from '@/components/layout/SectionTabs'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { UnitSummary } from '@/features/hierarchy/useHierarchy'

/**
 * Unit sub-navigation.
 *
 * These are ROUTES, not an ARIA tab widget — every section is deep-linkable, and
 * the browser Back button works. So it is marked up as a `nav` of links with
 * `aria-current="page"`, not `role="tablist"`: using tab roles for real
 * navigation lies to a screen reader about what Enter will do.
 *
 * The active section is marked three ways, never by colour alone: a 2px
 * underline, a weight change, and `aria-current`.
 *
 * Counts come from the Unit summary that the header already loaded, so the
 * strip costs no extra query. **A count is shown only when it is known.** If the
 * summary failed or is still loading, the badge is absent — a failed query must
 * never render as `[0]`, which would read as "this Unit has no vessels".
 */

const TABS = [
  { to: '', label: 'Overview', key: null },
  { to: 'compressor', label: 'Compressor', key: 'compressors' },
  { to: 'recovery-tank', label: 'Recovery Tank', key: 'recovery_tanks' },
  { to: 'dispensers', label: 'Dispensers', key: 'dispensers' },
  { to: 'storage', label: 'Storage', key: 'storage_vessels' },
  { to: 'gas-detectors', label: 'Gas Detectors', key: 'gas_detectors' },
  { to: 'hoses', label: 'Hoses', key: 'hoses' },
  { to: 'srvs', label: 'SRVs', key: 'installed_srvs' },
] as const

export function UnitTabs({
  unitId,
  summary,
}: {
  unitId: string
  summary: Loadable<UnitSummary | null>
}) {
  const counts = summary.status === 'ready' && summary.data ? summary.data : null

  return (
    <SectionTabs
      label="Unit sections"
      compact
      tabs={TABS.map((tab) => ({
        to: tab.to ? `/units/${unitId}/${tab.to}` : `/units/${unitId}`,
        end: tab.to === '',
        label: tab.label,
        // A count is shown only when it is known; a failed or loading summary shows none, never 0.
        count: tab.key && counts ? (counts[tab.key] as number) : null,
      }))}
    />
  )
}
