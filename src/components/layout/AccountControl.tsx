import { LogOut } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { useAuth } from '@/features/auth/AuthProvider'
import type { AppRole } from '@/types/domain'

/**
 * The real account control.
 *
 * Identity comes from Supabase Auth; the ROLE comes from `app_users`. Nothing here is
 * fabricated — no placeholder avatar, no invented display name. When Clerk has
 * no name the control simply shows less.
 */

const ROLE_LABEL: Record<AppRole, string> = {
  admin: 'Administrator',
  manager: 'Regional Manager',
  engineer: 'Station Engineer',
  viewer: 'Viewer',
}

export function AccountControl({
  displayName,
  role,
  signOut,
}: {
  displayName: string | null
  role: AppRole | null
  signOut: React.ReactNode
}) {
  return (
    <div className="flex shrink-0 items-center gap-2">
      {displayName ? (
        <div className="hidden text-right sm:block">
          <p className="max-w-[16rem] truncate text-xs font-medium leading-tight" dir="auto">
            {displayName}
          </p>
          {/* 12px floor applies here too — this is the only place the role is shown. */}
          {role ? <p className="text-xs leading-tight text-muted-foreground">{ROLE_LABEL[role]}</p> : null}
        </div>
      ) : null}
      {signOut}
    </div>
  )
}

export function SupabaseAccountControl({ role }: { role: AppRole | null }) {
  const { user, signOut } = useAuth()
  const metadataName = typeof user?.user_metadata?.full_name === 'string'
    ? user.user_metadata.full_name
    : null
  const displayName = metadataName ?? user?.email ?? null

  return (
    <AccountControl
      displayName={displayName}
      role={role}
      signOut={
        <Button variant="ghost" size="icon" aria-label="Sign out" onClick={() => void signOut()}>
          <LogOut className="h-4 w-4" aria-hidden="true" />
        </Button>
      }
    />
  )
}
