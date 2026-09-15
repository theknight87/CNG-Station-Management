import { NavLink } from 'react-router-dom'

import { cn } from '@/lib/utils'
import type { AppRole } from '@/types/domain'
import { visibleSections } from './navigation'

/**
 * The navigation list itself, shared by the desktop sidebar and the mobile
 * drawer so the two can never present different structures.
 */
export function SidebarNav({
  role,
  collapsed = false,
  onNavigate,
}: {
  role: AppRole | null
  collapsed?: boolean
  onNavigate?: () => void
}) {
  const sections = visibleSections(role)

  return (
    <nav aria-label="Main" className="flex flex-col gap-3 py-2">
      {sections.map((section, index) => (
        <div key={section.heading ?? `group-${index}`}>
          {/* Section labels are 12px, not 11px: below 12px is under the
              readable floor even for a label, and the density cost of one
              extra pixel is nil. */}
          {section.heading && !collapsed ? (
            <p className="px-3 pb-1 text-xs font-semibold uppercase tracking-wider text-muted-foreground">
              {section.heading}
            </p>
          ) : null}
          {/* Collapsed: a rule stands in for the heading so grouping survives
              without a label that would not fit. */}
          {section.heading && collapsed ? <div className="mx-2 mb-1 border-t" /> : null}

          <ul className="space-y-px px-2">
            {section.items.map((item) => {
              const { Icon } = item
              return (
                <li key={item.to}>
                  <NavLink
                    to={item.to}
                    end={!item.matchPrefix}
                    onClick={onNavigate}
                    title={collapsed ? item.label : undefined}
                    className={({ isActive }) =>
                      cn(
                        // Compact rows: 28px, not a 44px pill. Density is the
                        // point (§11.3); these are not touch-primary targets on
                        // desktop, and the mobile drawer uses roomier rows.
                        'group relative flex items-center gap-2 rounded px-2 py-1.5 text-sm transition-colors',
                        collapsed && 'justify-center px-0',
                        isActive
                          ? 'bg-accent font-medium text-accent-foreground'
                          : 'text-muted-foreground hover:bg-accent/60 hover:text-accent-foreground',
                      )
                    }
                  >
                    {({ isActive }) => (
                      <>
                        {/* Active state is not colour alone: a left marker
                            carries it too, and aria-current carries it to
                            assistive technology. */}
                        <span
                          aria-hidden="true"
                          className={cn(
                            'absolute left-0 top-1/2 h-4 w-0.5 -translate-y-1/2 rounded-r bg-foreground transition-opacity',
                            isActive ? 'opacity-100' : 'opacity-0',
                          )}
                        />
                        <Icon className="h-4 w-4 shrink-0" aria-hidden="true" />
                        {collapsed ? (
                          <span className="sr-only">{item.label}</span>
                        ) : (
                          <span className="truncate">{item.label}</span>
                        )}
                      </>
                    )}
                  </NavLink>
                </li>
              )
            })}
          </ul>
        </div>
      ))}
    </nav>
  )
}
