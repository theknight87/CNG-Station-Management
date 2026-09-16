/**
 * Notification delivery for CNG Station Management — EMAIL (Resend) and WEB PUSH.
 *
 * TWO CHANNELS, ONE DELIVERY SYSTEM. `email` and `web_push` are distinct values
 * of `notification_channel` sharing the same alerts, the same delivery rows and
 * the same dedupe/retry rules. This is not a second notification system bolted
 * alongside the first: `cng_enqueue_alert_deliveries` and
 * `cng_record_delivery_result` are reused unchanged for both, and the request's
 * `channel` defaults to `email`, so every existing caller behaves exactly as
 * before.
 *
 * WEB PUSH SIGNS SERVER-SIDE, ALWAYS. The VAPID private key exists only as an
 * Edge Function secret. It is never returned, never logged, never written to a
 * delivery row, and never present in any frontend bundle — only the PUBLIC key
 * reaches a browser. See supabase/functions/_shared/webpush.ts.
 *
 * ARCHITECTURE, PRESERVED FROM PROMPT 15:
 *
 *     technical condition -> persisted ALERT -> DELIVERY attempt
 *
 * This function only ever CONSUMES alerts that already exist. It cannot create,
 * modify, acknowledge or delete one: the three database functions it may call
 * (`cng_enqueue_alert_deliveries`, `cng_next_pending_deliveries`,
 * `cng_record_delivery_result`) touch `notification_deliveries` and nothing
 * else, and `service_role` holds no table privileges that would let it reach
 * further. A provider failure therefore cannot delete an alert, acknowledge it,
 * change its identity, or cause a duplicate.
 *
 * SECURITY MODEL
 * 1. FAILS CLOSED when unconfigured (503). It never runs half-configured, and
 *    a missing RESEND_API_KEY stops email rather than silently "succeeding".
 * 2. Every request must present `x-cng-alert-secret`, compared in CONSTANT
 *    TIME. Missing or wrong -> 401. `verify_jwt` is false because this is
 *    invoked server-side, so it authenticates the caller itself.
 * 3. NOT AN OPEN MAIL RELAY. This is the risk a sending endpoint creates, so it
 *    is closed three ways:
 *      - the invoke secret is server-side only and never reaches a browser;
 *      - queue mode takes recipients from the DATABASE (opted-in users whose
 *        RLS lets them read the alert), never from the request body;
 *      - test mode accepts ONE address, and only if it matches
 *        CNG_ALERT_TEST_RECIPIENT exactly. A caller cannot name an arbitrary
 *        destination even holding the secret.
 * 4. Provider errors are SANITIZED before storage or response: status code and
 *    a short provider name only. Raw provider bodies can echo the recipient,
 *    headers, or key fragments, and none of that belongs in an operational
 *    record a user can read.
 * 5. Secrets are read from Deno.env and are never logged, echoed or returned.
 *    The VAPID PRIVATE key stays here; only the PUBLIC key reaches a browser.
 * 6. RECIPIENTS ARE NEVER NAMED BY THE CALLER, on either channel. Push
 *    destinations come from `push_subscriptions` rows the owning user created
 *    themselves, reached through service_role-only functions no browser can
 *    execute. A request cannot supply an endpoint, a user id or a message body,
 *    so holding the invoke secret still does not make this a push relay.
 */

import { createClient } from '@supabase/supabase-js'

import { buildPushRequest, isSubscriptionGone } from '../_shared/webpush.ts'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const INVOKE_SECRET = Deno.env.get('CNG_ALERT_INVOKE_SECRET')
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const FROM_EMAIL = Deno.env.get('CNG_ALERT_FROM_EMAIL')
/** The ONLY address test mode may send to. Absent => test mode is disabled. */
const TEST_RECIPIENT = Deno.env.get('CNG_ALERT_TEST_RECIPIENT')
/** Browser-visible by design; needed here for the `k=` parameter and to import the signing key. */
const VAPID_PUBLIC_KEY = Deno.env.get('VAPID_PUBLIC_KEY')
/** NEVER logged, returned, or stored. Read once, used to sign, discarded. */
const VAPID_PRIVATE_KEY = Deno.env.get('VAPID_PRIVATE_KEY')
/** RFC 8292 `sub`. Falls back to the sending identity rather than inventing one. */
const VAPID_SUBJECT =
  Deno.env.get('CNG_VAPID_SUBJECT') ?? (FROM_EMAIL ? `mailto:${FROM_EMAIL}` : undefined)

