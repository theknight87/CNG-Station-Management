import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * A user's own notification preferences.
 *
 * OPT-IN IS THE DEFAULT STATE, AND ABSENCE MEANS OFF. `cng_enqueue_alert_deliveries`
 * only ever selects users who HAVE a row with `is_enabled`, so a user with no
 * preferences receives nothing. That is deliberate — nobody is subscribed by a
 * migration, and this screen is the only thing that changes it.
 *
 * SCOPE: the CHANNEL-level preference, the row where `subject IS NULL`, which
 * the schema defines as "applies to every subject". The table also supports
 * per-subject rows and the engine honours them; exposing that needs a precedence
 * UI that makes "SRV calibration overrides my default" legible, so it is left to
 * a later prompt rather than half-built here.
 *
 * REGION is NOT a preference and never will be. Which Regions a user receives
 * alerts for comes from `user_region_access` — their authorization — and the
 * enqueue function applies it. A preference that could WIDEN that would be a
 * privilege bug wearing a settings control.
 */
export type NotificationChannel = 'email' | 'web_push'

/** Ordered loudest-first, matching the alert_threshold enum's own severity order. */
export const THRESHOLD_CHOICES = [
  { value: '', label: 'Every alert' },
  { value: 'due_60', label: '60 days or closer' },
  { value: 'due_30', label: '30 days or closer' },
  { value: 'due_15', label: '15 days or closer' },
  { value: 'due_7', label: '7 days or closer' },
  { value: 'due_today', label: 'Due today or overdue' },
  { value: 'overdue', label: 'Overdue only' },
] as const

export interface ChannelPreference {
  id: string | null
  isEnabled: boolean
  minThreshold: string
}

export type PreferenceMap = Record<NotificationChannel, ChannelPreference>

const EMPTY: ChannelPreference = { id: null, isEnabled: false, minThreshold: '' }

export function useNotificationPreferences(): {
  prefs: PreferenceMap | null
  /** A failure to READ. The screen cannot be shown at all. */
  loadError: string | null
  /** A failure to WRITE. The screen is fine; one change did not stick. */
  saveError: string | null
  saving: boolean
  save: (channel: NotificationChannel, next: Omit<ChannelPreference, 'id'>) => Promise<void>
} {
  const supabase = useSupabaseClient()
  const [prefs, setPrefs] = useState<PreferenceMap | null>(null)
  // Kept apart deliberately. Reporting a failed SAVE with the words of a failed
  // LOAD is what made the Prompt 18A defect look like a page that would not
  // load, when in fact the page had loaded and one write was rejected.
  const [loadError, setLoadError] = useState<string | null>(null)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [saving, setSaving] = useState(false)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      // RLS confines this to the caller's own rows; no user id is supplied.
      const { data, error: err } = await supabase
        .from('notification_preferences')
        .select('id, channel, is_enabled, min_threshold')
        .is('subject', null)
      if (cancelled) return
      if (err) {
        setLoadError(err.message)
        return
      }
      const next: PreferenceMap = { email: { ...EMPTY }, web_push: { ...EMPTY } }
      for (const row of data ?? []) {
        const channel = row.channel as NotificationChannel
        if (channel in next) {
          next[channel] = {
            id: row.id as string,
            isEnabled: Boolean(row.is_enabled),
            minThreshold: (row.min_threshold as string | null) ?? '',
          }
        }
      }
      setLoadError(null)
      setPrefs(next)
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  const save = useCallback(
    async (channel: NotificationChannel, next: Omit<ChannelPreference, 'id'>) => {
      if (!supabase || !prefs) return
      setSaving(true)
      setSaveError(null)
      const min_threshold = next.minThreshold === '' ? null : next.minThreshold
      const existing = prefs[channel].id
      // Insert-or-update by id rather than upsert: the uniqueness that matters
      // here is a PARTIAL index (one default row per channel), which an
      // onConflict target cannot name.
      const { error: err } = existing
        ? await supabase
            .from('notification_preferences')
            .update({ is_enabled: next.isEnabled, min_threshold })
            .eq('id', existing)
        : await supabase
            .from('notification_preferences')
            .insert({ channel, is_enabled: next.isEnabled, min_threshold })
      setSaving(false)
      if (err) {
        // A WRITE failed. Reporting it as a load failure is precisely the
        // misdiagnosis that made this defect look like a page that would not
        // open, so the two are kept apart.
        setSaveError(err.message)
        return
      }
      setNonce((n) => n + 1)
    },
    [supabase, prefs],
  )

  return { prefs, loadError, saveError, saving, save }
}
