/**
 * A new deployment replaces every fingerprinted file under /assets. A tab opened before the deploy still
 * holds the OLD index.html, so the first time it navigates to a page whose code it has not loaded yet, the
 * browser asks for a file that no longer exists: "Failed to fetch dynamically imported module".
 *
 * The cure is to load the new version: reload once. A timestamp in sessionStorage stops a reload loop if
 * the failure is something else (offline, a genuinely missing file) — the second failure within the window
 * is shown on the error page instead of reloading again.
 */
const KEY = 'cng:stale-chunk-reload-at'
const WINDOW_MS = 30_000

const STALE_CHUNK = [
  /Failed to fetch dynamically imported module/i, // Chromium
  /error loading dynamically imported module/i, // Firefox
  /Importing a module script failed/i, // Safari
  /Unable to preload CSS/i, // Vite CSS preload
  /Loading (CSS )?chunk .* failed/i,
]

export function isStaleChunkError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : typeof error === 'string' ? error : ''
  return STALE_CHUNK.some((pattern) => pattern.test(message))
}

/** Reloads the page unless it already did so moments ago. Returns whether a reload was started. */
export function reloadForNewVersion(now: number = Date.now()): boolean {
  try {
    const last = Number(window.sessionStorage.getItem(KEY) ?? 0)
    if (now - last < WINDOW_MS) return false
    window.sessionStorage.setItem(KEY, String(now))
  } catch {
    // Storage unavailable: without a loop guard, never reload automatically — the error page offers a button.
    return false
  }
  window.location.reload()
  return true
}
