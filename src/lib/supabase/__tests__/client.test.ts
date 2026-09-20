import { afterEach, describe, expect, it, vi } from 'vitest'

const createClient = vi.hoisted(() => vi.fn())

vi.mock('@supabase/supabase-js', () => ({ createClient }))
vi.mock('../config', () => ({
  readSupabaseConfig: () => ({ url: 'https://example.invalid', publishableKey: 'sb_publishable_test' }),
}))

async function freshModule() {
  vi.resetModules()
  createClient.mockReset()
  createClient.mockReturnValue({ auth: {} })
  return await import('../client')
}

afterEach(() => vi.resetModules())

describe('the Supabase client', () => {
  it('builds exactly one first-party auth client', async () => {
    const mod = await freshModule()
    const a = mod.getSupabaseClient()
    const b = mod.getSupabaseClient()

    expect(createClient).toHaveBeenCalledTimes(1)
    expect(a).toBe(b)
    expect(createClient).toHaveBeenCalledWith(
      'https://example.invalid',
      'sb_publishable_test',
      { auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true } },
    )
  })

  it('can reset the singleton for test isolation', async () => {
    const mod = await freshModule()
    mod.getSupabaseClient()
    mod.resetSupabaseClientForTests()
    mod.getSupabaseClient()
    expect(createClient).toHaveBeenCalledTimes(2)
  })
})
