import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'
import { describeAdminError } from './useAdminUsers'

/**
 * Alert settings.
 *
 * ONLY `is_enabled` IS EDITABLE. Subject, threshold and days_before are rule
 * IDENTITY: alerts already raised carry the threshold they were raised under,
 * and editing the window would retroactively change what those alerts mean.
 * There is no function to edit them and no direct grant, so the restriction is
 * a database property rather than a disabled control.
 *
 * Disabling stops FUTURE generation. It deletes nothing: an alert that was
 * raised stays raised, and stays acknowledgeable.
 */
export interface AlertRuleRow {
  id: string
  subject: string
  threshold: string
  days_before: number | null
  is_enabled: boolean
  updated_at: string
}

export interface AdminSettingsState {
  rules: AlertRuleRow[] | null
  loadError: string | null
  actionError: string | null
  busy: boolean
  setEnabled: (rule: AlertRuleRow, enabled: boolean) => Promise<void>
}

export function useAdminAlertRules(): AdminSettingsState {
  const supabase = useSupabaseClient()
  const [rules, setRules] = useState<AlertRuleRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [actionError, setActionError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [nonce, setNonce] = useState(0)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      const { data, error } = await supabase
        .from('alert_rules')
        .select('id, subject, threshold, days_before, is_enabled, updated_at')
        .order('subject')
        .order('days_before', { nullsFirst: false })
      if (cancelled) return
      if (error) {
        setLoadError(error.message)
        return
      }
      setLoadError(null)
      setRules((data ?? []) as AlertRuleRow[])
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, nonce])

  const setEnabled = useCallback(
    async (rule: AlertRuleRow, enabled: boolean) => {
      if (!supabase) return
      setBusy(true)
      setActionError(null)
      const { error } = await supabase.rpc('cng_admin_set_alert_rule_enabled', {
        p_rule_id: rule.id,
        p_is_enabled: enabled,
        p_expected_updated_at: rule.updated_at,
      })
      setBusy(false)
      if (error) {
        setActionError(describeAdminError(error.message))
        return
      }
      setNonce((n) => n + 1)
    },
    [supabase],
  )

  return { rules, loadError, actionError, busy, setEnabled }
}
