import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { useSession } from '@clerk/clerk-react'

import { readSupabaseConfig } from './config'

/**
 * ONE Supabase client for the whole application, wired to Clerk using
 * Supabase's CURRENT third-party auth integration.
 *
 * WHY A SINGLETON. This hook previously built the client inside
 * `useMemo(..., [session])`, so a new client appeared whenever Clerk handed
 * back a new session object — and one per component under React StrictMode's
 * double invocation. Several clients means several independent token paths
 * racing each other, which is precisely what makes an auth failure appear on
 * one request and not the next. There is now exactly one client and exactly
 * one path to a token.
 *
 * The deprecated Clerk "Supabase JWT template" approach (deprecated 2025-04-01)
 * is deliberately NOT used. There is no JWT template, and this project's
 * Supabase JWT secret is never shared with Clerk. Supabase is configured to
 * trust the Clerk issuer, and we hand it the Clerk *session token* through the
 * `accessToken` option. Supabase verifies the signature itself and exposes the
 * claims to Postgres, where RLS reads `sub` via cng_jwt_sub().
 *
 * `accessToken` is invoked per request and always reads the CURRENT session, so
 * Clerk owns refresh and we never cache, copy or pass a JWT around the tree.
 *
 * Only browser-safe values are used here: the project URL and the publishable
 * key. The service-role key and the database password are server-side secrets
 * and must never reach this file.
 */

type TokenSource = { getToken: () => Promise<string | null> } | null

let client: SupabaseClient | null = null
let currentSession: TokenSource = null

/**
 * Points the single client at the current Clerk session. Exported for tests;
 * application code goes through `useSupabaseClient`.
 */
export function setSupabaseSession(session: TokenSource): void {
  currentSession = session
}

/** Test seam: forget the singleton so a test can build a fresh one. */
export function resetSupabaseClientForTests(): void {
  client = null
  currentSession = null
}

export function getSupabaseClient(): SupabaseClient | null {
  if (client) return client

  const config = readSupabaseConfig()
  if (!config) return null

  client = createClient(config.url, config.publishableKey, {
    // Read through `currentSession` at call time, never a captured session:
    // the client outlives any single Clerk session object.
    accessToken: async () => (await currentSession?.getToken()) ?? null,
  })
  return client
}

export function useSupabaseClient(): SupabaseClient | null {
  const { session } = useSession()

  // A plain assignment, not a subscription: it must happen before any child
  // effect fires a query, which rules out useEffect (parent effects run last).
  // Re-running it under StrictMode's double render is a no-op.
  setSupabaseSession(session ?? null)

  return getSupabaseClient()
}
