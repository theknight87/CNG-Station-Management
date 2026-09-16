import { useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * The audit log.
 *
 * READ ONLY, and not by convention: `audit_logs` carries no UPDATE or DELETE
 * grant for any browser role, so history cannot be rewritten from here even by
 * an administrator. The actor is resolved server-side at write time and is not
 * a caller parameter, so a row cannot be attributed to somebody else.
 */
export interface AuditLogRow {
  id: string
  action: string
  entity_table: string
  entity_id: string | null
  actor_id: string | null
  actor_label: string | null
  summary: string | null
  occurred_at: string
}

const PAGE_SIZE = 100

export function useAdminAuditLog(actionFilter: string): {
  entries: AuditLogRow[] | null
  loadError: string | null
} {
  const supabase = useSupabaseClient()
  const [entries, setEntries] = useState<AuditLogRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      let query = supabase
        .from('v_admin_audit_log')
        .select('id, action, entity_table, entity_id, actor_id, actor_label, summary, occurred_at')
        .order('occurred_at', { ascending: false })
        .limit(PAGE_SIZE)
      if (actionFilter) query = query.eq('action', actionFilter)
      const { data, error } = await query
      if (cancelled) return
      if (error) {
        setLoadError(error.message)
        return
      }
      setLoadError(null)
      setEntries((data ?? []) as AuditLogRow[])
    }
    void load()
    return () => {
      cancelled = true
    }
  }, [supabase, actionFilter])

  return { entries, loadError }
}
