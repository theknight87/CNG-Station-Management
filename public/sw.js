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
      tag: payload.alert_id || 'cng-alert',
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
