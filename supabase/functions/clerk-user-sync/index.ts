/**
 * Clerk -> Supabase user synchronization webhook.
 *
 * NOT DEPLOYED YET. Deployment requires the Clerk application to exist and its
 * secrets to be stored as Supabase Edge Function secrets. See
 * docs/authentication.md.
 *
 * SECURITY MODEL
 * --------------
 * 1. Every request must carry a valid Svix signature (Clerk's official webhook
 *    signing mechanism). A missing or invalid signature is rejected with 401
 *    before the body is parsed or trusted for anything.
 * 2. This function runs server-side only and uses the service-role key, which
 *    bypasses RLS. That is precisely why it must do as little as possible, and
 *    why the key is read from an Edge Function secret and never from a VITE_
 *    variable.
 * 3. IDENTITY SYNC AND AUTHORIZATION ARE SEPARATE CONCERNS. This function may
 *    write identity fields (email, name) and may create an account in a
 *    non-privileged pending state. It must NEVER write `role`, and never
 *    re-activate an account. A Clerk profile edit — including anything a user
 *    puts in their own Clerk metadata — therefore cannot grant database
 *    privileges. Role and region access change only through an admin acting
 *    against RLS-protected tables.
 * 4. Idempotent: repeated delivery of the same event cannot duplicate a user or
 *    alter an existing one's authorization.
 */

import { createClient } from 'jsr:@supabase/supabase-js@2'
import { Webhook } from 'npm:svix@1'

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const CLERK_WEBHOOK_SIGNING_SECRET = Deno.env.get('CLERK_WEBHOOK_SIGNING_SECRET')!

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
    deleted?: boolean
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

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 })
  }

  // --- 1. Signature verification, before the payload is trusted at all -------
  const svixId = req.headers.get('svix-id')
  const svixTimestamp = req.headers.get('svix-timestamp')
  const svixSignature = req.headers.get('svix-signature')

  if (!svixId || !svixTimestamp || !svixSignature) {
    // Missing signature headers: refuse without reading the body.
    return new Response(JSON.stringify({ error: 'missing signature headers' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const rawBody = await req.text()

  let event: ClerkUserEvent
  try {
    const wh = new Webhook(CLERK_WEBHOOK_SIGNING_SECRET)
    // Throws on an invalid signature, a tampered body, or a stale timestamp
    // (which is what gives us replay protection).
    event = wh.verify(rawBody, {
      'svix-id': svixId,
      'svix-timestamp': svixTimestamp,
      'svix-signature': svixSignature,
    }) as ClerkUserEvent
  } catch (_err) {
    // Deliberately no detail: do not help an attacker calibrate a forgery, and
    // never log the signing secret or the rejected body.
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
        // Least-privileged onboarding state: role `viewer` AND is_active=false.
        // cng_current_role() requires is_active, so a brand-new user resolves to
        // NULL role and can read nothing except their own app_users row. An
        // administrator must explicitly activate them and grant region access.
        //
        // ON CONFLICT DO NOTHING makes redelivery a no-op and, critically, means
        // a replayed user.created can never reset an already-approved account
        // back to pending.
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
        // Identity fields ONLY. `role` and `is_active` are intentionally absent:
        // authorization is not synchronized from Clerk.
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
        // Deactivate, never delete. Audit and mapping history reference
        // app_users with ON DELETE RESTRICT, and that history must survive the
        // account. Deactivation immediately removes all access, because
        // cng_current_role() returns NULL for an inactive user.
        const { error } = await supabase
          .from('app_users')
          .update({ is_active: false })
          .eq('clerk_user_id', clerkUserId)
        if (error) throw error
        break
      }

      default:
        // Unhandled event types are acknowledged so Clerk stops retrying.
        break
    }
  } catch (err) {
    console.error(JSON.stringify({
      event: 'clerk_webhook_error',
      type: event.type,
      svix_id: svixId,
      message: err instanceof Error ? err.message : 'unknown',
    }))
    return new Response(JSON.stringify({ error: 'processing failed' }), { status: 500 })
  }

  console.log(JSON.stringify({ event: 'clerk_webhook_ok', type: event.type, svix_id: svixId }))
  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  })
})
