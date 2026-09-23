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
  total: number | null
  page: number
  pageSize: number
  onPage: (page: number) => void
} {
  const supabase = useSupabaseClient()
  const [entries, setEntries] = useState<AuditLogRow[] | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [total, setTotal] = useState<number | null>(null)

  // A filter change restarts paging: keeping page 3 of a different question
  // would show a page that answers neither. The page number is stored WITH the
  // filter key it belongs to, so the reset is derived during render rather than
  // written by an effect that would cascade a second render.
  const key = JSON.stringify(filters)
  const [paging, setPaging] = useState({ key, page: 0 })
  const page = paging.key === key ? paging.page : 0

  useEffect(() => {
    let cancelled = false
    async function load() {
      if (!supabase) return
      setLoading(true)
      const safeSearch = filters.search.replace(/[(),*]/g, ' ').trim()
      const isUuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(safeSearch)
      let query = supabase
        .from('v_admin_audit_log')
        .select('id, action, entity_table, entity_id, actor_id, actor_label, summary, before_data, after_data, occurred_at', { count: 'exact' })
        .order('occurred_at', { ascending: false })
        .order('id', { ascending: false })
      if (filters.action) query = query.eq('action', filters.action)
      if (filters.actorId) query = query.eq('actor_id', filters.actorId)
      if (filters.entityTable) query = query.eq('entity_table', filters.entityTable)
      if (filters.from) query = query.gte('occurred_at', filters.from)
      if (filters.to) query = query.lte('occurred_at', `${filters.to}T23:59:59.999Z`)
      if (safeSearch) {
        // An id, or free text in the summary. `or` needs the value inline, so
        // commas and parentheses are stripped rather than escaped — they cannot
        // appear in a uuid and are not worth a broken filter in a summary.
        query = isUuid ? query.or(`summary.ilike.%${safeSearch}%,entity_id.eq.${safeSearch}`) : query.ilike('summary', `%${safeSearch}%`)
      }
      const { data, error, count } = await query.range(page * PAGE_SIZE, page * PAGE_SIZE + PAGE_SIZE - 1)
      if (cancelled) return
      setLoading(false)
      if (error) {
        setLoadError(error.message)
        return
      }
      const rows = (data ?? []) as AuditLogRow[]
      setEntries(rows)
      setTotal(count ?? null)
      setLoadError(null)
    }
    void load()
    return () => { cancelled = true }
  }, [supabase, key, page, filters])

  const onPage = useCallback((nextPage: number) => setPaging({ key, page: Math.max(0, nextPage) }), [key])

  return { entries, loadError, loading, total, page, pageSize: PAGE_SIZE, onPage }
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
