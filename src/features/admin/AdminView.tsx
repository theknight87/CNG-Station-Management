import { NavLink, Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { PermissionDenied } from '@/components/states/AppStates'
import { useAppUser } from '@/hooks/useAppUser'
import { cn } from '@/lib/utils'

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
      <nav aria-label="Admin sections" className="flex flex-wrap gap-1 border-b">
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

