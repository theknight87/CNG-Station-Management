import { describe, expect, it } from 'vitest'

import {
  audienceOf,
  base64UrlToBytes,
  bytesToBase64Url,
  buildPushRequest,
  buildVapidJwt,
  encryptPayload,
  isSubscriptionGone,
  RECORD_SIZE,
} from '../../../../supabase/functions/_shared/webpush'

/**
 * Web Push message construction (RFC 8291 / RFC 8292).
 *
 * WHAT THESE CAN AND CANNOT PROVE. They prove the implementation is
 * self-consistent and structurally correct: a message it encrypts decrypts back
 * to the original with the subscription's own private key, the header layout
 * matches the RFC, and the VAPID signature verifies against the PUBLIC key.
 * They CANNOT prove a real push service accepts it — that is the live test, and
 * nothing here should be read as standing in for one.
 *
 * The security assertions are the ones that must never regress: the private key
 * never reaches the wire, and a transient failure is not treated as a dead
 * subscription.
 */

const utf8 = new TextEncoder()

/** A stand-in browser: a real P-256 pair, so the round trip is genuine. */
async function makeSubscription(endpoint = 'https://fcm.example.test/send/abc123') {
  const pair = (await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, [
    'deriveBits',
  ])) as CryptoKeyPair
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
  const auth = crypto.getRandomValues(new Uint8Array(16))
  return {
    subscription: { endpoint, p256dh: bytesToBase64Url(raw), auth: bytesToBase64Url(auth) },
    uaPrivate: pair.privateKey,
    uaPublic: raw,
  }
}

async function makeVapid() {
  const pair = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
    'verify',
  ])) as CryptoKeyPair
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
  const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey)
  return {
    keys: {
      publicKey: bytesToBase64Url(raw),
      privateKey: jwk.d as string,
      subject: 'mailto:ops@example.test',
    },
    verifyKey: pair.publicKey,
  }
}

/** Decrypt with the subscription's own private key — the browser's half. */
async function decrypt(body: Uint8Array, uaPrivate: CryptoKey, authSecret: Uint8Array, uaPublic: Uint8Array) {
  const salt = body.slice(0, 16)
  const idLen = body[20]
  const asPublic = body.slice(21, 21 + idLen)
  const ciphertext = body.slice(21 + idLen)

  const asKey = await crypto.subtle.importKey(
    'raw',
    asPublic as unknown as ArrayBuffer,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  )
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: 'ECDH', public: asKey }, uaPrivate, 256),
  )
  const hkdf = async (s: Uint8Array, ikm: Uint8Array, info: Uint8Array, len: number) => {
    const k = await crypto.subtle.importKey('raw', ikm as unknown as ArrayBuffer, 'HKDF', false, ['deriveBits'])
    return new Uint8Array(
      await crypto.subtle.deriveBits(
        { name: 'HKDF', hash: 'SHA-256', salt: s as unknown as ArrayBuffer, info: info as unknown as ArrayBuffer },
        k,
        len * 8,
      ),
    )
  }
  const info = new Uint8Array([...utf8.encode('WebPush: info'), 0, ...uaPublic, ...asPublic])
  const prk = await hkdf(authSecret, shared, info, 32)
  const cek = await hkdf(salt, prk, utf8.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, prk, utf8.encode('Content-Encoding: nonce\0'), 12)
  const aes = await crypto.subtle.importKey('raw', cek as unknown as ArrayBuffer, 'AES-GCM', false, ['decrypt'])
  const plain = new Uint8Array(
    await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: nonce as unknown as ArrayBuffer, tagLength: 128 },
      aes,
      ciphertext as unknown as ArrayBuffer,
    ),
  )
  // Strip the 0x02 last-record delimiter.
  expect(plain[plain.length - 1]).toBe(2)
  return new TextDecoder().decode(plain.slice(0, -1))
}

describe('RFC 8291 payload encryption', () => {
  it('round-trips: what it encrypts, the subscription can decrypt', async () => {
    const { subscription, uaPrivate, uaPublic } = await makeSubscription()
    const message = JSON.stringify({ title: 'CNG Station Management', body: 'Web Push delivery test successful.' })
    const body = await encryptPayload(subscription, utf8.encode(message))

    const back = await decrypt(body, uaPrivate, base64UrlToBytes(subscription.auth), uaPublic)
    expect(back).toBe(message)
  })

  it('produces the RFC 8291 header layout', async () => {
    const { subscription } = await makeSubscription()
    const plaintext = utf8.encode('hello')
    const body = await encryptPayload(subscription, plaintext)

    expect(body.slice(0, 16)).toHaveLength(16) // salt
    expect(new DataView(body.buffer, body.byteOffset).getUint32(16, false)).toBe(RECORD_SIZE)
    expect(body[20]).toBe(65) // uncompressed P-256 point
    expect(body[21]).toBe(0x04)
    // ciphertext = plaintext + 1 delimiter byte + 16-byte GCM tag
    expect(body.length - 21 - 65).toBe(plaintext.length + 1 + 16)
  })

  it('uses fresh random material for every message', async () => {
    const { subscription } = await makeSubscription()
    const a = await encryptPayload(subscription, utf8.encode('same'))
    const b = await encryptPayload(subscription, utf8.encode('same'))
    // Identical plaintext must not produce an identical record.
    expect(bytesToBase64Url(a.slice(0, 16))).not.toBe(bytesToBase64Url(b.slice(0, 16)))
    expect(bytesToBase64Url(a)).not.toBe(bytesToBase64Url(b))
  })

  it('rejects malformed subscription key material instead of sending garbage', async () => {
    await expect(
      encryptPayload({ endpoint: 'https://x.test/1', p256dh: bytesToBase64Url(new Uint8Array(10)), auth: bytesToBase64Url(new Uint8Array(16)) }, utf8.encode('x')),
    ).rejects.toThrow(/subscription_key_malformed/)
    const { subscription } = await makeSubscription()
    await expect(
      encryptPayload({ ...subscription, auth: bytesToBase64Url(new Uint8Array(8)) }, utf8.encode('x')),
    ).rejects.toThrow(/subscription_auth_malformed/)
  })
})

