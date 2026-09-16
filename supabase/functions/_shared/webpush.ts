/**
 * Web Push message construction — RFC 8291 (aes128gcm) + RFC 8292 (VAPID).
 *
 * WHY THIS IS HAND-WRITTEN RATHER THAN A DEPENDENCY.
 * The usual libraries assume Node's crypto module. This runs in the Supabase
 * Edge runtime, and — just as importantly — a self-contained module built on
 * Web Crypto can be UNIT TESTED in this repository's ordinary test run, which a
 * remote import cannot be. Everything below uses only `crypto.subtle`,
 * `TextEncoder` and `Uint8Array`: no Deno API, no Node API, no network.
 *
 * WHAT IT DELIBERATELY DOES NOT DO. It never reads an environment variable,
 * never logs, and never touches the database. Keys arrive as parameters and
 * leave as bytes on the wire. The VAPID PRIVATE key passes through
 * `buildPushRequest` to sign one JWT and is never returned, stored or included
 * in any error this module raises.
 *
 * THE WIRE FORMAT (RFC 8291 §4), which the tests assert structurally:
 *
 *     salt(16) | record_size(4, BE) | key_id_len(1) | as_public(65) | ciphertext
 *
 * and the ciphertext is AES-128-GCM over `plaintext || 0x02`, so it is always
 * exactly `plaintext.length + 1 + 16` bytes.
 */

export interface PushSubscriptionKeys {
  endpoint: string
  /** The browser's public key, base64url, uncompressed P-256 point (65 bytes). */
  p256dh: string
  /** The browser's auth secret, base64url (16 bytes). */
  auth: string
}

export interface VapidKeys {
  /** base64url, uncompressed P-256 point (65 bytes). Browser-visible by design. */
  publicKey: string
  /** base64url, the raw 32-byte scalar. NEVER logged, returned or persisted. */
  privateKey: string
  /** RFC 8292 `sub`: a mailto: or https: contact for the push service operator. */
  subject: string
}

/* -------------------------------------------------------------------------- *
 * base64url
 * -------------------------------------------------------------------------- */

export function base64UrlToBytes(value: string): Uint8Array {
  const padded = value.replace(/-/g, '+').replace(/_/g, '/')
  const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
  const out = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i += 1) out[i] = binary.charCodeAt(i)
  return out
}

export function bytesToBase64Url(bytes: Uint8Array): string {
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0)
  const out = new Uint8Array(total)
  let at = 0
  for (const p of parts) {
    out.set(p, at)
    at += p.length
  }
  return out
}

const utf8 = new TextEncoder()

/* -------------------------------------------------------------------------- *
 * VAPID (RFC 8292)
 * -------------------------------------------------------------------------- */

/**
 * The private key is distributed as a bare 32-byte scalar, which Web Crypto
 * cannot import on its own — it needs the matching public point too. Both
 * halves of the SAME pair are required here, which is also a cheap structural
 * check: a mismatched pair fails at import rather than silently signing
 * something every push service will reject.
 */
async function importVapidSigningKey(publicKey: string, privateKey: string): Promise<CryptoKey> {
  const pub = base64UrlToBytes(publicKey)
  if (pub.length !== 65 || pub[0] !== 0x04) {
    throw new Error('vapid_public_key_malformed')
  }
  const d = base64UrlToBytes(privateKey)
  if (d.length !== 32) {
    throw new Error('vapid_private_key_malformed')
  }
  return crypto.subtle.importKey(
    'jwk',
    {
      kty: 'EC',
      crv: 'P-256',
      x: bytesToBase64Url(pub.slice(1, 33)),
      y: bytesToBase64Url(pub.slice(33, 65)),
      d: bytesToBase64Url(d),
      ext: false,
    },
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  )
}

/** The `aud` claim is the push service ORIGIN, never the full endpoint path. */
export function audienceOf(endpoint: string): string {
  return new URL(endpoint).origin
}

export async function buildVapidJwt(
  vapid: VapidKeys,
  audience: string,
  expiresAt: number,
): Promise<string> {
  const header = bytesToBase64Url(utf8.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const payload = bytesToBase64Url(
    utf8.encode(JSON.stringify({ aud: audience, exp: expiresAt, sub: vapid.subject })),
  )
  const signingInput = utf8.encode(`${header}.${payload}`)
  const key = await importVapidSigningKey(vapid.publicKey, vapid.privateKey)
  // ECDSA over Web Crypto yields the raw r||s pair JWS ES256 requires.
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    key,
    signingInput as unknown as ArrayBuffer,
  )
  return `${header}.${payload}.${bytesToBase64Url(new Uint8Array(signature))}`
}

/* -------------------------------------------------------------------------- *
 * Payload encryption (RFC 8291)
 * -------------------------------------------------------------------------- */

