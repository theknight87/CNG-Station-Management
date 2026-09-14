/**
 * Supabase configuration for THIS project only.
 *
 * Organization: "CNG Station Management"; project: `cng-station-management`.
 * Never point these variables at another project's instance (CLAUDE.md §2).
 *
 * Only publishable (browser-safe) values belong here. The service-role key is an
 * Edge Function secret and must never reach the client bundle.
 */

export interface SupabaseConfig {
  url: string
  publishableKey: string
}

export function readSupabaseConfig(): SupabaseConfig | null {
  const url = import.meta.env.VITE_SUPABASE_URL
  const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY

  if (!url || !publishableKey) return null
  return { url, publishableKey }
}

export function isSupabaseConfigured(): boolean {
  return readSupabaseConfig() !== null
}
