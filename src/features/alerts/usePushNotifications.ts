import { useCallback, useEffect, useRef, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * Web Push subscription, opt-in only.
 *
 * PERMISSION IS NEVER REQUESTED ON LOAD. `Notification.requestPermission()` is
 * called only from an explicit click, because a permission prompt a user did
 * not ask for is how a site gets permanently blocked — and because subscribing
 * someone silently is not consent.
 *
 * THE PUBLIC KEY IS NOT A SECRET. `VITE_VAPID_PUBLIC_KEY` is compiled into the
 * bundle by design: the browser needs it to create a subscription. Its private
 * counterpart lives only in Edge Function secrets and never appears in any
 * `VITE_*` variable, in source, or in the bundle.
 *
 * SUBSCRIBING REQUIRES AN *ACTIVE* SERVICE WORKER, NOT MERELY A REGISTERED
 * ONE. `register()` resolves as soon as the registration object exists, while
 * its worker may still be `installing`. Calling `pushManager.subscribe()` at
 * that moment fails with "Subscription failed - no active Service Worker" —
 * which is why the first click on a fresh browser failed and a later one, with
 * a worker already activated, appeared to work. The wait is therefore explicit.
 *
 * THE SUBSCRIPTION IS SAVED BY THE DATABASE, NOT BY THE CLIENT.
 * `cng_save_push_subscription` fills `app_user_id` from the session, so a
 * caller cannot register a subscription for another user however the request is
 * shaped.
 */

export type PushState =
  /** This browser cannot do Web Push at all. */
  | { status: 'unsupported' }
  /** The build has no public key, so subscribing is impossible. */
  | { status: 'unconfigured' }
  | { status: 'idle' }
  | { status: 'working' }
  | { status: 'subscribed' }
  /** The user said no. This is a settled answer, not an error to retry. */
  | { status: 'denied' }
  | { status: 'error'; message: string }

/**
 * Read at call time rather than captured at module load.
 *
 * Vite substitutes `import.meta.env.VITE_*` statically wherever it appears, so
 * this is exactly as build-time-resolved in production as a module constant —
 * but it means the value is observable in tests, and a deployment that forgot
 * the variable reports "unconfigured" rather than silently doing nothing.
 */
function vapidPublicKey(): string {
  return import.meta.env.VITE_VAPID_PUBLIC_KEY ?? ''
}

/**
 * base64url -> bytes, the form PushManager requires.
 *
 * Backed by an explicit ArrayBuffer so the result is a `BufferSource`
 * TypeScript accepts for `applicationServerKey`; a bare `new Uint8Array(n)` is
 * typed over `ArrayBufferLike`, which may be a SharedArrayBuffer.
 */
export function urlBase64ToUint8Array(base64: string): Uint8Array<ArrayBuffer> {
  const padding = '='.repeat((4 - (base64.length % 4)) % 4)
  const normalized = (base64 + padding).replace(/-/g, '+').replace(/_/g, '/')
  const raw = atob(normalized)
  const out = new Uint8Array(new ArrayBuffer(raw.length))
  for (let i = 0; i < raw.length; i += 1) out[i] = raw.charCodeAt(i)
  return out
}

function keyToBase64(key: ArrayBuffer | null): string {
  if (!key) return ''
  const bytes = new Uint8Array(key)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

/**
 * Register the service worker and resolve only once it is ACTIVE.
 *
 * This is the fix for "Subscription failed - no active Service Worker".
 * `navigator.serviceWorker.ready` resolves with the registration for this
 * page's scope once that registration has an active worker, so it is the
 * correct lifecycle signal. `registration.active` is checked first because on
 * every visit after the first the worker is already active and there is nothing
 * to wait for.
 *
 * The wait is BOUNDED. `ready` never rejects, so without a bound a browser that
 * never activates the worker would leave the button spinning forever. A stated
 * failure is more honest than an indefinite "Enabling…".
 */
export async function registerActiveServiceWorker(
  timeoutMs = 15_000,
): Promise<ServiceWorkerRegistration> {
  // A missing or non-JavaScript /sw.js rejects here, which surfaces as a real
  // error rather than an endless wait.
  const registration = await navigator.serviceWorker.register('/sw.js')
  if (registration.active) return registration

  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      navigator.serviceWorker.ready,
      new Promise<never>((_resolve, reject) => {
        timer = setTimeout(
          () => reject(new Error('The notification service worker did not start in this browser.')),
          timeoutMs,
        )
      }),
    ])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

export function pushSupported(): boolean {
  return (
    typeof window !== 'undefined' &&
    'serviceWorker' in navigator &&
    'PushManager' in window &&
    typeof Notification !== 'undefined'
  )
}

export function usePushNotifications(): {
  state: PushState
  enable: () => Promise<void>
} {
  const supabase = useSupabaseClient()
  const [state, setState] = useState<PushState>({ status: 'idle' })
  /**
   * Guards against a second click landing while the first is still in flight.
   * The button is disabled while working, but a disabled button is UX, not a
   * guarantee — a keyboard repeat or a programmatic call must not start a
   * second registration/subscribe race.
   */
  const inFlight = useRef(false)

  // Reflect what is already true WITHOUT prompting: reading the permission
  // value and an existing subscription asks the user nothing.
  useEffect(() => {
    let cancelled = false
    async function probe() {
      if (!pushSupported()) {
        if (!cancelled) setState({ status: 'unsupported' })
        return
      }
      if (!vapidPublicKey()) {
        if (!cancelled) setState({ status: 'unconfigured' })
        return
      }
      if (Notification.permission === 'denied') {
        if (!cancelled) setState({ status: 'denied' })
        return
      }
      try {
        const reg = await navigator.serviceWorker.getRegistration()
        const existing = await reg?.pushManager.getSubscription()
        if (!cancelled) setState({ status: existing ? 'subscribed' : 'idle' })
      } catch {
        if (!cancelled) setState({ status: 'idle' })
      }
    }
    void probe()
    return () => {
      cancelled = true
    }
  }, [])

  const enable = useCallback(async () => {
    if (inFlight.current) return
    if (!pushSupported()) {
      setState({ status: 'unsupported' })
      return
    }
    const publicKey = vapidPublicKey()
    if (!publicKey) {
      setState({ status: 'unconfigured' })
      return
    }
    if (!supabase) {
      setState({ status: 'error', message: 'Not connected to the database.' })
      return
    }

    inFlight.current = true
    setState({ status: 'working' })
    try {
      // Only now, and only because the user clicked. Asked BEFORE the worker is
      // registered so a user who declines gets no service worker at all.
      const permission = await Notification.requestPermission()
      if (permission !== 'granted') {
        setState({ status: 'denied' })
        return
      }

      // Waits for activation. Subscribing before this resolves is the defect
      // this replaces.
      const registration = await registerActiveServiceWorker()

      // IDEMPOTENT. A browser has at most one subscription per registration, so
      // an existing one is reused rather than replaced: re-subscribing would
      // mint a new endpoint and strand the row already saved for the old one.
      // Re-saving is still correct — `cng_save_push_subscription` upserts on the
      // endpoint and reactivates it, and derives the owner from the session.
      const subscription =
        (await registration.pushManager.getSubscription()) ??
        (await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(publicKey),
        }))

      const json = subscription.toJSON() as { endpoint?: string; keys?: Record<string, string> }
      const { error } = await supabase.rpc('cng_save_push_subscription', {
        p_endpoint: json.endpoint ?? subscription.endpoint,
        p_p256dh: json.keys?.p256dh ?? keyToBase64(subscription.getKey('p256dh')),
        p_auth: json.keys?.auth ?? keyToBase64(subscription.getKey('auth')),
        p_user_agent: navigator.userAgent,
      })
      if (error) {
        setState({ status: 'error', message: error.message })
        return
      }
      setState({ status: 'subscribed' })
    } catch (e) {
      setState({ status: 'error', message: e instanceof Error ? e.message : 'Could not enable notifications.' })
    } finally {
      inFlight.current = false
    }
  }, [supabase])

  return { state, enable }
}
