import { createClient, type SupabaseClient } from '@supabase/supabase-js'

import { readSupabaseConfig } from './config'

/**
 * ONE Supabase client for the whole application. Supabase Auth owns session
 * persistence and token refresh, so database requests automatically carry the
 * current first-party access token.
 *
 * Only browser-safe values are used here: the project URL and the publishable
 * key. The service-role key and the database password are server-side secrets
 * and must never reach this file.
 */

let client: SupabaseClient | null = null

/** Test seam: forget the singleton so a test can build a fresh one. */
export function resetSupabaseClientForTests(): void {
  client = null
}

export function getSupabaseClient(): SupabaseClient | null {
  if (client) return client

  const config = readSupabaseConfig()
  if (!config) return null

  client = createClient(config.url, config.publishableKey, {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  })
  return client
}

export function useSupabaseClient(): SupabaseClient | null {
  return getSupabaseClient()
}
