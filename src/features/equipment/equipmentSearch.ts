import { KINDS, type EquipmentKind } from './equipmentKinds'

/** Pure helpers for the Hoses / Gas Detectors global search (owner request 2026-10-10; see EquipmentGlobalSearch). */

export type EquipmentTab = 'installed' | 'warehouse' | 'log' | 'jobs'
export interface EquipmentHit { tab: EquipmentTab; id: string; serial: string | null; code: string | null; place: string | null }

/** `?q=<serial>&open=<id>` on the tab's route; read by the tab when it starts (the workspace remounts it per link). */
export function equipmentLink(kind: EquipmentKind, tab: EquipmentTab, q: string, open: string): string {
  const spec = KINDS[kind]
  return `${spec.base}/${tab === 'jobs' ? spec.jobPath : tab}?${new URLSearchParams({ q, open }).toString()}`
}

const ORDER: EquipmentTab[] = ['installed', 'warehouse', 'log', 'jobs']
/** Exact serial / code matches first, then by tab order, then serial. */
export function rankEquipmentHits(hits: EquipmentHit[], term: string): EquipmentHit[] {
  const t = term.toLowerCase()
  const exact = (h: EquipmentHit) => (h.serial?.toLowerCase() === t || h.code?.toLowerCase() === t ? 0 : 1)
  return [...hits].sort((a, b) => exact(a) - exact(b) || ORDER.indexOf(a.tab) - ORDER.indexOf(b.tab)
    || (a.serial ?? '').localeCompare(b.serial ?? ''))
}
