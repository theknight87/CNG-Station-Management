import { useCallback, useState, type ReactNode } from 'react'

import { AppHeader } from '@/components/layout/AppHeader'
import { MobileNav } from '@/components/layout/MobileNav'
import { SidebarNav } from '@/components/layout/SidebarNav'
import type { Crumb } from '@/components/layout/breadcrumbPaths'
import { cn } from '@/lib/utils'
import type { AppRole } from '@/types/domain'

const COLLAPSE_KEY = 'cng.sidebar.collapsed'

/** Storage can throw (private mode, blocked site data); the default is expanded. */
function readCollapsed(): boolean {
  try {
    return window.localStorage.getItem(COLLAPSE_KEY) === '1'
  } catch {
    return false
  }
}

/**
 * The application shell, as pure presentation.
 *
 * It knows the ROLE and the CRUMBS; it does not know about Clerk or Supabase.
 * `AppLayout` supplies those. Keeping the split means the shell can be rendered
 * and inspected in a real browser without an authentication round-trip — which
 * is the only way it could be visually verified in an environment whose egress
 * policy blocks Clerk.
 *
 * Layout decisions, and why:
 *
 * - A PERSISTENT left sidebar on desktop at 15rem, collapsing to 3.25rem. Every
 *   pixel it does not take is workspace for the engineering tables Prompts 8-20
 *   will fill (§11.3).
 * - The MAIN region owns the scroll, so the sidebar and header stay put while a
 *   long table scrolls — the normal expectation in an operations console.
 * - A skip link, because a keyboard user should not tab through the whole
 *   navigation to reach the table they came for.
 */
export function AppShell({
  role,
  crumbs,
  account,
  children,
}: {
  role: AppRole | null
  crumbs: Crumb[]
  /** The account control. Supplied by the app; stubbed in the preview harness. */
  account?: ReactNode
  children: ReactNode
}) {
  // A per-browser convenience, so localStorage — nobody should need a database
  // row to remember a sidebar width. Read in the initializer rather than an
  // effect, so the sidebar never renders expanded and then snaps shut.
  const [collapsed, setCollapsed] = useState(readCollapsed)
  const [mobileOpen, setMobileOpen] = useState(false)

  const toggleSidebar = useCallback(() => {
    setCollapsed((prev) => {
      const next = !prev
      try {
        window.localStorage.setItem(COLLAPSE_KEY, next ? '1' : '0')
      } catch {
        // Failing to remember the preference must never break the app.
      }
      return next
    })
  }, [])

  return (
    <div className="flex h-screen overflow-hidden bg-background">
      <a
        href="#main-content"
        className="sr-only focus:not-sr-only focus:absolute focus:left-2 focus:top-2 focus:z-50 focus:rounded focus:border focus:bg-card focus:px-3 focus:py-2 focus:text-sm focus:shadow"
      >
        Skip to main content
      </a>

      <aside
        className={cn(
          'hidden shrink-0 flex-col border-r bg-card lg:flex',
          collapsed ? 'w-sidebar-collapsed' : 'w-sidebar',
        )}
      >
        <div
          className={cn(
            'flex h-header shrink-0 items-center border-b',
            collapsed ? 'justify-center px-0' : 'px-3',
          )}
        >
          {collapsed ? (
            <span className="text-sm font-semibold tracking-tight" aria-hidden="true">
              CNG
            </span>
          ) : (
            <span className="truncate text-sm font-semibold tracking-tight">CNG Station Management</span>
          )}
        </div>

        <div className="flex-1 overflow-y-auto">
          <SidebarNav role={role} collapsed={collapsed} />
        </div>
      </aside>

      <MobileNav open={mobileOpen} onClose={() => setMobileOpen(false)} role={role} />

      <div className="flex min-w-0 flex-1 flex-col">
        <AppHeader
          crumbs={crumbs}
          sidebarCollapsed={collapsed}
          onToggleSidebar={toggleSidebar}
          onOpenMobileNav={() => setMobileOpen(true)}
          account={account}
        />

        <main id="main-content" className="flex-1 overflow-auto">
          {children}
        </main>
      </div>
    </div>
  )
}
