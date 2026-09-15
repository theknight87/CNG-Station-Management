import { SignOutButton, useUser } from '@clerk/clerk-react'
import { LogOut } from 'lucide-react'

import { Button } from '@/components/ui/button'
import type { AppRole } from '@/types/domain'

/**
 * The real account control.
 *
 * Identity comes from Clerk; the ROLE comes from `app_users`. Nothing here is
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

export function ClerkAccountControl({ role }: { role: AppRole | null }) {
  const { user } = useUser()
  const displayName = user?.fullName ?? user?.primaryEmailAddress?.emailAddress ?? null

  return (
    <AccountControl
      displayName={displayName}
      role={role}
      signOut={
        <SignOutButton>
          <Button variant="ghost" size="icon" aria-label="Sign out">
            <LogOut className="h-4 w-4" aria-hidden="true" />
          </Button>
        </SignOutButton>
      }
    />
  )
}
