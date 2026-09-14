/**
 * Temporal-claim inspection for a Clerk session token.
 *
 * A "JWT not yet valid" rejection means the verifier considered `nbf` (or
 * `iat`) to be in the future against ITS clock. Diagnosing that needs the
 * token's timing claims and the verifying server's time — nothing else.
 *
 * This module therefore reads ONLY `iat`, `nbf` and `exp`. It never returns,
 * stores or logs the token, its signature, or any identity claim.
 */

export interface TokenTiming {
  iat: number | null
  nbf: number | null
  exp: number | null
}

/** Decode a base64url segment in the browser without pulling in a library. */
function decodeSegment(segment: string): unknown {
  const padded = segment.replace(/-/g, '+').replace(/_/g, '/')
  const json = atob(padded.padEnd(padded.length + ((4 - (padded.length % 4)) % 4), '='))
  return JSON.parse(json)
}

/**
 * Returns only the three timing claims. Malformed input yields nulls rather
 * than throwing: this is diagnostics and must never break the page.
 */
export function readTokenTiming(token: string | null): TokenTiming | null {
  if (!token) return null
  const parts = token.split('.')
  if (parts.length !== 3) return null

  try {
    const payload = decodeSegment(parts[1]) as Record<string, unknown>
    const num = (v: unknown): number | null => (typeof v === 'number' ? v : null)
    return { iat: num(payload.iat), nbf: num(payload.nbf), exp: num(payload.exp) }
  } catch {
    return null
  }
}

export interface SkewReport {
  serverEpoch: number
  browserEpoch: number
  browserMinusServer: number
  nbfMinusServer: number | null
  iatMinusServer: number | null
  expMinusServer: number | null
  notYetValid: boolean
}

/**
 * Compares the token's claims against the SUPABASE server clock — not the
 * browser's, which plays no part in verification.
 */
export function compareToServer(
  timing: TokenTiming | null,
  serverDate: Date | null,
): SkewReport | null {
  if (!timing || !serverDate) return null
  const serverEpoch = Math.floor(serverDate.getTime() / 1000)
  const browserEpoch = Math.floor(Date.now() / 1000)
  const delta = (claim: number | null) => (claim === null ? null : claim - serverEpoch)

  const nbfMinusServer = delta(timing.nbf)
  const iatMinusServer = delta(timing.iat)

  return {
    serverEpoch,
    browserEpoch,
    browserMinusServer: browserEpoch - serverEpoch,
    nbfMinusServer,
    iatMinusServer,
    expMinusServer: delta(timing.exp),
    // Either claim ahead of the server's clock is what produces the rejection.
    notYetValid: (nbfMinusServer ?? 0) > 0 || (iatMinusServer ?? 0) > 0,
  }
}

/**
 * Reads the Supabase server's clock from the `Date` response header of a
 * cheap request to the REST root. No token is sent.
 */
export async function readSupabaseServerDate(
  url: string,
  publishableKey: string,
): Promise<Date | null> {
  try {
    const res = await fetch(`${url}/rest/v1/`, { headers: { apikey: publishableKey } })
    const header = res.headers.get('date')
    return header ? new Date(header) : null
  } catch {
    return null
  }
}
