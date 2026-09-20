/**
 * RETIRED 2026-09-20. Kept only as rollback evidence; do not deploy for new
 * environments. Supabase Auth now provisions app_users through migration 0056.
 *
 * Clerk -> Supabase user synchronization webhook.
 *
 * verify_jwt is deliberately FALSE: Clerk sends a Svix-signed request, not a
 * Supabase JWT. This function implements its own authentication (Svix signature
 * verification) and refuses everything that fails it.
 *
 * SECURITY MODEL
 * 1. Fails CLOSED when unconfigured (503) - an unsigned body is never trusted.
 * 2. Every request must carry a valid Svix signature; missing or invalid -> 401.
 * 3. Runs server-side with the service-role key, which bypasses RLS. That is
 *    why it does as little as possible and why the key never reaches a browser.
 *    Its SQL privileges are narrowed to app_users alone (migration 0023): it
 *    cannot write `role`, cannot grant region access, and cannot delete.
 * 4. IDENTITY SYNC AND AUTHORIZATION ARE SEPARATE CONCERNS. It may write email
 *    and name, and may create an account in a non-privileged pending state. It
 *    must NEVER write `role` and never re-activate an account, so no Clerk
 *    profile edit can grant database privileges.
 * 5. Idempotent: redelivery cannot duplicate a user or alter authorization.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { Webhook } from 'npm:svix@1'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
const CLERK_WEBHOOK_SIGNING_SECRET = Deno.env.get('CLERK_WEBHOOK_SIGNING_SECRET')

interface ClerkEmail {
  id: string
  email_address: string
}

interface ClerkUserEvent {
  type: 'user.created' | 'user.updated' | 'user.deleted' | string
  data: {
    id: string
    first_name?: string | null
    last_name?: string | null
    primary_email_address_id?: string | null
    email_addresses?: ClerkEmail[]
  }
}

function primaryEmail(data: ClerkUserEvent['data']): string | null {
  const list = data.email_addresses ?? []
  const primary = list.find((e) => e.id === data.primary_email_address_id) ?? list[0]
  return primary?.email_address ?? null
}

function fullName(data: ClerkUserEvent['data']): string | null {
  const name = [data.first_name, data.last_name].filter(Boolean).join(' ').trim()
  return name.length > 0 ? name : null
}

/** Diagnostics for the log only. The response body stays deliberately opaque. */
function describeError(err: unknown): Record<string, string> {
  if (err && typeof err === 'object') {
    const e = err as { message?: unknown; code?: unknown; details?: unknown; hint?: unknown }
    const out: Record<string, string> = {}
    if (typeof e.message === 'string') out.message = e.message
    if (typeof e.code === 'string') out.code = e.code
    if (typeof e.details === 'string') out.details = e.details
    if (typeof e.hint === 'string') out.hint = e.hint
    if (Object.keys(out).length > 0) return out
  }
  return { message: String(err) }
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 })
  }

  // --- 0. Fail CLOSED if the deployment is not fully configured ------------
  if (!CLERK_WEBHOOK_SIGNING_SECRET || !SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error(JSON.stringify({
      event: 'clerk_webhook_unconfigured',
      has_signing_secret: Boolean(CLERK_WEBHOOK_SIGNING_SECRET),
      has_supabase_url: Boolean(SUPABASE_URL),
      has_service_role_key: Boolean(SERVICE_ROLE_KEY),
    }))
    return new Response(
      JSON.stringify({ error: 'webhook not configured; refusing all requests' }),
      { status: 503, headers: { 'Content-Type': 'application/json' } },
    )
  }

  // --- 1. Signature verification, before the payload is trusted at all ------
  const svixId = req.headers.get('svix-id')
  const svixTimestamp = req.headers.get('svix-timestamp')
  const svixSignature = req.headers.get('svix-signature')

  if (!svixId || !svixTimestamp || !svixSignature) {
    return new Response(JSON.stringify({ error: 'missing signature headers' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const rawBody = await req.text()

  let event: ClerkUserEvent
  try {
    const wh = new Webhook(CLERK_WEBHOOK_SIGNING_SECRET)
    // Throws on invalid signature, tampered body, or stale timestamp (replay).
    event = wh.verify(rawBody, {
      'svix-id': svixId,
      'svix-timestamp': svixTimestamp,
      'svix-signature': svixSignature,
    }) as ClerkUserEvent
  } catch (_err) {
    // No detail: do not help calibrate a forgery, and never log the secret.
    console.warn(JSON.stringify({ event: 'clerk_webhook_rejected', reason: 'invalid_signature', svix_id: svixId }))
    return new Response(JSON.stringify({ error: 'invalid signature' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const clerkUserId = event.data?.id
  if (!clerkUserId) {
    return new Response(JSON.stringify({ error: 'missing user id' }), { status: 400 })
  }

  try {
    switch (event.type) {
      case 'user.created': {
        // Least-privileged onboarding: role viewer AND is_active=false.
        // cng_current_role() requires is_active, so a new user resolves to a
        // NULL role and can read nothing but their own app_users row.
        // ignoreDuplicates makes redelivery a no-op, so a replayed
        // user.created can never reset an approved account back to pending.
        const { error } = await supabase
          .from('app_users')
          .upsert(
            {
              clerk_user_id: clerkUserId,
              email: primaryEmail(event.data),
              full_name: fullName(event.data),
              role: 'viewer',
              is_active: false,
            },
            { onConflict: 'clerk_user_id', ignoreDuplicates: true },
          )
        if (error) throw error
        break
      }

      case 'user.updated': {
        // Identity fields ONLY. role and is_active are intentionally absent.
        const { error } = await supabase
          .from('app_users')
          .update({
            email: primaryEmail(event.data),
            full_name: fullName(event.data),
          })
          .eq('clerk_user_id', clerkUserId)
        if (error) throw error
        break
      }

      case 'user.deleted': {
        // Deactivate, never delete: audit and mapping history reference
        // app_users with ON DELETE RESTRICT and must outlive the account.
        // Deactivation removes all access immediately.
        const { error } = await supabase
          .from('app_users')
          .update({ is_active: false })
          .eq('clerk_user_id', clerkUserId)
        if (error) throw error
        break
      }

      default:
        break
    }
  } catch (err) {
    // A PostgrestError is a plain object, not an Error, so `instanceof Error`
    // reported every database failure as "unknown" and hid the real cause.
    // Postgres error text is server-side diagnostics (a privilege denial names
    // a table, never a value) and never contains a key or a token.
    console.error(JSON.stringify({
      event: 'clerk_webhook_error',
      type: event.type,
      svix_id: svixId,
      ...describeError(err),
    }))
    return new Response(JSON.stringify({ error: 'processing failed' }), { status: 500 })
  }

  console.log(JSON.stringify({ event: 'clerk_webhook_ok', type: event.type, svix_id: svixId }))
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
