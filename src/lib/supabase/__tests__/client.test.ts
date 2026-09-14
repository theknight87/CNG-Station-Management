import { afterEach, describe, expect, it, vi } from 'vitest'

/**
 * Regression tests for the defect behind the real-browser "JWT not yet valid"
 * investigation: the Supabase client used to be rebuilt inside
 * `useMemo(..., [session])`, so a new client — and therefore a new,
 * independent token path — appeared whenever Clerk handed back a new session
 * object, and once per component under StrictMode's double invocation.
 *
 * These assert the two properties that make the token path authoritative:
 * exactly one client, and a token always read from the CURRENT session at
 * request time rather than one captured when the client was built.
 */

const createClient = vi.hoisted(() => vi.fn())

vi.mock('@supabase/supabase-js', () => ({ createClient }))
vi.mock('@clerk/clerk-react', () => ({ useSession: () => ({ session: null }) }))
vi.mock('../config', () => ({
  readSupabaseConfig: () => ({ url: 'https://example.invalid', publishableKey: 'sb_publishable_test' }),
}))

async function freshModule() {
  vi.resetModules()
  createClient.mockReset()
  createClient.mockImplementation((_url: string, _key: string, opts: { accessToken: () => Promise<string | null> }) => ({
    __accessToken: opts.accessToken,
  }))
  return await import('../client')
}

afterEach(() => vi.resetModules())

describe('the Supabase client is a singleton', () => {
  it('CLIENT-1 builds exactly one client however many times it is requested', async () => {
    const mod = await freshModule()
    const a = mod.getSupabaseClient()
    const b = mod.getSupabaseClient()
    const c = mod.getSupabaseClient()

    expect(createClient).toHaveBeenCalledTimes(1)
    expect(a).toBe(b)
    expect(b).toBe(c)
  })

  it('CLIENT-2 keeps that one client across session changes', async () => {
    const mod = await freshModule()
    const first = mod.getSupabaseClient()

    mod.setSupabaseSession({ getToken: async () => 'token-one' })
    mod.setSupabaseSession({ getToken: async () => 'token-two' })

    expect(mod.getSupabaseClient()).toBe(first)
    expect(createClient).toHaveBeenCalledTimes(1)
  })
})

describe('the token path is authoritative', () => {
  it('CLIENT-3 reads the CURRENT session on every request, not one captured at build time', async () => {
    const mod = await freshModule()
    mod.setSupabaseSession({ getToken: async () => 'first-token' })
    const client = mod.getSupabaseClient() as unknown as { __accessToken: () => Promise<string | null> }

    await expect(client.__accessToken()).resolves.toBe('first-token')

    // Clerk rotates the session object; the SAME client must follow it.
    mod.setSupabaseSession({ getToken: async () => 'rotated-token' })
    await expect(client.__accessToken()).resolves.toBe('rotated-token')
  })

  it('CLIENT-4 yields null rather than a stale token once signed out', async () => {
    const mod = await freshModule()
    mod.setSupabaseSession({ getToken: async () => 'live-token' })
    const client = mod.getSupabaseClient() as unknown as { __accessToken: () => Promise<string | null> }
    await expect(client.__accessToken()).resolves.toBe('live-token')

    mod.setSupabaseSession(null)
    await expect(client.__accessToken()).resolves.toBeNull()
  })

  it('CLIENT-5 never falls back to anonymous when Clerk returns no token', async () => {
    const mod = await freshModule()
    mod.setSupabaseSession({ getToken: async () => null })
    const client = mod.getSupabaseClient() as unknown as { __accessToken: () => Promise<string | null> }
    await expect(client.__accessToken()).resolves.toBeNull()
  })
})
