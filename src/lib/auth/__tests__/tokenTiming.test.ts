import { describe, expect, it } from 'vitest'

import { compareToServer, readTokenTiming } from '../tokenTiming'

function fakeToken(payload: Record<string, unknown>): string {
  const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString('base64url')
  return `${b64({ alg: 'RS256' })}.${b64(payload)}.signature-not-verified-here`
}

describe('token timing diagnostics', () => {
  it('TIMING-1 reads only iat, nbf and exp', () => {
    const t = readTokenTiming(fakeToken({ iat: 100, nbf: 95, exp: 160, sub: 'user_secret', email: 'a@b.c' }))
    expect(t).toEqual({ iat: 100, nbf: 95, exp: 160 })
    // Identity claims must not leak into the diagnostic surface.
    expect(JSON.stringify(t)).not.toContain('user_secret')
    expect(JSON.stringify(t)).not.toContain('a@b.c')
  })

  it('TIMING-2 returns null for malformed input instead of throwing', () => {
    expect(readTokenTiming(null)).toBeNull()
    expect(readTokenTiming('not-a-jwt')).toBeNull()
    expect(readTokenTiming('a.b.c')).toBeNull()
  })

  it('TIMING-3 flags a token whose nbf is ahead of the server clock', () => {
    const server = new Date(1_000_000 * 1000)
    const report = compareToServer({ iat: 1_000_003, nbf: 1_000_002, exp: 1_000_060 }, server)
    expect(report?.nbfMinusServer).toBe(2)
    expect(report?.notYetValid).toBe(true)
  })

  it('TIMING-4 does not flag a token already valid', () => {
    const server = new Date(1_000_000 * 1000)
    const report = compareToServer({ iat: 999_995, nbf: 999_990, exp: 1_000_060 }, server)
    expect(report?.notYetValid).toBe(false)
  })
})
