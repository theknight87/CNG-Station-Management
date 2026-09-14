import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { SignedIn, SignedOut, SignOutButton, useSession, useUser } from '@clerk/clerk-react'

import { Button, buttonVariants } from '@/components/ui/button'
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card'
import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * TEMPORARY Prompt-5 authentication test page.
 *
 * Purpose: prove the real path Clerk -> Supabase -> PostgreSQL RLS with a
 * genuine Clerk-issued session token, and surface the Clerk user id needed for
 * the one-time first-administrator bootstrap.
 *
 * It is deliberately reachable while the account is still INACTIVE — that is
 * the state a first sign-in produces, and the owner needs to read their Clerk
 * user id from it. Showing this page grants nothing: every value below is what
 * the database chose to return under RLS for this caller. An inactive user
 * sees their own row and nothing else, because the policies say so, not
 * because this page hides anything.
 *
 * Remove this route when the real application UI lands (Prompt 7+).
 */

interface AppUserRow {
  id: string
  clerk_user_id: string
  role: string
  is_active: boolean
  email: string | null
  full_name: string | null
}

interface RegionGrant {
  can_map: boolean
  regions: { code: string; name: string } | null
}

interface Probe {
  appUser: AppUserRow | null
  appUserError: string | null
  grants: RegionGrant[] | null
  grantsError: string | null
  visibleRegions: { code: string; name: string }[] | null
  visibleRegionsError: string | null
  tokenPresent: boolean
  loading: boolean
}

const EMPTY: Probe = {
  appUser: null,
  appUserError: null,
  grants: null,
  grantsError: null,
  visibleRegions: null,
  visibleRegionsError: null,
  tokenPresent: false,
  loading: true,
}

function Row({ label, value }: { label: string; value: React.ReactNode }) {
  return (
    <div className="grid grid-cols-[minmax(11rem,auto)_1fr] gap-3 border-b py-2 text-sm last:border-b-0">
      <span className="text-muted-foreground">{label}</span>
      <span className="break-all font-mono">{value}</span>
    </div>
  )
}

function SignedInProbe() {
  const { user } = useUser()
  const { session } = useSession()
  const supabase = useSupabaseClient()
  const [probe, setProbe] = useState<Probe>(EMPTY)

  useEffect(() => {
    let cancelled = false

    async function run() {
      if (!session) return
      if (!supabase) {
        if (!cancelled) {
          setProbe({ ...EMPTY, loading: false, appUserError: 'Supabase is not configured (.env.local).' })
        }
        return
      }

      // Presence only. The token itself is never rendered, logged or stored.
      const token = await session.getToken()

      const [appUserRes, grantsRes, regionsRes] = await Promise.all([
        supabase.from('app_users').select('id, clerk_user_id, role, is_active, email, full_name').maybeSingle(),
        supabase.from('user_region_access').select('can_map, regions(code, name)'),
        supabase.from('regions').select('code, name').order('sort_order'),
      ])

      if (cancelled) return
      setProbe({
        loading: false,
        tokenPresent: Boolean(token),
        appUser: (appUserRes.data as AppUserRow | null) ?? null,
        appUserError: appUserRes.error?.message ?? null,
        grants: (grantsRes.data as unknown as RegionGrant[] | null) ?? null,
        grantsError: grantsRes.error?.message ?? null,
        visibleRegions: regionsRes.data ?? null,
        visibleRegionsError: regionsRes.error?.message ?? null,
      })
    }

    void run()
    return () => {
      cancelled = true
    }
  }, [session, supabase])

  const grantedRegions = (probe.grants ?? [])
    .map((g) => g.regions?.name)
    .filter((n): n is string => Boolean(n))

  return (
    <Card>
      <CardHeader>
        <CardTitle>Authentication test</CardTitle>
        <CardDescription>
          Temporary Prompt-5 page. Every value below was returned by PostgreSQL under RLS for a
          real Clerk-issued session token.
        </CardDescription>
      </CardHeader>
      <CardContent className="space-y-6">
        <section>
          <h2 className="mb-2 text-sm font-semibold">Clerk</h2>
          <Row label="Clerk User ID" value={user?.id ?? '—'} />
          <Row label="Primary email" value={user?.primaryEmailAddress?.emailAddress ?? '—'} />
          <Row label="Session token obtained" value={probe.tokenPresent ? 'yes' : 'no'} />
        </section>

        <section>
          <h2 className="mb-2 text-sm font-semibold">Supabase — application profile</h2>
          {probe.loading && <Row label="Status" value="loading…" />}
          {probe.appUserError && <Row label="Error" value={probe.appUserError} />}
          {!probe.loading && !probe.appUserError && !probe.appUser && (
            <Row
              label="app_users row"
              value="none — the Clerk webhook has not created it yet (or it did not reach Supabase)"
            />
          )}
          {probe.appUser && (
            <>
              <Row label="Application role" value={probe.appUser.role} />
              <Row label="is_active" value={String(probe.appUser.is_active)} />
              <Row label="app_users.id" value={probe.appUser.id} />
              <Row label="clerk_user_id (from DB)" value={probe.appUser.clerk_user_id} />
            </>
          )}
        </section>

        <section>
          <h2 className="mb-2 text-sm font-semibold">Supabase — authorized Regions</h2>
          {probe.grantsError && <Row label="Error" value={probe.grantsError} />}
          <Row
            label="Granted (user_region_access)"
            value={grantedRegions.length > 0 ? grantedRegions.join(', ') : 'none'}
          />
          {probe.visibleRegionsError && <Row label="regions error" value={probe.visibleRegionsError} />}
          <Row
            label="Visible under RLS (regions)"
            value={
              probe.visibleRegions && probe.visibleRegions.length > 0
                ? probe.visibleRegions.map((r) => r.name).join(', ')
                : 'none'
            }
          />
        </section>

        <div className="flex gap-3">
          <SignOutButton>
            <Button variant="outline">Sign out</Button>
          </SignOutButton>
          <Link to="/" className={buttonVariants({ variant: 'ghost' })}>
            Go to application
          </Link>
        </div>
      </CardContent>
    </Card>
  )
}

export function AuthTestPage() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-background p-6">
      <div className="w-full max-w-2xl">
        <SignedOut>
          <Card>
            <CardHeader>
              <CardTitle>Not signed in</CardTitle>
              <CardDescription>Sign in with Clerk to run the authentication test.</CardDescription>
            </CardHeader>
            <CardContent>
              <Link to="/sign-in" className={buttonVariants()}>
                Go to /sign-in
              </Link>
            </CardContent>
          </Card>
        </SignedOut>
        <SignedIn>
          <SignedInProbe />
        </SignedIn>
      </div>
    </div>
  )
}
