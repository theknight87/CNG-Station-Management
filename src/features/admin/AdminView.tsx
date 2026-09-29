import { Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { PermissionDenied } from '@/components/states/AppStates'
import { useAppUser } from '@/hooks/useAppUser'
import { SectionTabs } from '@/components/layout/SectionTabs'

/**
 * The Admin workspace.
 *
 * Sections are NESTED ROUTES, not local tab state, so each one is deep-linkable
 * and the Back button behaves.
 *
 * THE ROLE CHECK HERE IS UX. It exists so a non-admin who reaches this URL reads
 * why the screen is empty instead of assuming the product is broken. It is not
 * the protection: migration 0038 revoked the underlying grants, and every
 * privileged mutation is an admin-gated SECURITY DEFINER function, so a user who
 * edits this component out of the bundle gains exactly nothing.
 */
const SECTIONS = [
  { to: '/admin/users', label: 'Users' },
  { to: '/admin/alert-settings', label: 'Alert Settings' },
  { to: '/admin/data-quality', label: 'Data Quality' },
  { to: '/admin/audit-log', label: 'Audit Log' },
]

export function AdminView() {
  const appUser = useAppUser()
  const role = appUser.status === 'active' ? appUser.user.role : null

  if (role !== 'admin') {
    return (
      <PageContainer>
        <PageHeader
          title="Admin"
          description="Users, region access, alert settings and the data-quality workflow."
        />
        <PermissionDenied
          what="administration"
          detail="Administration covers users, region access, alert settings and mapping resolution. It is restricted to administrators, and the database enforces that independently of what this screen shows."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader
        title="Admin"
        description="Users, region access, alert settings, the data-quality workflow and the audit log."
      />
      <SectionTabs label="Admin sections" tabs={SECTIONS} compact />
      <Outlet />
    </PageContainer>
  )
}

