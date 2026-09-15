import { NavLink, Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { cn } from '@/lib/utils'

/**
 * Vessels Management.
 *
 * Storage Vessels and Recovery Tanks share a workspace and an inspection
 * vocabulary, but they are separate asset types with separate tables. The
 * sub-navigation says which one you are looking at in words, and each registry
 * shows only the fields its own schema carries — a Recovery Tank is never given
 * a Storage Vessel's relationships to make the two look alike.
 *
 * Sections are routes, so both are deep-linkable and Back works.
 * `/manage/vessels` remains the canonical entry and lands on Storage Vessels.
 */

const SECTIONS = [
  { to: 'storage', label: 'Storage Vessels', hint: 'Pressure storage, may carry relief valves' },
  { to: 'recovery', label: 'Recovery Tanks', hint: 'Recovery vessels, no relief-valve relationship' },
]

export function VesselWorkspace() {
  return (
    <PageContainer>
      <PageHeader
        title="Vessels Management"
        description="Storage Vessels and Recovery Tanks across every Region you are authorized for, with their inspection status."
      />

      <nav aria-label="Vessel types" className="scrollbar-none -mx-3 overflow-x-auto border-b px-3 sm:-mx-4 sm:px-4">
        <ul className="flex w-max items-stretch gap-0.5">
          {SECTIONS.map((s) => (
            <li key={s.to}>
              <NavLink
                to={`/manage/vessels/${s.to}`}
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
                    {/* Underline, weight and aria-current — never colour alone. */}
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
