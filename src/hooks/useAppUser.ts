import { createContext, createElement, useContext, useEffect, useState, type ReactNode } from 'react'

import { useAuth } from '@/features/auth/AuthProvider'
import { useSupabaseClient } from '@/lib/supabase/client'
import type { AppRole } from '@/types/domain'

export interface AppUser {
  id: string
  auth_user_id: string | null
  clerk_user_id: string | null
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

const AppUserContext = createContext<AppUserState | null>(null)

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
export function AppUserProvider({ children }: { children: ReactNode }) {
  const { session, loading } = useAuth()
  const supabase = useSupabaseClient()
  const [state, setState] = useState<AppUserState>({ status: 'loading' })

  useEffect(() => {
    let cancelled = false

    async function load() {
      if (loading) return
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
        .select('id, auth_user_id, clerk_user_id, role, is_active, full_name')
        .eq('auth_user_id', session.user.id)
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
  }, [loading, session, supabase])

  return createElement(AppUserContext.Provider, { value: state }, children)
}

export function useAppUser(): AppUserState {
  const state = useContext(AppUserContext)
  if (!state) throw new Error('useAppUser must be used inside AppUserProvider')
  return state
}
