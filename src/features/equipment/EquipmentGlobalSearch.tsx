import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { Search } from 'lucide-react'
import { useNavigate } from 'react-router-dom'

import { searchTerm } from '@/features/relief-valves/srvSearch'
import { useSupabaseClient } from '@/lib/supabase/client'
import { KINDS, type EquipmentKind } from './equipmentKinds'
import { equipmentLink, rankEquipmentHits, type EquipmentHit, type EquipmentTab } from './equipmentSearch'

/**
 * One search over every Hoses / Gas Detectors tab (owner request 2026-10-10, as the relief valves have it —
 * SrvGlobalSearch): type a serial (or warehouse code) and see where that item is — installed at a station, in the
 * warehouse, out awaiting return, or at the 3rd party — then jump straight to it: its tab opens filtered to it (with
 * its details open where the tab has them). Read-only, under the caller's RLS.
 */

const PER_SOURCE = 8

const join = (...parts: (string | null | undefined)[]) => parts.filter(Boolean).join(' · ') || null

export function EquipmentGlobalSearch({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const TAB_LABEL: Record<EquipmentTab, string> = { installed: 'Installed', warehouse: 'Warehouse', log: 'Log', jobs: kind === 'hose' ? 'Hydrotest' : 'Calibration' }
  const supabase = useSupabaseClient()
  const navigate = useNavigate()
  const listId = useId()
  const [text, setText] = useState('')
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(0)
  const [result, setResult] = useState<{ term: string; hits: EquipmentHit[]; error: string | null } | null>(null)
  const box = useRef<HTMLDivElement>(null)
  const term = searchTerm(text)
  const ready = Boolean(supabase) && term.length >= 2

  useEffect(() => {
    if (!ready || !supabase) return
    let cancelled = false
    const like = `serial_number.ilike.*${term}*,warehouse_code.ilike.*${term}*`
    const serialOnly = `serial_number.ilike.*${term}*`
    const installed = kind === 'hose'
      ? supabase.from('v_hose_registry').select('id, serial_number, unit_name, station_name, region_name').or(serialOnly).limit(PER_SOURCE)
      : supabase.from('v_gas_detector_management').select('id:detector_id, serial_number, unit_name, station_name, region_name')
        .not('detector_id', 'is', null).or(serialOnly).limit(PER_SOURCE)
    const timer = setTimeout(() => {
      void Promise.all([
        installed,
        supabase.from('v_equipment_stock').select('id, serial_number, warehouse_code, availability_status').eq('kind', kind)
          .or(like).limit(PER_SOURCE),
        supabase.from('v_equipment_field_log').select('id, serial_number, station_name, unit_name, region_name').eq('kind', kind)
          .eq('status', 'at_station').or(serialOnly).limit(PER_SOURCE),
        supabase.from('v_equipment_calibration').select('id, serial_number, warehouse_code').eq('kind', kind)
          .in('status', ['sent', 'returned_awaiting_certificate']).or(like).limit(PER_SOURCE),
      ]).then(([i, w, l, c]) => {
        if (cancelled) return
        const failed = [i, w, l, c].find((x) => x.error)
        type Row = Record<string, string | null>
        const rows = (x: { data: unknown }) => (x.data ?? []) as Row[]
        const state = (s: string | null) => (s && s in spec.stateLabel ? spec.stateLabel[s as keyof typeof spec.stateLabel] : s)
        const hits: EquipmentHit[] = [
          ...rows(i).map((r) => ({ tab: 'installed' as const, id: r.id as string, serial: r.serial_number, code: null,
            place: join(r.unit_name ?? r.station_name, r.region_name) })),
          ...rows(w).map((r) => ({ tab: 'warehouse' as const, id: r.id as string, serial: r.serial_number, code: r.warehouse_code,
            place: join('in the warehouse', state(r.availability_status)) })),
          ...rows(l).map((r) => ({ tab: 'log' as const, id: r.id as string, serial: r.serial_number, code: null,
            place: join('awaiting return from', r.unit_name ?? r.station_name, r.region_name) })),
          ...rows(c).map((r) => ({ tab: 'jobs' as const, id: r.id as string, serial: r.serial_number, code: r.warehouse_code,
            place: 'at the 3rd party' })),
        ]
        setResult({ term, hits: rankEquipmentHits(hits, term), error: failed?.error?.message ?? null })
        setActive(0)
      })
    }, 300)
    return () => { cancelled = true; clearTimeout(timer) }
  }, [ready, supabase, term, kind, spec])

  // Close the list on a click outside it.
  useEffect(() => {
    const away = (e: MouseEvent) => { if (box.current && !box.current.contains(e.target as Node)) setOpen(false) }
    document.addEventListener('mousedown', away)
    return () => document.removeEventListener('mousedown', away)
  }, [])

  const current = ready && result?.term === term ? result : null
  const hits = current?.hits ?? []

  function go(h: EquipmentHit) {
    setOpen(false)
    navigate(equipmentLink(kind, h.tab, h.serial ?? h.code ?? term, h.id))
  }
  function onKey(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Escape') { setOpen(false); return }
    if (!hits.length) return
    if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setActive((a) => Math.min(a + 1, hits.length - 1)) }
    if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)) }
    if (e.key === 'Enter') { e.preventDefault(); go(hits[Math.min(active, hits.length - 1)]) }
  }

  return (
    <div ref={box} className="relative w-full max-w-xl">
      <Search className="pointer-events-none absolute left-2 top-2 h-4 w-4 text-muted-foreground" aria-hidden="true" />
      <input id={`${listId}-input`} type="search" aria-label={`Find a ${spec.one} in every tab`} dir="auto" autoComplete="off" value={text}
             placeholder={`Find a ${spec.one} anywhere — serial or warehouse code`}
             role="combobox" aria-expanded={open && ready} aria-controls={listId} aria-autocomplete="list"
             onChange={(e) => { setText(e.target.value); setOpen(true) }} onFocus={() => setOpen(true)} onKeyDown={onKey}
             className="h-8 w-full rounded border bg-background pl-8 pr-2 text-sm text-foreground" />
      {open && ready ? (
        <div id={listId} role="listbox" aria-label={`Where this ${spec.one} is`}
             className="absolute z-30 mt-1 max-h-80 w-full overflow-y-auto rounded border bg-popover p-1 shadow-md">
          {!current ? <p className="px-2 py-1.5 text-xs text-muted-foreground" role="status">Searching every tab…</p>
            : current.error ? <p className="px-2 py-1.5 text-xs text-destructive" role="alert">Could not search: {current.error}</p>
            : hits.length === 0 ? <p className="px-2 py-1.5 text-xs text-muted-foreground">No {spec.one} matches “{term}”.</p>
            : hits.map((h, n) => (
              <button key={`${h.tab}:${h.id}`} type="button" role="option" aria-selected={n === active}
                      onMouseEnter={() => setActive(n)} onClick={() => go(h)}
                      className={`flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-sm ${n === active ? 'bg-muted' : ''}`}>
                <span className="w-24 shrink-0 rounded border px-1.5 py-0.5 text-center text-xs">{TAB_LABEL[h.tab]}</span>
                {h.serial ? <span className="font-technical" dir="ltr">{h.serial}</span>
                  : <span className="text-xs text-muted-foreground">serial not recorded</span>}
                {h.code ? <span className="font-technical text-xs text-muted-foreground" dir="ltr">{h.code}</span> : null}
                {h.place ? <span className="ml-auto truncate text-xs text-muted-foreground" dir="auto">{h.place}</span> : null}
              </button>
            ))}
        </div>
      ) : null}
    </div>
  )
}
