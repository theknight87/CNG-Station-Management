import type { SrvTab } from '@/features/relief-valves/srvDeepLink'

/** Pure helpers for the global SRV search (owner request 2026-10-04). */

export interface SrvHit { tab: SrvTab; id: string; serial: string | null; code: string | null; place: string | null }

/** PostgREST `or()` filters cannot carry these; a serial never needs them. */
export function searchTerm(text: string): string {
  return text.replace(/[,()*%"\\]/g, ' ').trim()
}

/** Exact serial matches first, then by tab order, then serial. */
export function rankHits(hits: SrvHit[], term: string): SrvHit[] {
  const t = term.toLowerCase()
  const order: SrvTab[] = ['installed', 'warehouse', 'log', 'calibration']
  const exact = (h: SrvHit) => (h.serial?.toLowerCase() === t || h.code?.toLowerCase() === t ? 0 : 1)
  return [...hits].sort((a, b) => exact(a) - exact(b) || order.indexOf(a.tab) - order.indexOf(b.tab)
    || (a.serial ?? '').localeCompare(b.serial ?? ''))
}
