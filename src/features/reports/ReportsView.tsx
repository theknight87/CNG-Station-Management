import { NavLink, Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { PermissionDenied } from '@/components/states/AppStates'
import { useAppUser } from '@/hooks/useAppUser'
import { cn } from '@/lib/utils'

/**
 * The Reports workspace.
 *
 * ONE workspace with report-type selection, as nested routes so each report is
 * deep-linkable and the Back button behaves.
 *
 * THE ROLE CHECK HERE IS UX. Every report view is `security_invoker`, so a
 * viewer or engineer reads only their authorized Regions and an unauthenticated
 * caller reads nothing — whatever this component renders. It exists so someone
 * who is not signed in, or whose account is not yet activated, reads why the
 * page is empty rather than assuming the product is broken.
 *
 * Reports are READ-ONLY for every role. There is no acknowledgement control, no
 * mapping control and no mutation of any kind in this module.
 */
const SECTIONS = [
  { to: '/reports/due', label: 'Due & Overdue' },
  { to: '/reports/srv', label: 'SRV' },
  { to: '/reports/vessels', label: 'Vessels' },
  { to: '/reports/gas-detectors', label: 'Gas Detectors' },
  { to: '/reports/hoses', label: 'Hoses' },
  { to: '/reports/data-quality', label: 'Data Quality' },
  { to: '/reports/activity', label: 'Notification Activity' },
]

export function ReportsView() {
  const appUser = useAppUser()

  if (appUser.status !== 'active') {
    return (
      <PageContainer>
        <PageHeader
          title="Reports"
          description="Compliance and asset reports across Regions and Stations."
        />
        <PermissionDenied
          what="reports"
          detail="Reports read the same records as the rest of the application and are bounded by the same Region authorization. An active account is required, and the database enforces that independently of what this screen shows."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader
        title="Reports"
        description="Operational compliance reporting. Every figure is read from live records within your authorized Regions — nothing here is stored, cached or hard-coded."
      />
      <nav aria-label="Report categories" className="flex flex-wrap gap-1 border-b">
        {SECTIONS.map((section) => (
          <NavLink
            key={section.to}
            to={section.to}
            className={({ isActive }) =>
              cn(
                'border-b-2 px-2 py-1 text-sm',
                isActive
                  ? 'border-[--brand-strong] font-medium text-[--brand-strong]'
                  : 'border-transparent text-muted-foreground hover:text-foreground',
              )
            }
          >
            {section.label}
          </NavLink>
        ))}
      </nav>
      <Outlet />
    </PageContainer>
  )
}
