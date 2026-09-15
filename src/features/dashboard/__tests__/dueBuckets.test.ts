import { describe, expect, it } from 'vitest'

import { ATTENTION_STATUSES, DUE_BUCKETS, DUE_ASSET_KINDS, ASSET_LABELS, ASSET_ROUTES } from '../dueBuckets'
import { assetTotal, dueFor, dueTotal, mappingTotal, type DueRow } from '../useDashboard'

describe('due buckets', () => {
  it('DUE-1 covers every status cng_due_status() can return, exactly once', () => {
    const statuses = DUE_BUCKETS.map((b) => b.status)
    expect(statuses).toEqual([
      'overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60', 'valid', 'unknown',
    ])
    expect(new Set(statuses).size).toBe(statuses.length)
  })

  it('DUE-2 labels state RANGES, so a bucket cannot be misread as cumulative', () => {
    const byStatus = Object.fromEntries(DUE_BUCKETS.map((b) => [b.status, b.label]))
    expect(byStatus.due_7).toBe('1–7 days')
    expect(byStatus.due_15).toBe('8–15 days')
    expect(byStatus.due_30).toBe('16–30 days')
    expect(byStatus.due_60).toBe('31–60 days')
    // "within 15 days" would imply it includes the 1-7 bucket. It does not.
    for (const b of DUE_BUCKETS) expect(b.label).not.toMatch(/within/i)
  })

  it('DUE-3 NEGATIVE: "no exact date" is neither current nor overdue', () => {
    const unknown = DUE_BUCKETS.find((b) => b.status === 'unknown')!
    expect(unknown.statusKind).toBe('info')
    expect(unknown.statusKind).not.toBe('ok')
    expect(unknown.statusKind).not.toBe('overdue')
    // It must never count toward "needs attention" either — an unknown date is
    // not evidence of anything.
    expect(unknown.attention).toBe(false)
    expect(ATTENTION_STATUSES).not.toContain('unknown')
  })

  it('DUE-4 attention = overdue plus everything due within 60 days, and nothing else', () => {
    expect([...ATTENTION_STATUSES]).toEqual(['overdue', 'due_today', 'due_7', 'due_15', 'due_30', 'due_60'])
    expect(ATTENTION_STATUSES).not.toContain('valid')
  })

  it('DUE-5 mutually exclusive buckets sum to the asset total, with no double counting', () => {
    // 100 valves spread across every bucket.
    const due: DueRow[] = DUE_BUCKETS.map((b, i) => ({
      asset_kind: 'installed_relief_valve',
      due_status: b.status,
      total: (i + 1) * 3,
    }))
    const rowTotal = DUE_BUCKETS.reduce((s, b) => s + dueFor(due, 'installed_relief_valve', b.status), 0)
    expect(rowTotal).toBe(due.reduce((s, d) => s + d.total, 0))

    // Attention is a strict subset — it must be smaller than the total.
    expect(dueTotal(due, ATTENTION_STATUSES)).toBeLessThan(rowTotal)
  })

  it('DUE-6 warehouse SRVs are not a due-tracked STATION asset kind', () => {
    expect(DUE_ASSET_KINDS).not.toContain('warehouse_relief_valve' as never)
    expect([...DUE_ASSET_KINDS]).toEqual([
      'installed_relief_valve', 'storage_vessel', 'recovery_tank', 'gas_detector', 'hose',
    ])
  })

  it('DUE-7 drill-down targets point only at routes that exist', () => {
    const realRoutes = new Set([
      '/stations', '/manage/srvs', '/manage/vessels', '/manage/gas-detectors', '/manage/hoses', '/alerts', '/admin',
    ])
    for (const [kind, route] of Object.entries(ASSET_ROUTES)) {
      if (route === undefined) continue
      expect(realRoutes, `${kind} links to a route that must exist`).toContain(route)
    }
    // Compressors and dispensers have no module yet: no dead link is created.
    expect(ASSET_ROUTES.compressor).toBeUndefined()
    expect(ASSET_ROUTES.dispenser).toBeUndefined()
  })

  it('DUE-8 installed and warehouse SRVs are labelled distinguishably', () => {
    expect(ASSET_LABELS.installed_relief_valve).toBe('Installed SRVs')
    expect(ASSET_LABELS.warehouse_relief_valve).toBe('Warehouse SRVs')
    expect(ASSET_LABELS.installed_relief_valve).not.toBe(ASSET_LABELS.warehouse_relief_valve)
  })
})

describe('summary arithmetic', () => {
  const due: DueRow[] = [
    { asset_kind: 'installed_relief_valve', due_status: 'overdue', total: 12 },
    { asset_kind: 'installed_relief_valve', due_status: 'due_7', total: 3 },
    { asset_kind: 'storage_vessel', due_status: 'overdue', total: 5 },
    { asset_kind: 'hose', due_status: 'unknown', total: 40 },
    { asset_kind: 'hose', due_status: 'valid', total: 7 },
  ]

  it('SUM-1 overdue totals across every asset kind', () => {
    expect(dueTotal(due, ['overdue'])).toBe(17)
  })

  it('SUM-2 attention excludes valid AND unknown', () => {
    // 12 + 3 + 5 = 20. The 40 unknown hoses and 7 current ones are excluded.
    expect(dueTotal(due, ATTENTION_STATUSES)).toBe(20)
  })

  it('SUM-3 a missing bucket reads as 0, because the query returned no such row', () => {
    expect(dueFor(due, 'gas_detector', 'overdue')).toBe(0)
    expect(assetTotal([], 'station')).toBe(0)
    expect(mappingTotal([])).toBe(0)
  })

  it('SUM-4 mapping totals sum across asset kinds and statuses', () => {
    expect(
      mappingTotal([
        { asset_kind: 'installed_relief_valve', mapping_status: 'needs_station_mapping', total: 9 },
        { asset_kind: 'storage_vessel', mapping_status: 'needs_unit_mapping', total: 4 },
      ]),
    ).toBe(13)
  })
})
