import { useCallback, useEffect, useState } from 'react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { filterControl, filterLabel } from '@/components/data/filterStyles'
import { parseMulti } from '@/components/data/multiFilter'
import { Button } from '@/components/ui/button'
import { downloadBlob } from '@/features/export/exportData'
import {
  EQUIPMENT_ISSUE_SHEET_COLUMNS, buildEquipmentIssueWorkbook, equipmentIssueWorkbookName, groupEquipmentSheets, pendingEquipmentSheets,
  type EquipmentIssueSheetRow,
} from '@/features/export/equipmentIssueSheet'
import { monthRange } from '@/features/export/issueSheet'
import { cairoBusinessDate } from '@/features/reports/csv'
import { useRegionOptions } from '@/features/reports/useHierarchyOptions'
import { FormMessage } from '@/features/relief-valves/SrvWorkflowPieces'
import { useSupabaseClient } from '@/lib/supabase/client'
import { KINDS, type EquipmentKind } from './equipmentKinds'

/**
 * Export the hose / gas detector warehouse issue workbook for one Region and month (owner request 2026-10-10, as the
 * SRV IssueSheetDialog does). Issues not sent before are first placed in new sheets for their day, then the whole
 * month is written, so the sheets already sent are always reproduced exactly as they were.
 */
export function EquipmentIssueSheetDialog({ kind, open, regionFilter, onClose, onDone }: {
  kind: EquipmentKind
  open: boolean
  /** The Log's Region filter; a single chosen Region is the default. */
  regionFilter: string
  onClose: () => void
  onDone: (message: string) => void
}) {
  // Mounted only while open, so each opening starts from the current filter.
  return open ? <IssueSheetBody kind={kind} regionFilter={regionFilter} onClose={onClose} onDone={onDone} /> : null
}

