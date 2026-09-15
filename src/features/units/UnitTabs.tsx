import { NavLink } from 'react-router-dom'

import { cn } from '@/lib/utils'
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
    <nav
      aria-label="Unit sections"
      // Scrolls rather than wrapping or shrinking: at 390px eight technical
      // labels cannot fit, and truncating them into ambiguity is worse than a
      // swipe. The page body still never scrolls sideways.
      className="scrollbar-none -mx-3 overflow-x-auto border-b px-3 sm:-mx-4 sm:px-4"
    >
      <ul className="flex w-max items-stretch gap-0.5">
        {TABS.map((tab) => {
          const count = tab.key && counts ? (counts[tab.key] as number) : null
          return (
            <li key={tab.to || 'overview'}>
              <NavLink
                to={tab.to ? `/units/${unitId}/${tab.to}` : `/units/${unitId}`}
                end={tab.to === ''}
                className={({ isActive }) =>
                  cn(
                    'flex items-center gap-1.5 whitespace-nowrap border-b-2 px-2.5 py-1.5 text-sm transition-colors',
                    isActive
                      ? 'border-b-brand-strong font-semibold text-brand-strong'
                      : 'border-b-transparent text-muted-foreground hover:border-b-border hover:text-foreground',
                  )
                }
              >
                {() => (
                  <>
                    {/* No aria-current here: NavLink already sets it on the
                      * anchor, and a second one on the label announces "current
                      * page" twice. The underline and the weight change are
                      * what carry the state visually, so it is never colour
                      * alone. */}
                    <span>{tab.label}</span>
                    {count !== null ? (
                      <span
                        className={cn(
                          'tabular rounded px-1 text-xs',
                          count === 0 ? 'text-muted-foreground' : 'bg-muted font-medium text-foreground',
                        )}
                      >
                        {count}
                      </span>
                    ) : null}
                  </>
                )}
              </NavLink>
            </li>
          )
        })}
      </ul>
    </nav>
  )
}
