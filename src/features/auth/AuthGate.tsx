import type { ReactNode } from 'react'
import { SignedIn, SignedOut, SignInButton, UserButton, useAuth } from '@clerk/clerk-react'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAppUser } from '@/hooks/useAppUser'

/**
 * Minimal, functional authentication gate.
 *
 * Deliberately plain: the professional authentication experience is Prompt 7+.
 * What matters here is that every state is handled explicitly — loading,
 * signed out, signed in but not provisioned, awaiting approval, error — so no
 * state silently renders an empty application.
 *
 * This component is UX only. Hiding a screen is not security; the database
 * refuses unauthorized reads and writes regardless of what is rendered.
 */
function Centered({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <div className="w-full max-w-md">{children}</div>
    </div>
  )
}

function StatusCard({
  title,
  description,
  children,
}: {
  title: string
  description: string
  children?: ReactNode
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
        <CardDescription>{description}</CardDescription>
      </CardHeader>
      {children ? <CardContent>{children}</CardContent> : null}
    </Card>
  )
}

export function AuthGate({ children }: { children: ReactNode }) {
  const { isLoaded } = useAuth()
  const appUser = useAppUser()

  if (!isLoaded) {
    return (
      <Centered>
        <StatusCard title="Loading" description="Checking your session…" />
      </Centered>
    )
  }

  return (
    <>
      <SignedOut>
        <Centered>
          <StatusCard
            title="CNG Station Management"
            description="Sign in to continue. Access is granted by an administrator."
          >
            <SignInButton mode="modal">
              <Button className="w-full">Sign in</Button>
            </SignInButton>
          </StatusCard>
        </Centered>
      </SignedOut>

      <SignedIn>
        {appUser.status === 'loading' && (
          <Centered>
            <StatusCard title="Loading" description="Resolving your access…" />
          </Centered>
        )}

        {appUser.status === 'not_provisioned' && (
          <Centered>
            <StatusCard
              title="Account not yet provisioned"
              description="Your sign-in succeeded, but no application profile exists yet. This is created automatically; if it persists, contact an administrator."
            >
              <UserButton />
            </StatusCard>
          </Centered>
        )}

        {appUser.status === 'pending_approval' && (
          <Centered>
            <StatusCard
              title="Awaiting approval"
              description="Your account exists but has not been activated. An administrator must approve it and grant region access before you can see any data."
            >
              <UserButton />
            </StatusCard>
          </Centered>
        )}

        {appUser.status === 'error' && (
          <Centered>
            <StatusCard title="Authentication error" description={appUser.message}>
              <UserButton />
            </StatusCard>
          </Centered>
        )}

        {appUser.status === 'active' && children}
      </SignedIn>
    </>
  )
}