describe('VAPID signing', () => {
  it('signs a verifiable ES256 JWT scoped to the push service ORIGIN', async () => {
    const { keys, verifyKey } = await makeVapid()
    const jwt = await buildVapidJwt(keys, 'https://fcm.example.test', 1_800_000_000)
    const [h, p, s] = jwt.split('.')

    expect(JSON.parse(new TextDecoder().decode(base64UrlToBytes(h)))).toEqual({ typ: 'JWT', alg: 'ES256' })
    const claims = JSON.parse(new TextDecoder().decode(base64UrlToBytes(p)))
    expect(claims.aud).toBe('https://fcm.example.test')
    expect(claims.sub).toBe('mailto:ops@example.test')

    const ok = await crypto.subtle.verify(
      { name: 'ECDSA', hash: 'SHA-256' },
      verifyKey,
      base64UrlToBytes(s) as unknown as ArrayBuffer,
      utf8.encode(`${h}.${p}`) as unknown as ArrayBuffer,
    )
    expect(ok).toBe(true)
  })

  it('scopes the audience to the origin, never the endpoint path', () => {
    // The path identifies the SUBSCRIPTION. Signing it into the token would
    // hand the push service a token usable only once, and leak the endpoint.
    expect(audienceOf('https://fcm.example.test/send/secret-endpoint-id')).toBe('https://fcm.example.test')
  })

  it('refuses a malformed key pair rather than signing something unusable', async () => {
    await expect(
      buildVapidJwt({ publicKey: bytesToBase64Url(new Uint8Array(20)), privateKey: bytesToBase64Url(new Uint8Array(32)), subject: 'mailto:a@b.test' }, 'https://x.test', 1),
    ).rejects.toThrow(/vapid_public_key_malformed/)
    const { keys } = await makeVapid()
    await expect(
      buildVapidJwt({ ...keys, privateKey: bytesToBase64Url(new Uint8Array(16)) }, 'https://x.test', 1),
    ).rejects.toThrow(/vapid_private_key_malformed/)
  })
})

describe('The request that goes on the wire', () => {
  it('carries the PUBLIC key and a signature — never the private key', async () => {
    const { subscription } = await makeSubscription()
    const { keys } = await makeVapid()
    const req = await buildPushRequest(subscription, keys, { title: 'x' })

    const serialized = JSON.stringify({ url: req.url, headers: req.headers })
    expect(serialized).toContain(keys.publicKey)
    // THE assertion: the VAPID private key appears nowhere in the request.
    expect(serialized).not.toContain(keys.privateKey)
    expect(bytesToBase64Url(req.body)).not.toContain(keys.privateKey)
    expect(req.headers.authorization).toMatch(/^vapid t=[\w-]+\.[\w-]+\.[\w-]+, k=/)
  })

  it('posts to the subscription endpoint with the aes128gcm content coding', async () => {
    const { subscription } = await makeSubscription('https://updates.push.services.mozilla.test/wpush/v2/xyz')
    const { keys } = await makeVapid()
    const req = await buildPushRequest(subscription, keys, { title: 'x' }, { ttlSeconds: 60 })
    expect(req.url).toBe(subscription.endpoint)
    expect(req.headers['content-encoding']).toBe('aes128gcm')
    expect(req.headers.ttl).toBe('60')
  })
})

describe('Stale versus transient failures', () => {
  it('treats only 404 and 410 as a gone subscription', () => {
    expect(isSubscriptionGone(404)).toBe(true)
    expect(isSubscriptionGone(410)).toBe(true)
  })

  it('never treats a transient failure as a gone subscription', () => {
    // Unsubscribing a real user because a push service had a bad minute is the
    // failure mode this guards.
    for (const status of [400, 401, 403, 413, 429, 500, 502, 503, 504]) {
      expect(isSubscriptionGone(status)).toBe(false)
    }
  })
})
