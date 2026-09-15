import { NavLink, Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { cn } from '@/lib/utils'

/**
 * Global SRV Management.
 *
 * Two datasets, one workspace, and they are never merged. Installed valves sit
 * in the physical hierarchy `Region → Station → Unit → Equipment`; warehouse
 * stock is inventory with no physical position at all. The sub-navigation makes
 * which one you are looking at unmistakable — by label and by the description
 * under the heading, not by colour.
 *
 * Sections are routes (`/manage/srvs/installed`, `/manage/srvs/warehouse`), so
 * both are deep-linkable and Back works. `/manage/srvs` remains the canonical
 * entry point and lands on Installed.
 */

const SECTIONS = [
  { to: 'installed', label: 'Installed SRVs', hint: 'Valves fitted to station equipment' },
  { to: 'warehouse', label: 'Warehouse SRVs', hint: 'Inventory — no station or unit' },
]

export function SrvWorkspace() {
  return (
    <PageContainer>
      <PageHeader
        title="SRV Management"
        description="Safety Relief Valves across every Region you are authorized for, and warehouse stock."
      />

      <nav aria-label="SRV datasets" className="scrollbar-none -mx-3 overflow-x-auto border-b px-3 sm:-mx-4 sm:px-4">
        <ul className="flex w-max items-stretch gap-0.5">
          {SECTIONS.map((s) => (
            <li key={s.to}>
              <NavLink
                to={`/manage/srvs/${s.to}`}
                className={({ isActive }) =>
                  cn(
                    'flex flex-col whitespace-nowrap border-b-2 px-3 py-1.5 transition-colors',
                    isActive
                      ? 'border-b-brand-strong text-brand-strong'
                      : 'border-b-transparent text-muted-foreground hover:border-b-border hover:text-foreground',
                  )
                }
              >
                {({ isActive }) => (
                  <>
                    {/* The active dataset is marked by an underline, a weight
                      * change and aria-current — never by colour alone. */}
                    <span className={cn('text-sm', isActive && 'font-semibold')}>{s.label}</span>
                    <span className="text-xs text-muted-foreground">{s.hint}</span>
                  </>
                )}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>

      <Outlet />
    </PageContainer>
  )
}
