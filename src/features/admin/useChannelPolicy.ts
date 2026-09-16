import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { describeAdminError } from './useAdminUsers'

/**
 * Organization-level delivery policy.
 *
 * THE DISTINCTION THIS HOOK EXISTS TO HOLD:
 *
 *   `/settings` is a USER saying "I want email".
 *   This is the ORGANIZATION saying "email is available at all".
 *
 *   effective delivery = policy permits the channel AND the user opted in.
 *
 * Disabling here writes NO user preference, so re-enabling restores exactly the
 * audience that existed before. That is the whole reason it is a separate table
 * rather than a bulk update over `notification_preferences`.
 *
 * IN-APP HAS NO OFF SWITCH, and the screen says so rather than offering a
 * control that always refuses. In-app is not a delivery channel — it is the
 * READ surface for compliance state, and hiding it would remove safety
 * visibility from people authorized to see it. The database enforces that with
 * `ncp_in_app_mandatory_ck`, so this is a statement of fact, not a UI choice.
 */
export interface ChannelPolicyRow {
  channel: 'email' | 'web_push' | 'in_app'
  is_enabled: boolean
  note: string | null
  updated_at: string
}

/** In-app is mandatory by design; see the note above and migration 0040. */
export const MANDATORY_CHANNELS: readonly string[] = ['in_app']

export const CHANNEL_LABELS: Record<string, string> = {
  email: 'Email',
  web_push: 'Web Push',
  in_app: 'In-app alerts',
}

export function useChannelPolicy(): {
  policy: ChannelPolicyRow[] | null
  loadError: string | null
  actionError: string | null
  busy: boolean
  setEnabled: (row: ChannelPolicyRow, enabled: boolean) => Promise<void>
} {
  const supabase = useSupabaseClient()
  const [policy, setPolicy] = useState<ChannelPolicyRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const { data, error } = await supabase
        .from('notification_channel_policy')
        .select('channel, is_enabled, note, updated_at')
        .order('channel')
      if (cancelled) return
      if (error) { setLoadError(error.message); return }
      setLoadError(null)
      setPolicy((data ?? []) as ChannelPolicyRow[])
    })()
    return () => { cancelled = true }
  }, [supabase, nonce])

  const setEnabled = useCallback(
    async (row: ChannelPolicyRow, enabled: boolean) => {
      if (!supabase) return
      setBusy(true)
      setActionError(null)
      const { error } = await supabase.rpc('cng_admin_set_channel_policy', {
        p_channel: row.channel,
        p_is_enabled: enabled,
        p_expected_updated_at: row.updated_at,
      })
      setBusy(false)
      if (error) { setActionError(describeAdminError(error.message)); return }
      setNonce((n) => n + 1)
    },
    [supabase],
  )

  return { policy, loadError, actionError, busy, setEnabled }
}
