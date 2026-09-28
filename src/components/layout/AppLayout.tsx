import { Outlet, useLocation } from 'react-router-dom'

import { AppShell } from '@/components/layout/AppShell'
import { AlertBell } from '@/features/alerts/AlertBell'
import { SupabaseAccountControl } from '@/components/layout/AccountControl'
import { BreadcrumbProvider } from '@/components/layout/BreadcrumbProvider'
import { crumbsFromPath } from '@/components/layout/breadcrumbPaths'
import { useAppUser } from '@/hooks/useAppUser'

/**
 * The authenticated layout: the shell, wired to the real identity and the real
 * role.
 *
 * The role comes from `app_users`, which is the authorization authority
 * (CLAUDE.md §10). What it drives here is navigation VISIBILITY only — the
 * database refuses unauthorized reads regardless of what is rendered.
 */
export function AppLayout() {
  const location = useLocation()
  const appUser = useAppUser()
  const role = appUser.status === 'active' ? appUser.user.role : null

  return (
    // A screen that owns an entity publishes the real trail once its data has
    // loaded; until then the path-derived one stands, so no label is ever
    // fabricated from a URL segment.
    <BreadcrumbProvider>
      {(override) => (
        <AppShell
          notifications={<AlertBell />}
          role={role}
          crumbs={override ?? crumbsFromPath(location.pathname)}
          account={<SupabaseAccountControl role={role} />}
        >
          <Outlet />
        </AppShell>
      )}
    </BreadcrumbProvider>
  )
}