function secretMatches(provided: string, expected: string): boolean {
  const a = new TextEncoder().encode(provided)
  const b = new TextEncoder().encode(expected)
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i += 1) diff |= a[i] ^ b[i]
  return diff === 0
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

/**
 * Reduce any provider failure to something safe to store and return.
 * Never includes the response body, the recipient, or any header.
 */
function sanitizeProviderError(provider: string, status: number | null, hint?: string): string {
  const code = status === null ? 'no_response' : `http_${status}`
  // `hint` is only ever a short, known-safe token chosen by this file.
  return hint ? `${provider}:${code}:${hint}` : `${provider}:${code}`
}

const SUBJECT_TEXT: Record<string, string> = {
  srv_calibration: 'SRV calibration',
  storage_inspection: 'Storage vessel inspection',
  recovery_tank_inspection: 'Recovery tank inspection',
  gas_detector_calibration: 'Gas detector calibration',
  hose_hydrotest: 'Hose hydrotest',
}

const THRESHOLD_TEXT: Record<string, string> = {
  overdue: 'is overdue',
  due_today: 'is due today',
  due_7: 'is due within 7 days',
  due_15: 'is due within 15 days',
  due_30: 'is due within 30 days',
  due_60: 'is due within 60 days',
}

/** Plain, factual wording. No severity is asserted that the data does not carry. */
function alertEmail(row: Record<string, unknown>): { subject: string; text: string } {
  const subj = SUBJECT_TEXT[String(row.subject)] ?? String(row.subject)
  const when = THRESHOLD_TEXT[String(row.threshold)] ?? String(row.threshold)
  const where = row.station_name ? ` at ${row.station_name}` : ''
  return {
    subject: `CNG Station Management — ${subj} ${when}`,
    text: [
      `${subj}${where} ${when}.`,
      ``,
      `Due date: ${row.due_date}`,
      ``,
      `Open the Alerts page in CNG Station Management for the full record.`,
      `This message reports a scheduled due date. It is not a statement about equipment safety.`,
    ].join('\n'),
  }
}

async function sendEmail(
  to: string,
  subject: string,
  text: string,
): Promise<{ ok: true; id: string | null } | { ok: false; error: string }> {
  let res: Response
  try {
    res = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${RESEND_API_KEY}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ from: FROM_EMAIL, to: [to], subject, text }),
    })
  } catch {
    // Network-level failure: no status, and nothing from the provider to leak.
    return { ok: false, error: sanitizeProviderError('resend', null, 'unreachable') }
  }

  if (!res.ok) {
    // The body is deliberately NOT stored. A 403 from Resend commonly means the
    // sending domain is unverified and only the account owner may be mailed;
    // that hint is written by this file, not echoed from the provider.
    const hint = res.status === 403 ? 'sender_or_recipient_not_permitted'
      : res.status === 422 ? 'invalid_sender_or_recipient'
      : res.status === 429 ? 'rate_limited'
      : undefined
    return { ok: false, error: sanitizeProviderError('resend', res.status, hint) }
  }

  let id: string | null = null
  try {
    const body = await res.json()
    id = typeof body?.id === 'string' ? body.id : null
  } catch {
    id = null
  }
  return { ok: true, id }
}


/* -------------------------------------------------------------------------- *
 * WEB PUSH
 * -------------------------------------------------------------------------- */

interface PushTarget { endpoint: string; p256dh: string; auth: string }

/** Plain, factual notification content. Mirrors the email wording. */
function alertPush(row: Record<string, unknown>): { title: string; body: string } {
  const subj = SUBJECT_TEXT[String(row.subject)] ?? String(row.subject)
  const when = THRESHOLD_TEXT[String(row.threshold)] ?? String(row.threshold)
  const where = row.station_name ? ` at ${row.station_name}` : ''
  return {
    title: 'CNG Station Management',
    body: `${subj}${where} ${when}. Due ${row.due_date}.`,
  }
}

