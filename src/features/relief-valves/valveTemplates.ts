import { useEffect, useRef, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * Fill a new relief valve from the valves already recorded with the same manufacturer and set pressure (owner request
 * 2026-10-04): part number, size type, inlet, outlet and warehouse code are what valves of one type and pressure share.
 * Nothing is invented — every option is a combination real records carry, with how many carry it. One combination is
 * filled in by itself (only into fields the user has not typed); several are offered for the user to choose. Blank
 * fields and one-or-two-record oddities are not offered as versions (owner 2026-10-05; see groupTemplates).
 */

/** The relief-valve manufacturers recorded in the system, offered as a list in both add forms (owner request 2026-10-05). */
export const VALVE_MANUFACTURERS = ['Anderson', 'Aspro', 'COI', 'DK-LOK', 'EKC', 'Farinola', 'Mercer', 'TAKEI', 'Taylor', 'Technical', 'Tyco Anderson']

export interface ValveTemplate {
  part_number: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  /** The two-letter base code ("sb 20"); the condition letter (C / U) follows the valve's state. */
  base_code: string | null
  count: number
}

export interface TemplateSource {
  part_number: string | null
  size_type: string | null
  inlet_size: string | null
  outlet_size: string | null
  warehouse_code: string | null
}

const clean = (v: string | null | undefined) => (v ?? '').trim() || null

/** "sbc 20" / "sbu 20" / "sb 20" -> "sb 20" — the owner's code rule (cng_srv_code_for); other shapes unchanged. */
export function baseCode(code: string | null | undefined): string | null {
  const c = clean(code)
  if (!c) return null
  const m = /^([A-Za-z]+)(\s*\d.*)$/.exec(c)
  if (!m) return c
  return m[1].length === 3 && /[cu]$/i.test(m[1]) ? m[1].slice(0, 2) + m[2] : c
}

/** The code of a calibrated valve ("sb 20" -> "sbc 20"), keeping the letters' case; other shapes unchanged. */
export function calibratedCode(base: string | null): string | null {
  if (!base) return null
  const m = /^([A-Za-z]{2})(\s*\d.*)$/.exec(base)
  if (!m) return base
  return m[1] + (m[1] === m[1].toLowerCase() ? 'c' : 'C') + m[2]
}

/** A record (or combination) as its five comparable values: case is not a difference for size type and code. */
function parts(t: Omit<ValveTemplate, 'count'>): (string | null)[] {
  return [t.part_number, t.size_type?.toLowerCase() ?? null, t.inlet_size, t.outlet_size, t.base_code?.toLowerCase() ?? null]
}

/** How many of `rare` or fewer records make a combination a typing mistake when a commoner one exists (owner 2026-10-05). */
export const RARE_VARIANT = 2

/**
 * The combinations the records carry, most common first (owner rulings 2026-10-04 / 2026-10-05):
 *  - a record with none of the five values is skipped;
 *  - a missing value is not a different version: a combination that only leaves blank what a fuller one records is
 *    counted with the commonest fuller one (e.g. installed valves recorded without a part number);
 *  - one or two records that differ from a commoner combination are a mistake, not a version, and are not offered —
 *    unless every combination is that rare, in which case all are shown.
 * Nothing is invented: every value offered is one real records carry.
 */
export function groupTemplates(rows: TemplateSource[]): ValveTemplate[] {
  const by = new Map<string, ValveTemplate>()
  for (const r of rows) {
    const t = {
      part_number: clean(r.part_number), size_type: clean(r.size_type), inlet_size: clean(r.inlet_size),
      outlet_size: clean(r.outlet_size), base_code: baseCode(r.warehouse_code),
    }
    if (Object.values(t).every((v) => v === null)) continue
    const key = JSON.stringify(parts(t))
    const seen = by.get(key)
    if (seen) seen.count += 1
    else by.set(key, { ...t, count: 1 })
  }
  const known = (t: ValveTemplate) => parts(t).filter((v) => v !== null).length
  // Least specific first, so each folds into the commonest combination that records everything it records and more.
  const combos = [...by.values()].sort((a, b) => known(a) - known(b))
  const merged = new Set<ValveTemplate>()
  for (const c of combos) {
    const mine = parts(c)
    let best: ValveTemplate | null = null
    for (const o of combos) {
      if (o === c || merged.has(o) || known(o) <= known(c)) continue
      const theirs = parts(o)
      if (mine.every((v, i) => v === null || v === theirs[i]) && (!best || o.count > best.count)) best = o
    }
    if (best) { best.count += c.count; merged.add(c) }
  }
  const kept = combos.filter((c) => !merged.has(c))
  const top = Math.max(0, ...kept.map((c) => c.count))
  const offered = top > RARE_VARIANT ? kept.filter((c) => c.count > RARE_VARIANT) : kept
  return offered.sort((a, b) => b.count - a.count || JSON.stringify(a).localeCompare(JSON.stringify(b)))
}

/** "SS-4R3A · Male 1/2" X 3/4" · sb 20" */
export function templateLabel(t: ValveTemplate): string {
  const size = [t.inlet_size, t.outlet_size].filter(Boolean).join(' X ')
  return [t.part_number ? `P/N ${t.part_number}` : null, [t.size_type, size].filter(Boolean).join(' ') || null, t.base_code]
    .filter(Boolean).join(' · ')
}

const COLUMNS = 'part_number, size_type, inlet_size, outlet_size, warehouse_code'

/**
 * The templates for a manufacturer and set pressure, read from the warehouse and the installed valves (the caller's RLS).
 * `onLoaded` runs once per answer, with the templates for exactly what was asked.
 */
export function useValveTemplates(manufacturer: string, pressure: number | null | undefined, unit: string,
                                  onLoaded: (templates: ValveTemplate[]) => void) {
  const supabase = useSupabaseClient()
  const maker = manufacturer.trim()
  const ready = Boolean(supabase) && maker !== '' && typeof pressure === 'number'
  const key = ready ? `${maker.toLowerCase()}|${pressure}|${unit}` : ''
  const [result, setResult] = useState<{ key: string; templates: ValveTemplate[] } | null>(null)
  const callback = useRef(onLoaded)
  useEffect(() => { callback.current = onLoaded })

  useEffect(() => {
    if (!ready || !supabase || typeof pressure !== 'number') return
    let cancelled = false
    const pattern = maker.replace(/[\\%_]/g, (c) => `\\${c}`)
    const read = (view: string) => supabase.from(view).select(COLUMNS).ilike('manufacturer', pattern)
      .eq('pressure_min', pressure).eq('pressure_max', pressure).eq('pressure_unit', unit).limit(2000)
    // Wait for the typing to settle before asking.
    const timer = setTimeout(() => {
      void Promise.all([read('v_warehouse_srv_management'), read('v_installed_srv_management')]).then(([w, i]) => {
        if (cancelled) return
        const templates = groupTemplates([...((w.data ?? []) as TemplateSource[]), ...((i.data ?? []) as TemplateSource[])])
        setResult({ key, templates })
        callback.current(templates)
      })
    }, 350)
    return () => { cancelled = true; clearTimeout(timer) }
  }, [ready, supabase, maker, pressure, unit, key])

  const current = result && result.key === key ? result : null
  return { templates: current?.templates ?? [], loading: ready && !current, asked: ready }
}
