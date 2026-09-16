import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * The audit log.
 *
 * READ ONLY, and not by convention: `audit_logs` carries no UPDATE or DELETE
 * grant for any browser role, so history cannot be rewritten from here even by
 * an administrator. The actor is resolved server-side at write time and is not a
 * caller parameter, so a row cannot be attributed to somebody else.
 *
 * PAGINATION IS BOUNDED, NOT CAPPED. Each request fetches one page; "Load more"
 * fetches the next. There is no permanent ceiling, and the filters below exist
 * so an administrator can reach an old entry without walking the whole history.
 */
export interface AuditLogRow {
  id: string
  action: string
  entity_table: string
  entity_id: string | null
  actor_id: string | null
  actor_label: string | null
  summary: string | null
  before_data: unknown
  after_data: unknown
  occurred_at: string
}

export interface AuditFilters {
  action: string
  actorId: string
  entityTable: string
  /** Matches an entity id, or any text in the summary. */
  search: string
  from: string
  to: string
}

export const EMPTY_AUDIT_FILTERS: AuditFilters = {
  action: '', actorId: '', entityTable: '', search: '', from: '', to: '',
}

export const PAGE_SIZE = 50

export function useAdminAuditLog(filters: AuditFilters): {
  entries: AuditLogRow[] | null
  loadError: string | null
  loading: boolean
  hasMore: boolean
  loadMore: () => void
} {
  const supabase = useSupabaseClient()
  const [entries, setEntries] = useState<AuditLogRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [hasMore, setHasMore] = useState(false)

  // A filter change restarts paging: keeping page 3 of a different question
  // would show a page that answers neither. The page number is stored WITH the
  // filter key it belongs to, so the reset is derived during render rather than
  // written by an effect that would cascade a second render.
  const key = JSON.stringify(filters)
  const [paging, setPaging] = useState({ key, pages: 1 })
  const pages = paging.key === key ? paging.pages : 1

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      setLoading(true)
      const limit = pages * PAGE_SIZE
      let query = supabase
        .from('v_admin_audit_log')
        .select('id, action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at')
        .order('occurred_at', { ascending: false })
        // One extra row, purely to learn whether another page exists without
        // asking for a count the database would have to compute.
        .limit(limit + 1)
      if (filters.action) query = query.eq('action', filters.action)
      if (filters.actorId) query = query.eq('actor_id', filters.actorId)
      if (filters.entityTable) query = query.eq('entity_table', filters.entityTable)
      if (filters.from) query = query.gte('occurred_at', filters.from)
      if (filters.to) query = query.lte('occurred_at', `${filters.to}T23:59:59.999Z`)
      if (filters.search) {
        // An id, or free text in the summary. `or` needs the value inline, so
        // commas and parentheses are stripped rather than escaped — they cannot
        // appear in a uuid and are not worth a broken filter in a summary.
        const safe = filters.search.replace(/[(),*]/g, ' ').trim()
        if (safe) query = query.or(`summary.ilike.%${safe}%,entity_id.eq.${safe}`)
      }
      const { data, error } = await query
      if (cancelled) return
      setLoading(false)
      if (error) {
        // An `entity_id.eq.<not a uuid>` is a type error, not a broken screen.
        // Fall back to a summary-only search rather than showing a database
        // message about uuid syntax.
        if (filters.search && /invalid input syntax|uuid/i.test(error.message)) {
          const safe = filters.search.replace(/[(),*]/g, ' ').trim()
          const retry = await supabase
            .from('v_admin_audit_log')
            .select('id, action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at')
            .order('occurred_at', { ascending: false })
            .limit(limit + 1)
            .ilike('summary', `%${safe}%`)
          if (cancelled) return
          if (!retry.error) {
            const rows = (retry.data ?? []) as AuditLogRow[]
            setHasMore(rows.length > limit)
            setEntries(rows.slice(0, limit))
            setLoadError(null)
            return
          }
        }
        setLoadError(error.message)
        return
      }
      const rows = (data ?? []) as AuditLogRow[]
      setHasMore(rows.length > limit)
      setEntries(rows.slice(0, limit))
      setLoadError(null)
    }
    void load()
    return () => { cancelled = true }
  }, [supabase, key, pages, filters])

  const loadMore = useCallback(() => setPaging({ key, pages: pages + 1 }), [key, pages])

  return { entries, loadError, loading, hasMore, loadMore }
}

/** Distinct actors, for the actor filter. Read through the same admin view. */
export function useAuditActors(): { id: string; label: string }[] {
  const supabase = useSupabaseClient()
  const [actors, setActors] = useState<{ id: string; label: string }[]>([])
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase) return
      const { data } = await supabase.from('v_admin_users').select('id, full_name, email')
      if (cancelled) return
      setActors((data ?? []).map((r) => ({
        id: r.id as string,
        label: (r.full_name as string | null) ?? (r.email as string | null) ?? (r.id as string),
      })))
    })()
    return () => { cancelled = true }
  }, [supabase])
  return actors
}
