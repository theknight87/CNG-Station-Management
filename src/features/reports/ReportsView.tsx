import { Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { PermissionDenied } from '@/components/states/AppStates'
import { useAppUser } from '@/hooks/useAppUser'
import { SectionTabs } from '@/components/layout/SectionTabs'

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
  // Owner request 2026-10-02: Data Quality and Notification Activity are no longer offered here.
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
      <SectionTabs label="Report categories" tabs={SECTIONS} compact />
      <Outlet />
    </PageContainer>
  )
}
