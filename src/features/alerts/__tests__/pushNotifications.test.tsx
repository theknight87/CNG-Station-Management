import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

/**
 * Web Push opt-in.
 *
 * What these defend, hardest first:
 *
 * 1. **Permission is never requested without an explicit click.** A prompt the
 *    user did not ask for is how a site gets permanently blocked.
 * 2. **The client never supplies the owning user.** `cng_save_push_subscription`
 *    fills `app_user_id` from the session, so the RPC arguments must contain no
 *    user identifier at all.
 * 3. **Only the PUBLIC VAPID key is used in the browser.** The private key must
 *    appear nowhere in frontend code.
 * 4. Denied is a settled answer, not an error to retry.
 */

const rpc = vi.hoisted(() => ({ calls: [] as { fn: string; args: Record<string, unknown> }[], error: null as null | { message: string } }))

vi.mock('@/lib/supabase/client', () => ({
  useSupabaseClient: () => ({
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpc.calls.push({ fn, args })
      return Promise.resolve({ data: 'sub-1', error: rpc.error })
    },
  }),
}))

const { EnableNotifications } = await import('@/features/alerts/EnableNotifications')
const { urlBase64ToUint8Array } = await import('@/features/alerts/usePushNotifications')

const permission = vi.hoisted(() => ({ value: 'default' as NotificationPermission, requested: 0 }))
const subscribeArgs = vi.hoisted(() => ({ last: null as Record<string, unknown> | null }))

function installPushEnvironment(opts: { existing?: boolean } = {}) {
  permission.value = 'default'
  permission.requested = 0
  subscribeArgs.last = null

  const subscription = {
    endpoint: 'https://push.example.test/abc123',
    toJSON: () => ({ endpoint: 'https://push.example.test/abc123', keys: { p256dh: 'PPP', auth: 'AAA' } }),
    getKey: () => null,
  }

  const registration = {
    pushManager: {
      getSubscription: () => Promise.resolve(opts.existing ? subscription : null),
      subscribe: (args: Record<string, unknown>) => {
        subscribeArgs.last = args
        return Promise.resolve(subscription)
      },
    },
  }

  vi.stubGlobal('Notification', {
    get permission() {
      return permission.value
    },
    requestPermission: () => {
      permission.requested += 1
      return Promise.resolve(permission.value === 'default' ? 'granted' : permission.value)
    },
  })
  // Augment the REAL navigator rather than replacing it: userEvent needs the
  // genuine object, and swapping it out breaks the interactions under test.
  Object.defineProperty(navigator, 'serviceWorker', {
    configurable: true,
    value: {
      getRegistration: () => Promise.resolve(registration),
      register: () => Promise.resolve(registration),
    },
  })
  vi.stubGlobal('PushManager', function PushManager() {})
}

beforeEach(() => {
  rpc.calls = []
  rpc.error = null
  // A syntactically valid base64url string. Not a real key, and not a secret:
  // the VAPID PUBLIC key is browser-visible by design.
  vi.stubEnv('VITE_VAPID_PUBLIC_KEY', 'BFakePublicKeyForTestsOnly-not-a-secret')
  installPushEnvironment()
})
afterEach(() => {
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
  vi.clearAllMocks()
})

describe('Permission is opt-in only', () => {
  it('requests no permission on render', async () => {
    render(<EnableNotifications />)
    expect(await screen.findByRole('button', { name: /enable notifications/i })).toBeDefined()
    // THE key assertion: rendering the control asked the user nothing.
    expect(permission.requested).toBe(0)
    expect(rpc.calls).toHaveLength(0)
  })

  it('requests permission only after an explicit click', async () => {
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    expect(permission.requested).toBe(1)
  })

  it('treats a denied permission as a settled answer, not an error', async () => {
    render(<EnableNotifications />)
    permission.value = 'denied'
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    expect(await screen.findByText(/blocked for this site/i)).toBeDefined()
    // Nothing was stored, and no error state is shown.
    expect(rpc.calls).toHaveLength(0)
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('does not subscribe when permission is already denied', async () => {
    permission.value = 'denied'
    render(<EnableNotifications />)
    expect(await screen.findByText(/blocked for this site/i)).toBeDefined()
    expect(screen.queryByRole('button', { name: /enable notifications/i })).toBeNull()
    expect(permission.requested).toBe(0)
  })
})

describe('Subscription ownership and key handling', () => {
  it('saves through the database function and supplies no user identifier', async () => {
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    await screen.findByText(/notifications are enabled/i)

    const call = rpc.calls.find((c) => c.fn === 'cng_save_push_subscription')
    expect(call).toBeDefined()
    expect(Object.keys(call!.args).sort()).toEqual(['p_auth', 'p_endpoint', 'p_p256dh', 'p_user_agent'])
    // The owning user is filled server-side; the client cannot name one.
    expect(JSON.stringify(call!.args)).not.toMatch(/app_user|user_id|clerk/i)
  })

  it('subscribes with the PUBLIC VAPID key and userVisibleOnly', async () => {
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    await screen.findByText(/notifications are enabled/i)
    expect(subscribeArgs.last?.userVisibleOnly).toBe(true)
    expect(subscribeArgs.last?.applicationServerKey).toBeInstanceOf(Uint8Array)
  })

  it('states a save failure instead of claiming success', async () => {
    rpc.error = { message: 'new row violates row-level security policy' }
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    expect(await screen.findByRole('alert')).toBeDefined()
    expect(screen.queryByText(/notifications are enabled/i)).toBeNull()
  })

  it('reflects an existing subscription without prompting', async () => {
    installPushEnvironment({ existing: true })
    render(<EnableNotifications />)
    expect(await screen.findByText(/notifications are enabled/i)).toBeDefined()
    expect(permission.requested).toBe(0)
  })
})

describe('Configuration states', () => {
  it('says so when the deployment has no public key, rather than failing silently', async () => {
    vi.stubEnv('VITE_VAPID_PUBLIC_KEY', '')
    render(<EnableNotifications />)
    expect(await screen.findByText(/not configured for this deployment/i)).toBeDefined()
    expect(permission.requested).toBe(0)
  })

  it('decodes a base64url key to bytes', () => {
    const bytes = urlBase64ToUint8Array('AQAB')
    expect(bytes).toBeInstanceOf(Uint8Array)
    expect(Array.from(bytes)).toEqual([1, 0, 1])
  })
})
