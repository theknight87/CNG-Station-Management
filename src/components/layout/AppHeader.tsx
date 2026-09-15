import type { ReactNode } from 'react'
import { Menu, PanelLeftClose, PanelLeftOpen } from 'lucide-react'

import { Breadcrumbs } from '@/components/layout/Breadcrumbs'
import type { Crumb } from '@/components/layout/breadcrumbPaths'
import { Button } from '@/components/ui/button'

/**
 * Application header (prompt §9).
 *
 * Restrained on purpose. It carries the navigation trigger, page context, and
 * the account slot — and nothing invented. There is no global search, no
 * command palette and no notification bell, because none of them exist yet and
 * a control that does nothing is worse than no control.
 *
 * The account itself is a slot rather than a Clerk import, so the header can be
 * rendered without an authentication round-trip.
 */
export function AppHeader({
  crumbs,
  sidebarCollapsed,
  onToggleSidebar,
  onOpenMobileNav,
  account,
}: {
  crumbs: Crumb[]
  sidebarCollapsed: boolean
  onToggleSidebar: () => void
  onOpenMobileNav: () => void
  account?: ReactNode
}) {
  return (
    <header className="flex h-header shrink-0 items-center gap-2 border-b bg-card px-2 sm:px-3">
      <Button
        variant="ghost"
        size="icon"
        className="lg:hidden"
        onClick={onOpenMobileNav}
        aria-label="Open navigation"
      >
        <Menu className="h-4 w-4" aria-hidden="true" />
      </Button>

      <Button
        variant="ghost"
        size="icon"
        className="hidden lg:inline-flex"
        onClick={onToggleSidebar}
        aria-label={sidebarCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
        aria-expanded={!sidebarCollapsed}
      >
        {sidebarCollapsed ? (
          <PanelLeftOpen className="h-4 w-4" aria-hidden="true" />
        ) : (
          <PanelLeftClose className="h-4 w-4" aria-hidden="true" />
        )}
      </Button>

      <div className="min-w-0 flex-1">
        <Breadcrumbs crumbs={crumbs} />
      </div>

      {account}
    </header>
  )
}
