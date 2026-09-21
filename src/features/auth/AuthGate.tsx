import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router-dom'

import { Button } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useAuth } from '@/features/auth/AuthProvider'
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
  const { session, loading, signOut } = useAuth()
  const appUser = useAppUser()
  const location = useLocation()

  if (loading) {
    return (
      <Centered>
        <StatusCard title="Loading" description="Checking your session…" />
      </Centered>
    )
  }

  if (!session) {
    return <Navigate to="/sign-in" replace state={{ from: `${location.pathname}${location.search}${location.hash}` }} />
  }

  const signOutButton = (
    <Button variant="outline" className="w-full" onClick={() => void signOut()}>
      Sign out
    </Button>
  )

  if (appUser.status === 'loading') return <Centered><StatusCard title="Loading" description="Resolving your access…" /></Centered>
  if (appUser.status === 'not_provisioned') {
    return <Centered><StatusCard title="Account not yet provisioned" description="Your sign-in succeeded, but no application profile exists yet. If this persists, contact an administrator.">{signOutButton}</StatusCard></Centered>
  }
  if (appUser.status === 'pending_approval') {
    return <Centered><StatusCard title="Awaiting approval" description="Your account exists but has not been activated. An administrator must approve it and grant region access before you can see any data.">{signOutButton}</StatusCard></Centered>
  }
  if (appUser.status === 'error') {
    return <Centered><StatusCard title="Authentication error" description={appUser.message}>{signOutButton}</StatusCard></Centered>
  }
  if (appUser.status === 'unauthenticated') return null
  return children
}
