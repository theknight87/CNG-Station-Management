/**
 * Daily alert generation for CNG Station Management.
 *
 * WHAT IT DOES. One thing: calls `cng_generate_alerts()`, which evaluates the
 * enabled alert rules against assets with an EXACT next due date and inserts
 * only the alert rows that do not already exist. All of the dedupe, threshold
 * and timezone logic lives in PostgreSQL, deliberately — see migration 0031.
 * This function is transport, not business logic.
 *
 * SECURITY MODEL
 * 1. FAILS CLOSED when unconfigured (503). It never runs half-configured.
 * 2. Every request must present the shared invocation secret in
 *    `x-cng-alert-secret`, compared in constant time. Missing or wrong -> 401.
 *    `verify_jwt` is false because pg_cron calls this with a static header, not
 *    a user JWT, so the function authenticates the caller itself.
 * 3. It runs with the service-role key, which bypasses RLS. That key never
 *    reaches a browser. Its SQL privileges are narrow by design: migration 0024
 *    left `service_role` with SELECT on `app_users` only, and migration 0031
 *    grants it EXECUTE on `cng_generate_alerts` and nothing else. So even with
 *    this key, the function cannot read assets, write alerts directly, delete
 *    anything, or touch authorization.
 * 4. Generation is IDEMPOTENT in the database. A retry, a double-fire, or two
 *    overlapping cron runs cannot create a duplicate alert — proven by
 *    `alerts_dedupe_uq` plus ON CONFLICT DO NOTHING, not by checking first.
 * 5. Errors returned to the caller are non-specific. The database message is
 *    logged server-side and never echoed, so a provider or schema detail cannot
 *    leak through an HTTP response.
 *
 * WHAT IT DELIBERATELY DOES NOT DO. It sends no email and no web push. Those
 * need this project's OWN Resend API key and OWN VAPID key pair, neither of
 * which exists yet (see docs/alerts-notifications.md). Crucially, external
 * delivery is a SEPARATE concern from the alert: an alert is persisted whether
 * or not anything is ever delivered, so adding delivery later cannot change
 * what this function produces.
 */

import { createClient } from '@supabase/supabase-js'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const INVOKE_SECRET = Deno.env.get('CNG_ALERT_INVOKE_SECRET')

/** Constant-time compare, so a wrong secret cannot be found byte by byte. */
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

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405)
  }

  // 1. Fail closed rather than run unconfigured.
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY || !INVOKE_SECRET) {
    console.error('generate-alerts: missing required configuration')
    return json({ error: 'not_configured' }, 503)
  }

  // 2. Authenticate the caller.
  const provided = req.headers.get('x-cng-alert-secret')
  if (!provided || !secretMatches(provided, INVOKE_SECRET)) {
    return json({ error: 'unauthorized' }, 401)
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  // 3. The whole job is one idempotent call. `as_of` is omitted so the function
  //    uses cng_business_date() — the Africa/Cairo calendar date, never UTC.
  const { data, error } = await supabase.rpc('cng_generate_alerts')

  if (error) {
    // Logged in full server-side; the response stays non-specific.
    console.error('generate-alerts: rpc failed', error.message)
    return json({ error: 'generation_failed' }, 500)
  }

  const row = Array.isArray(data) ? data[0] : data
  const result = { as_of: row?.as_of ?? null, created: row?.created ?? 0 }
  console.log(`generate-alerts: as_of=${result.as_of} created=${result.created}`)
  return json(result, 200)
})