function IssueSheetBody({ kind, regionFilter, onClose, onDone }: {
  kind: EquipmentKind
  regionFilter: string
  onClose: () => void
  onDone: (message: string) => void
}) {
  const spec = KINDS[kind]
  const Many = spec.many[0].toUpperCase() + spec.many.slice(1)
  const supabase = useSupabaseClient()
  const regions = useRegionOptions()
  const [regionId, setRegionId] = useState(() => {
    const chosen = parseMulti(regionFilter)
    return !chosen.exclude && chosen.values.length === 1 ? chosen.values[0] : ''
  })
  const [month, setMonth] = useState(() => cairoBusinessDate().slice(0, 7))
  // The month's rows, tagged with the Region and month they were read for, so a stale answer is never shown.
  const [result, setResult] = useState<{ key: string; rows: EquipmentIssueSheetRow[] | null; error: string | null } | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const key = `${regionId}:${month}`
  const ready = regionId !== '' && /^\d{4}-\d{2}$/.test(month)

  const load = useCallback(async (): Promise<EquipmentIssueSheetRow[]> => {
    if (!supabase) throw new Error('the database is not configured')
    const { from, to } = monthRange(month)
    const { data, error: e } = await supabase.from('v_equipment_issue_sheet').select(EQUIPMENT_ISSUE_SHEET_COLUMNS)
      .eq('kind', kind).eq('region_id', regionId).gte('issue_day', from).lt('issue_day', to).order('issued_at').limit(5000)
    if (e) throw new Error(e.message)
    return (data ?? []) as unknown as EquipmentIssueSheetRow[]
  }, [supabase, kind, regionId, month])

  useEffect(() => {
    if (!ready) return
    let cancelled = false
    load().then((r) => { if (!cancelled) setResult({ key, rows: r, error: null }) },
                (e: Error) => { if (!cancelled) setResult({ key, rows: null, error: e.message }) })
    return () => { cancelled = true }
  }, [ready, key, load])

  const current = ready && result?.key === key ? result : null
  const rows = current?.rows ?? null
  const loadError = current?.error ?? null

  const region = regions.find((r) => r.id === regionId)?.label ?? ''
  const sent = rows ? groupEquipmentSheets(rows, region) : []
  const pending = rows ? pendingEquipmentSheets(rows, region) : []

  async function exportWorkbook() {
    if (!supabase || !regionId) return
    setBusy(true); setError(null)
    try {
      let placed = 0
      if (pending.length > 0) {
        const { data, error: e } = await supabase.rpc('cng_equipment_issue_sheet_assign', { p_kind: kind, p_region_id: regionId, p_month: `${month}-01` })
        if (e) throw new Error(e.message)
        placed = Number(data ?? 0)
      }
      const fresh = await load()
      setResult({ key, rows: fresh, error: null })
      const sheets = groupEquipmentSheets(fresh, region)
      if (sheets.length === 0) { setError(`No ${spec.many} were issued to ${region} in this month; nothing was downloaded.`); return }
      downloadBlob(equipmentIssueWorkbookName(kind, region, month), await buildEquipmentIssueWorkbook(kind, region, sheets))
      onDone(placed > 0
        ? `Workbook downloaded: ${sheets.length} sheet(s); ${placed} ${spec.many} placed in new sheet(s).`
        : `Workbook downloaded: ${sheets.length} sheet(s); nothing new since the last export.`)
      onClose()
    } catch (e) {
      setError(`The export failed: ${e instanceof Error ? e.message : 'unknown error'}. Nothing was downloaded.`)
    } finally {
      setBusy(false)
    }
  }

  return (
    <RecordDetailsDialog open title={`${Many}: warehouse issue sheet`}
                         description={`One workbook per Region and month, one sheet per issue day. ${Many} not sent before go in a new sheet for their day.`}
                         onClose={onClose}>
      <div className="flex flex-wrap items-end gap-3">
        <label className={filterLabel} htmlFor={`${kind}-issue-sheet-region`}>
          Region
          <select id={`${kind}-issue-sheet-region`} className={filterControl} value={regionId} onChange={(e) => setRegionId(e.target.value)}>
            <option value="">Choose a Region</option>
            {regions.map((r) => <option key={r.id} value={r.id}>{r.label}</option>)}
          </select>
        </label>
        <label className={filterLabel} htmlFor={`${kind}-issue-sheet-month`}>
          Month
          <input id={`${kind}-issue-sheet-month`} type="month" className={filterControl} value={month} onChange={(e) => setMonth(e.target.value)} />
        </label>
      </div>

      <section aria-label="What the workbook will hold" className="mt-3 text-sm">
        {!regionId ? <p className="text-muted-foreground">Choose the Region to export.</p>
          : loadError ? <p role="alert" className="text-destructive">Could not read the issues: {loadError}</p>
          : rows === null ? <p className="text-muted-foreground">Reading the month's issues…</p>
          : rows.length === 0 ? <p className="text-muted-foreground">No {spec.many} were issued to {region} in this month.</p>
          : (
            <div className="flex flex-col gap-2">
              <p>
                <span className="font-medium">Already sent:</span>{' '}
                {sent.length === 0 ? 'none'
                  : `${sent.length} sheet(s), ${sent.reduce((n, s) => n + s.rows.length, 0)} ${spec.many} — written again unchanged.`}
              </p>
              {rows.some((r) => r.is_cancelled) ? (
                <p>
                  <span className="font-medium">Undone after leaving the warehouse:</span>{' '}
                  {rows.filter((r) => r.is_cancelled).length} {spec.many} — kept on their sheet, marked ملغي in the return column.
                </p>
              ) : null}
              <div>
                <span className="font-medium">New:</span>{' '}
                {pending.length === 0 ? 'nothing since the last export.' : (
                  <ul className="mt-1 list-disc pl-5">
                    {pending.map((p) => <li key={p.day}><span dir="ltr">{p.name}</span> — {p.count} {spec.many}</li>)}
                  </ul>
                )}
              </div>
            </div>
          )}
      </section>

      <FormMessage error={error} done={null} />
      <div className="mt-3 flex justify-end gap-2">
        <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
        <Button size="sm" disabled={busy || !rows || rows.length === 0} onClick={() => void exportWorkbook()}>
          {busy ? 'Preparing…' : 'Export workbook'}
        </Button>
      </div>
    </RecordDetailsDialog>
  )
}