async function hkdf(
  salt: Uint8Array,
  ikm: Uint8Array,
  info: Uint8Array,
  length: number,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey('raw', ikm as unknown as ArrayBuffer, 'HKDF', false, [
    'deriveBits',
  ])
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: salt as unknown as ArrayBuffer, info: info as unknown as ArrayBuffer },
    key,
    length * 8,
  )
  return new Uint8Array(bits)
}

/** RFC 8291 §3.4: `"WebPush: info" || 0x00 || ua_public || as_public`. */
function keyInfo(uaPublic: Uint8Array, asPublic: Uint8Array): Uint8Array {
  return concat(utf8.encode('WebPush: info'), new Uint8Array([0]), uaPublic, asPublic)
}

export const RECORD_SIZE = 4096

export async function encryptPayload(
  subscription: PushSubscriptionKeys,
  plaintext: Uint8Array,
  /** Injectable ONLY so a test can pin the random material; production omits it. */
  fixed?: { salt: Uint8Array; asKeyPair: CryptoKeyPair },
): Promise<Uint8Array> {
  const uaPublic = base64UrlToBytes(subscription.p256dh)
  const authSecret = base64UrlToBytes(subscription.auth)
  if (uaPublic.length !== 65 || uaPublic[0] !== 0x04) throw new Error('subscription_key_malformed')
  if (authSecret.length !== 16) throw new Error('subscription_auth_malformed')

  const salt = fixed?.salt ?? crypto.getRandomValues(new Uint8Array(16))
  const asKeyPair =
    fixed?.asKeyPair ??
    ((await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, [
      'deriveBits',
    ])) as CryptoKeyPair)

  const asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', asKeyPair.publicKey))
  const uaKey = await crypto.subtle.importKey(
    'raw',
    uaPublic as unknown as ArrayBuffer,
    { name: 'ECDH', namedCurve: 'P-256' },
    false,
    [],
  )
  const shared = new Uint8Array(
    await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asKeyPair.privateKey, 256),
  )

  // Two-stage derivation: the auth secret binds the keys to THIS subscription,
  // then the per-message salt derives the record key and nonce.
  const prk = await hkdf(authSecret, shared, keyInfo(uaPublic, asPublic), 32)
  const cek = await hkdf(salt, prk, utf8.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, prk, utf8.encode('Content-Encoding: nonce\0'), 12)

  const aesKey = await crypto.subtle.importKey('raw', cek as unknown as ArrayBuffer, 'AES-GCM', false, ['encrypt'])
  // 0x02 is the last-record padding delimiter; this implementation always sends
  // exactly one record, so it is never 0x01.
  const record = concat(plaintext, new Uint8Array([2]))
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: nonce as unknown as ArrayBuffer, tagLength: 128 },
      aesKey,
      record as unknown as ArrayBuffer,
    ),
  )

  const rs = new Uint8Array(4)
  new DataView(rs.buffer).setUint32(0, RECORD_SIZE, false)
  return concat(salt, rs, new Uint8Array([asPublic.length]), asPublic, ciphertext)
}

/* -------------------------------------------------------------------------- *
 * The request
 * -------------------------------------------------------------------------- */

export interface PushRequest {
  url: string
  headers: Record<string, string>
  body: Uint8Array
}

/**
 * Everything needed to POST one push message. Returning a plain object rather
 * than performing the fetch keeps this module free of I/O, so the tests can
 * assert exactly what would go on the wire — including that the Authorization
 * header carries the PUBLIC key and a signature, never the private key.
 */
export async function buildPushRequest(
  subscription: PushSubscriptionKeys,
  vapid: VapidKeys,
  payload: unknown,
  options: { ttlSeconds?: number; now?: number } = {},
): Promise<PushRequest> {
  const ttl = options.ttlSeconds ?? 3600
  const now = options.now ?? Math.floor(Date.now() / 1000)
  const audience = audienceOf(subscription.endpoint)
  // RFC 8292 caps `exp` at 24h ahead; 12h leaves room without being sloppy.
  const jwt = await buildVapidJwt(vapid, audience, now + 12 * 3600)
  const body = await encryptPayload(subscription, utf8.encode(JSON.stringify(payload)))

  return {
    url: subscription.endpoint,
    headers: {
      authorization: `vapid t=${jwt}, k=${vapid.publicKey}`,
      'content-encoding': 'aes128gcm',
      'content-type': 'application/octet-stream',
      ttl: String(ttl),
      urgency: 'normal',
    },
    body,
  }
}

/**
 * 404 and 410 are the push service saying this endpoint is GONE — the browser
 * discarded it, or the user cleared site data. Only these two justify
 * deactivating a subscription. Everything else (429, 5xx, a network error) is
 * transient and must leave the subscription alone.
 */
export function isSubscriptionGone(status: number): boolean {
  return status === 404 || status === 410
}