/**
 * Send one message to one endpoint.
 *
 * Returns `gone` separately from `failed` because the two mean different
 * things: `gone` is the push service saying the subscription no longer exists,
 * and only that may deactivate it. A 500, a 429 or a dropped connection says
 * nothing about validity and must leave the subscription usable.
 */
async function sendPush(
  target: PushTarget,
  payload: { title: string; body: string; url: string; test?: boolean },
): Promise<{ ok: true } | { ok: false; gone: boolean; error: string }> {
  if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY || !VAPID_SUBJECT) {
    return { ok: false, gone: false, error: sanitizeProviderError('webpush', null, 'not_configured') }
  }
  let request
  try {
    request = await buildPushRequest(
      target,
      { publicKey: VAPID_PUBLIC_KEY, privateKey: VAPID_PRIVATE_KEY, subject: VAPID_SUBJECT },
      payload,
    )
  } catch (e) {
    // Construction failures name a CATEGORY, never key material. The messages
    // webpush.ts raises are fixed tokens chosen for exactly this reason.
    const hint = e instanceof Error ? e.message.slice(0, 40) : 'build_failed'
    return { ok: false, gone: false, error: sanitizeProviderError('webpush', null, hint) }
  }

  let res: Response
  try {
    res = await fetch(request.url, { method: 'POST', headers: request.headers, body: request.body })
  } catch {
    return { ok: false, gone: false, error: sanitizeProviderError('webpush', null, 'unreachable') }
  }
  if (res.ok) return { ok: true }

  const gone = isSubscriptionGone(res.status)
  return {
    ok: false,
    gone,
    // The body is NOT stored: a push service response can echo the endpoint.
    error: sanitizeProviderError('webpush', res.status, gone ? 'subscription_gone' : undefined),
  }
}

/**
 * Deliver to every active browser the user has, and report whether ANY
 * succeeded.
 *
 * One delivery row covers one user per alert whatever their device count, so
 * the record reflects "this user was reached", not "this browser was". A gone
 * endpoint is deactivated as it is found; the others are unaffected.
 */
