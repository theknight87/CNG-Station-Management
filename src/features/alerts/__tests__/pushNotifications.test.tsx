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
 * 5. **subscribe() cannot run before the service worker is ACTIVE.** This is the
 *    production defect of Prompt 15.2B: `register()` resolves while the worker
 *    may still be `installing`, and subscribing then fails with "Subscription
 *    failed - no active Service Worker".
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
const { urlBase64ToUint8Array, registerActiveServiceWorker } = await import(
  '@/features/alerts/usePushNotifications'
)

const permission = vi.hoisted(() => ({ value: 'default' as NotificationPermission, requested: 0 }))
const subscribeArgs = vi.hoisted(() => ({ last: null as Record<string, unknown> | null, count: 0 }))
const sw = vi.hoisted(() => ({
  registerCount: 0,
  /** Resolves the pending activation in `activation: 'deferred'` mode. */
  activate: () => {},
}))

/**
 * @param activation how the worker reaches the ACTIVE state:
 *   - `immediate`: already active, as on every visit after the first;
 *   - `deferred`: `register()` resolves with an INACTIVE worker and
 *     `navigator.serviceWorker.ready` settles only when the test calls
 *     `sw.activate()` — the real first-registration sequence, and the one the
 *     production bug raced against;
 *   - `never`: activation never completes.
 */
function installPushEnvironment(
  opts: {
    existing?: boolean
    /** false = nothing registered yet when the page probes on mount. */
    probeRegistration?: boolean
    activation?: 'immediate' | 'deferred' | 'never'
  } = {},
) {
  const activation = opts.activation ?? 'immediate'
  permission.value = 'default'
  permission.requested = 0
  subscribeArgs.last = null
  subscribeArgs.count = 0
  sw.registerCount = 0

  const subscription = {
    endpoint: 'https://push.example.test/abc123',
    toJSON: () => ({ endpoint: 'https://push.example.test/abc123', keys: { p256dh: 'PPP', auth: 'AAA' } }),
    getKey: () => null,
  }

  const registration: Record<string, unknown> = {
    // `null` until activation completes — exactly what the browser reports
    // while the worker is still installing.
    active: activation === 'immediate' ? { state: 'activated' } : null,
    pushManager: {
      getSubscription: () => Promise.resolve(opts.existing ? subscription : null),
      subscribe: (args: Record<string, unknown>) => {
        subscribeArgs.count += 1
        subscribeArgs.last = args
        return Promise.resolve(subscription)
      },
    },
  }

  const ready =
    activation === 'immediate'
      ? Promise.resolve(registration)
      : new Promise<unknown>((resolve) => {
          if (activation === 'deferred') {
            sw.activate = () => {
              registration.active = { state: 'activated' }
              resolve(registration)
            }
          }
          // 'never': the promise is simply never settled.
        })

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
      getRegistration: () =>
        Promise.resolve(opts.probeRegistration === false ? undefined : registration),
      register: () => {
        sw.registerCount += 1
        return Promise.resolve(registration)
      },
      ready,
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

/**
 * THE PRODUCTION DEFECT (Prompt 15.2B).
 *
 * Reported from https://cng-station-management.pages.dev/alerts as:
 *
 *     Failed to execute 'subscribe' on 'PushManager':
 *     Subscription failed - no active Service Worker
 *
 * `navigator.serviceWorker.register()` resolves as soon as the REGISTRATION
 * exists; its worker may still be `installing`. `pushManager.subscribe()`
 * requires an ACTIVE worker. The old code subscribed immediately after
 * registering, so a first click on a fresh browser raced activation and lost —
 * while a later click, with a worker already activated, appeared to work. That
 * intermittency is what made it look like a configuration problem.
 */
describe('Service worker must be ACTIVE before subscribing', () => {
  it('does not call subscribe() while the worker is still installing', async () => {
    installPushEnvironment({ activation: 'deferred' })
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))

    // Registration has happened and permission was granted, but activation has
    // not completed. Give the microtask queue every chance to run ahead.
    await Promise.resolve()
    await new Promise((r) => setTimeout(r, 0))

    expect(sw.registerCount).toBe(1)
    expect(permission.requested).toBe(1)
    // THE assertion this whole file exists for: no subscribe before ACTIVE.
    expect(subscribeArgs.count).toBe(0)
    expect(rpc.calls).toHaveLength(0)
    expect(await screen.findByRole('button', { name: /enabling/i })).toBeDefined()

    // Now let the worker activate. Only then may subscribe() run.
    sw.activate()
    expect(await screen.findByText(/notifications are enabled/i)).toBeDefined()
    expect(subscribeArgs.count).toBe(1)
  })

  it('subscribes without waiting when the worker is already active', async () => {
    // The repeat-visit path must not be slowed down by the fix.
    installPushEnvironment({ activation: 'immediate' })
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    expect(await screen.findByText(/notifications are enabled/i)).toBeDefined()
    expect(subscribeArgs.count).toBe(1)
  })

  it('returns the registration directly when it is already active', async () => {
    installPushEnvironment({ activation: 'immediate' })
    const reg = await registerActiveServiceWorker()
    expect((reg as unknown as { active: unknown }).active).toBeTruthy()
  })

  it('reports a bounded failure instead of spinning forever if activation never completes', async () => {
    installPushEnvironment({ activation: 'never' })
    // Called directly with a short bound: the production default is 15s, and a
    // test must not wait for it. `ready` never settles here.
    await expect(registerActiveServiceWorker(20)).rejects.toThrow(/did not start/i)
  })
})

describe('Repeated clicks and existing subscriptions', () => {
  it('a second click while the first is in flight starts nothing new', async () => {
    installPushEnvironment({ activation: 'deferred' })
    render(<EnableNotifications />)
    const button = await screen.findByRole('button', { name: /enable notifications/i })
    await userEvent.click(button)
    // The button is disabled while working, but that is UX, not a guarantee —
    // call the handler again the way a keyboard repeat or a stray event would.
    await userEvent.click(await screen.findByRole('button', { name: /enabling/i }))

    sw.activate()
    expect(await screen.findByText(/notifications are enabled/i)).toBeDefined()
    // One registration, one subscription, one save. Not two of anything.
    expect(sw.registerCount).toBe(1)
    expect(subscribeArgs.count).toBe(1)
    expect(rpc.calls.filter((c) => c.fn === 'cng_save_push_subscription')).toHaveLength(1)
  })

  it('reuses an existing subscription rather than minting a second endpoint', async () => {
    // Nothing registered when the page probed, so the control is offered; the
    // browser has nonetheless retained a subscription from a previous session.
    installPushEnvironment({ existing: true, probeRegistration: false })
    render(<EnableNotifications />)
    await userEvent.click(await screen.findByRole('button', { name: /enable notifications/i }))
    expect(await screen.findByText(/notifications are enabled/i)).toBeDefined()

    // Re-subscribing would strand the row saved against the old endpoint.
    expect(subscribeArgs.count).toBe(0)
    const call = rpc.calls.find((c) => c.fn === 'cng_save_push_subscription')
    expect(call?.args.p_endpoint).toBe('https://push.example.test/abc123')
  })
})
