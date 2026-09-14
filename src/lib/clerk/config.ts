/**
 * Clerk configuration for THIS project only.
 *
 * Application: "CNG Station Management". No other Clerk instance, JWT template,
 * or key is reused (CLAUDE.md §2).
 *
 * Only the PUBLISHABLE key is read here — it is designed for browser exposure.
 * The Clerk SECRET key and the webhook signing secret are server-side only and
 * must never appear in a VITE_ variable, in this repository, or in any bundle.
 */

export function readClerkPublishableKey(): string | null {
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || null
}

export function isClerkConfigured(): boolean {
  return readClerkPublishableKey() !== null
}
