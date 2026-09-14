import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { useSession } from '@clerk/clerk-react'
import { useMemo } from 'react'

import { readSupabaseConfig } from './config'

/**
 * Supabase client wired to Clerk using Supabase's CURRENT third-party auth
 * integration.
 *
 * The deprecated Clerk "Supabase JWT template" approach (deprecated 2025-04-01)
 * is deliberately NOT used. There is no JWT template, and this project's
 * Supabase JWT secret is never shared with Clerk. Instead Supabase is configured
 * to trust the Clerk issuer, and we hand it the Clerk *session token* through
 * the `accessToken` option. Supabase verifies the signature itself and exposes
 * the claims to Postgres, where our RLS policies read `sub` via cng_jwt_sub().
 *
 * `accessToken` is called per request, so token refresh is handled by Clerk and
 * we never cache, copy or pass a JWT around the component tree.
 *
 * Only browser-safe values are used here: the project URL and the publishable
 * key. The service-role key and the database password are server-side secrets
 * and must never reach this file.
 */
export function useSupabaseClient(): SupabaseClient | null {
  const { session } = useSession()

  return useMemo(() => {
    const config = readSupabaseConfig()
    if (!config) return null

    return createClient(config.url, config.publishableKey, {
      accessToken: async () => session?.getToken() ?? null,
    })
  }, [session])
}
