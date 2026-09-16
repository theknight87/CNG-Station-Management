/**
 * Notification delivery for CNG Station Management — EMAIL (Resend).
 *
 * SCOPE: email only. Web Push SENDING is not implemented here; the browser
 * subscription path exists (see cng_save_push_subscription and the /alerts
 * opt-in), but nothing in this function delivers a push message. Saying so
 * plainly matters more than implying a capability that is not here.
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
 */

import { createClient } from '@supabase/supabase-js'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const INVOKE_SECRET = Deno.env.get('CNG_ALERT_INVOKE_SECRET')
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')
const FROM_EMAIL = Deno.env.get('CNG_ALERT_FROM_EMAIL')
/** The ONLY address test mode may send to. Absent => test mode is disabled. */
const TEST_RECIPIENT = Deno.env.get('CNG_ALERT_TEST_RECIPIENT')

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

  let body: { mode?: string; to?: string; limit?: number } = {}
  try {
    body = await req.json()
  } catch {
    body = {}
  }
  const mode = body.mode === 'test' ? 'test' : 'queue'

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
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

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
