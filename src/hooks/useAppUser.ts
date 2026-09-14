import { useEffect, useState } from 'react'
import { useSession } from '@clerk/clerk-react'

import { useSupabaseClient } from '@/lib/supabase/client'
import type { AppRole } from '@/types/domain'

export interface AppUser {
  id: string
  clerk_user_id: string
  role: AppRole
  is_active: boolean
  full_name: string | null
}

export type AppUserState =
  | { status: 'loading' }
  | { status: 'unauthenticated' }
  | { status: 'not_provisioned' }   // signed in, but no app_users row yet
  | { status: 'pending_approval'; user: AppUser }
  | { status: 'active'; user: AppUser }
  | { status: 'error'; message: string }

/**
 * Resolves the caller's application profile from the database.
 *
 * This is the authorization state the UI may *display*. It is never the
 * authorization itself: every read and write is independently enforced by RLS,
 * so a tampered client can at most mislead its own user.
 *
 * A user whose row exists but is not yet activated can still read that row (the
 * app_users self-select policy does not require activation), which is what lets
 * the UI say "awaiting approval" instead of showing an unexplained empty app.
 */
export function useAppUser(): AppUserState {
  const { session, isLoaded } = useSession()
  const supabase = useSupabaseClient()
  const [state, setState] = useState<AppUserState>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (!isLoaded) return
      if (!session) {
        if (!cancelled) setState({ status: 'unauthenticated' })
        return
      }
      if (!supabase) {
        if (!cancelled) setState({ status: 'error', message: 'Supabase is not configured.' })
        return
      }

      const { data, error } = await supabase
        .from('app_users')
        .select('id, clerk_user_id, role, is_active, full_name')
        .maybeSingle()

      if (cancelled) return
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }
      if (!data) {
        setState({ status: 'not_provisioned' })
        return
      }
      const user = data as AppUser
      setState(user.is_active ? { status: 'active', user } : { status: 'pending_approval', user })
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [isLoaded, session, supabase])

  return state
}
