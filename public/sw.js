/**
 * CNG Station Management service worker — Web Push only.
 *
 * It caches nothing and intercepts no fetch. Its entire job is to receive a
 * push message and show it, so it cannot affect how the application loads or
 * serve a stale build.
 *
 * The payload carries no secret and no personal data beyond what the recipient
 * is already authorized to see: a subject, a threshold and a due date. The
 * server decides who receives a push; this file only renders what arrives.
 */

/**
 * Activate promptly.
 *
 * Subscribing needs an ACTIVE worker, and the page waits for one. These two
 * handlers keep that wait short and keep it from stalling on an update: without
 * skipWaiting a newly deployed worker sits in `waiting` behind the old one, and
 * without claim() the first page load after registration stays uncontrolled.
 *
 * This is safe here ONLY because this worker caches nothing and intercepts no
 * fetch, so taking over early cannot serve a stale build.
 */
self.addEventListener('install', () => {
  self.skipWaiting()
})

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim())
})

self.addEventListener('push', (event) => {
  let payload = {}
  try {
    payload = event.data ? event.data.json() : {}
  } catch {
    payload = {}
  }

  const title = payload.title || 'CNG Station Management'
  const body = payload.body || 'An alert needs attention.'

  event.waitUntil(
    self.registration.showNotification(title, {
      body,
      // The Cargas mark, already in the brand assets. Nothing is redrawn.
      icon: '/brand/favicon-96.png',
      badge: '/brand/favicon-96.png',
      // Collapse repeats for the same alert instead of stacking duplicates.
      // A delivery TEST gets its own tag so it never collapses onto, or
      // replaces, a real alert notification.
      tag: payload.test ? 'cng-delivery-test' : payload.alert_id || 'cng-alert',
      data: { url: payload.url || '/alerts' },
      // No vibration and no requireInteraction: a due date is a scheduling
      // fact, not an emergency, and the UI must not imply otherwise.
    }),
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const url = (event.notification.data && event.notification.data.url) || '/alerts'
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if ('focus' in client) {
          client.navigate(url)
          return client.focus()
        }
      }
      return self.clients.openWindow(url)
    }),
  )
})

/**
 * The browser replaced this subscription.
 *
 * Chrome and Firefox fire this when a subscription is rotated or expired. The
 * OLD endpoint is dead from that moment, so the page must re-register rather
 * than keep pushing into a hole — which is what produces the 404/410 that
 * deactivates the row server-side.
 *
 * The worker deliberately does NOT save the new subscription itself. Saving
 * goes through `cng_save_push_subscription`, which derives the owning user from
 * the caller's session, and a service worker has no session. Re-subscribing
 * here without an owner would either fail or, worse, need an unauthenticated
 * write path. So the worker resubscribes to keep the browser's own state
 * coherent and leaves persistence to the next page load, where the user's
 * identity is real.
 */
self.addEventListener('pushsubscriptionchange', (event) => {
  const applicationServerKey =
    (event.oldSubscription && event.oldSubscription.options &&
      event.oldSubscription.options.applicationServerKey) || undefined
  if (!applicationServerKey) return
  event.waitUntil(
    self.registration.pushManager
      .subscribe({ userVisibleOnly: true, applicationServerKey })
      .catch(() => {
        // Nothing safe to do from here. The next visit to /alerts re-subscribes
        // through the authenticated path and the stale row is deactivated by
        // the server on its next 404/410.
      }),
  )
})
