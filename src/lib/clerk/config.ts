/**
 * Clerk configuration for THIS project only.
 *
 * Application: "CNG Station Management". No other Clerk instance, JWT template,
 * or key is reused (CLAUDE.md, §2).
 *
 * Only the publishable key is read here. The Clerk secret key is a server-side
 * secret and must never appear in the client bundle or in this repository.
 *
 * The ClerkProvider is wired in a later phase.
 */

export function readClerkPublishableKey(): string | null {
  return import.meta.env.VITE_CLERK_PUBLISHABLE_KEY || null
}

export function isClerkConfigured(): boolean {
  return readClerkPublishableKey() !== null
}