async function sendPushToTargets(
  supabase: ReturnType<typeof createClient>,
  targets: PushTarget[],
  payload: { title: string; body: string; url: string; test?: boolean },
): Promise<{ delivered: number; gone: number; failed: number; lastError: string | null }> {
  let delivered = 0
  let gone = 0
  let failed = 0
  let lastError: string | null = null

  for (const target of targets) {
    const result = await sendPush(target, payload)
    if (result.ok) {
      delivered += 1
      await supabase.rpc('cng_record_push_endpoint_result', {
        p_endpoint: target.endpoint,
        p_succeeded: true,
      })
      continue
    }
    lastError = result.error
    if (result.gone) {
      gone += 1
      // ONLY 404/410 reaches this call. Deactivation is soft: the row stays.
      await supabase.rpc('cng_deactivate_push_subscription', { p_endpoint: target.endpoint })
    } else {
      failed += 1
      // Records the failure WITHOUT deactivating.
      await supabase.rpc('cng_record_push_endpoint_result', {
        p_endpoint: target.endpoint,
        p_succeeded: false,
      })
    }
  }
  return { delivered, gone, failed, lastError }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405)

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !INVOKE_SECRET) {
    console.error('send-notifications: missing core configuration')
    return json({ error: 'not_configured' }, 503)
  }

  const provided = req.headers.get('x-cng-alert-secret')
  if (!provided || !secretMatches(provided, INVOKE_SECRET)) {
    return json({ error: 'unauthorized' }, 401)
  }

  let body: { mode?: string; to?: string; limit?: number; channel?: string } = {}
  try {
    body = await req.json()
  } catch {
    body = {}
  }
  const mode = body.mode === 'test' ? 'test' : 'queue'
  // Defaults to email, so every caller written before web_push existed keeps
  // its exact previous behaviour.
  const channel = body.channel === 'web_push' ? 'web_push' : 'email'

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  /* ------------------------------------------------------------------ *
   * WEB PUSH
   * ------------------------------------------------------------------ */
  if (channel === 'web_push') {
    if (!VAPID_PUBLIC_KEY || !VAPID_PRIVATE_KEY || !VAPID_SUBJECT) {
      // Fails closed, and names no value.
      console.error('send-notifications: web push is not configured')
      return json({ error: 'web_push_not_configured' }, 503)
    }

    if (mode === 'test') {
      if (!TEST_RECIPIENT) return json({ error: 'test_recipient_not_configured' }, 503)
      // The request may not choose a destination on this channel either. There
      // is no endpoint, user or message parameter to supply: targets are looked
      // up from the CONFIGURED test user's own opted-in subscriptions.
      if (body.to && body.to.trim().toLowerCase() !== TEST_RECIPIENT.trim().toLowerCase()) {
        return json({ error: 'recipient_not_permitted' }, 403)
      }

      const { data: targets, error: targetError } = await supabase.rpc('cng_test_push_targets', {
        p_email: TEST_RECIPIENT,
      })
      if (targetError) {
        console.error('send-notifications: push test target lookup failed', targetError.message)
        return json({ error: 'target_lookup_failed' }, 500)
      }
      const list = (targets ?? []) as PushTarget[]
      if (list.length === 0) {
        // Nobody is subscribed. Stating that is the correct outcome; inventing
        // a destination would make this a relay.
        return json({ mode: 'test', channel, sent: false, error: 'no_active_subscription' }, 409)
      }

      const result = await sendPushToTargets(supabase, list, {
        title: 'CNG Station Management',
        body: 'Web Push delivery test successful.',
        url: '/alerts',
        // Marks the notification as a TEST for anything that inspects it. No
        // alert row is created, so this reports no real equipment condition.
        test: true,
      })
      if (result.delivered === 0) {
        // The sanitized code is the ONLY record of why a test failed: a test
        // send writes no delivery row, so without this line the reason exists
        // solely in the HTTP response and is lost the moment it is not read.
        // `lastError` is already reduced to provider:code:hint by
        // sanitizeProviderError — never an endpoint, key, header or provider
        // body — which is what makes it safe to log at all.
        console.error('send-notifications: push test send failed', result.lastError)
        return json({ mode: 'test', channel, sent: false, error: result.lastError }, 502)
      }
      console.log('send-notifications: push test send accepted')
      return json(
        { mode: 'test', channel, sent: true, delivered: result.delivered, gone: result.gone, failed: result.failed },
        200,
      )
    }

    const { error: pushEnqueueError } = await supabase.rpc('cng_enqueue_alert_deliveries', {
      p_channel: 'web_push',
    })
    if (pushEnqueueError) {
      console.error('send-notifications: push enqueue failed', pushEnqueueError.message)
      return json({ error: 'enqueue_failed' }, 500)
    }

    const pushLimit = Math.min(Math.max(Number(body.limit) || 25, 1), 100)
    const { data: pending, error: pushClaimError } = await supabase.rpc(
      'cng_next_pending_push_deliveries',
      { p_limit: pushLimit },
    )
    if (pushClaimError) {
      console.error('send-notifications: push claim failed', pushClaimError.message)
      return json({ error: 'claim_failed' }, 500)
    }

    let pushSent = 0
    let pushFailed = 0
    let pushSkipped = 0
    for (const row of (pending ?? []) as Record<string, unknown>[]) {
      const targets = (row.subscriptions ?? []) as PushTarget[]
      if (targets.length === 0) {
        // Opted in, but no live browser. Recorded as skipped so it is not
        // retried forever, and the ALERT is untouched.
        await supabase.rpc('cng_record_delivery_result', {
          p_delivery_id: row.delivery_id,
          p_status: 'skipped',
          p_error: 'no_active_subscription',
        })
        pushSkipped += 1
        continue
      }
      const message = alertPush(row)
      const result = await sendPushToTargets(supabase, targets, { ...message, url: '/alerts' })
      // Reached on at least one device counts as delivered to that user.
      const ok = result.delivered > 0
      await supabase.rpc('cng_record_delivery_result', {
        p_delivery_id: row.delivery_id,
        p_status: ok ? 'sent' : 'failed',
        p_error: ok ? null : result.lastError,
      })
      if (ok) pushSent += 1
      else {
        pushFailed += 1
        // Persisted on the delivery row too; logged so a run can be diagnosed
        // without querying, and sanitized by the same single path.
        console.error('send-notifications: push delivery failed', result.lastError)
      }
    }

    console.log(`send-notifications: push sent=${pushSent} failed=${pushFailed} skipped=${pushSkipped}`)
    return json({ mode: 'queue', channel, sent: pushSent, failed: pushFailed, skipped: pushSkipped }, 200)
  }

  /* ------------------------------------------------------------------ *
   * EMAIL — unchanged from Prompt 15.1.
   * ------------------------------------------------------------------ */
  if (!RESEND_API_KEY || !FROM_EMAIL) {
    // Email specifically is unconfigured. Say so without naming values.
    console.error('send-notifications: email is not configured')
    return json({ error: 'email_not_configured' }, 503)
  }

  /* ------------------------------------------------------------------ *
   * TEST MODE — exactly one message, to exactly one allow-listed address.
   * ------------------------------------------------------------------ */
  if (mode === 'test') {
    if (!TEST_RECIPIENT) {
      return json({ error: 'test_recipient_not_configured' }, 503)
    }
    // The request may not choose a destination. If it names one it must match
    // the configured address exactly, so the secret alone cannot relay mail.
    if (body.to && body.to.trim().toLowerCase() !== TEST_RECIPIENT.trim().toLowerCase()) {
      return json({ error: 'recipient_not_permitted' }, 403)
    }

    const result = await sendEmail(
      TEST_RECIPIENT,
      '[TEST] CNG Station Management — Notification Verification',
      [
        'This is a controlled notification test from the CNG Station Management system.',
        '',
        'It was sent to verify that email delivery is configured correctly.',
        'It does NOT report a real alert, a real due date, or any condition of real equipment.',
        '',
        'No action is required.',
      ].join('\n'),
    )

    if (!result.ok) {
      console.error('send-notifications: test send failed', result.error)
      return json({ mode: 'test', sent: false, error: result.error }, 502)
    }
    // No alert row is involved in a test send, so no delivery record is written:
    // a delivery belongs to an alert, and inventing one would be a fabricated
    // operational record.
    console.log('send-notifications: test send accepted')
    return json({ mode: 'test', sent: true, provider_message_id: result.id }, 200)
  }

  /* ------------------------------------------------------------------ *
   * QUEUE MODE — recipients come from the database, never from the caller.
   * ------------------------------------------------------------------ */
  const { error: enqueueError } = await supabase.rpc('cng_enqueue_alert_deliveries', {
    p_channel: 'email',
  })
  if (enqueueError) {
    console.error('send-notifications: enqueue failed', enqueueError.message)
    return json({ error: 'enqueue_failed' }, 500)
  }

  const limit = Math.min(Math.max(Number(body.limit) || 25, 1), 100)
  const { data: pending, error: claimError } = await supabase.rpc('cng_next_pending_deliveries', {
    p_channel: 'email',
    p_limit: limit,
  })
  if (claimError) {
    console.error('send-notifications: claim failed', claimError.message)
    return json({ error: 'claim_failed' }, 500)
  }

  let sent = 0
  let failed = 0
  for (const row of (pending ?? []) as Record<string, unknown>[]) {
    const to = typeof row.recipient === 'string' ? row.recipient : null
    if (!to) {
      // No address on file. Recorded as skipped, not retried forever.
      await supabase.rpc('cng_record_delivery_result', {
        p_delivery_id: row.delivery_id,
        p_status: 'skipped',
        p_error: 'no_recipient_address',
      })
      continue
    }
    const mail = alertEmail(row)
    const result = await sendEmail(to, mail.subject, mail.text)
    await supabase.rpc('cng_record_delivery_result', {
      p_delivery_id: row.delivery_id,
      p_status: result.ok ? 'sent' : 'failed',
      p_provider_message_id: result.ok ? result.id : null,
      p_error: result.ok ? null : result.error,
    })
    if (result.ok) sent += 1
    else failed += 1
  }

  console.log(`send-notifications: sent=${sent} failed=${failed}`)
  return json({ mode: 'queue', sent, failed }, 200)
})
