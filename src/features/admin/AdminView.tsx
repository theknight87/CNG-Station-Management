import { PermissionDenied } from '@/components/states/AppStates'
import { NotImplemented } from '@/components/states/AppStates'
import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { useAppUser } from '@/hooks/useAppUser'

/**
 * Admin landing.
 *
 * Non-admins reach a PERMISSION state, not an empty page and not a redirect.
 * This is UX: the database refuses the underlying reads regardless (CLAUDE.md
 * §10), and this screen exists so a user understands WHY they see nothing
 * rather than assuming the system is broken.
 */
export function AdminView() {
  const appUser = useAppUser()
  const role = appUser.status === 'active' ? appUser.user.role : null

  return (
    <PageContainer>
      <PageHeader
        title="Admin"
        description="Users, region access, imports and the data-quality workflow."
      />
      {role === 'admin' ? (
        <NotImplemented
          feature="Administration"
          phase="planned for Prompts 10-14 and 21 — users and region access, station alias confirmation, the SRV mapping queue, and the controlled import"
        />
      ) : (
        <PermissionDenied
          what="administration"
          detail="Administration covers users, region access, imports and data-quality resolution. It is restricted to administrators, and the database enforces that independently of what this screen shows."
        />
      )}
    </PageContainer>
  )
}
