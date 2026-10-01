import { beforeEach, describe, expect, it } from 'vitest'

import { loadScopeWorkbook } from '@/features/export/exportScope'

/**
 * Region / Station / Unit workbooks: every family is narrowed by the scope column, archived records and recorded
 * detector ABSENCE are excluded, and raw-table rows get their names from the hierarchy views.
 */

const calls: string[] = []
const DATA: Record<string, unknown[]> = {
  v_station_summary: [{ station_id: 's1', station_name: 'شبرا', region_name: 'Delta' }],
  v_unit_summary: [{ unit_id: 'u1', unit_name: 'شبرا 1', station_id: 's1', station_name: 'شبرا', region_name: 'Delta' }],
  compressors: [{ id: 'c1', station_id: 's1', unit_id: 'u1', serial_number: '9' }],
  v_installed_srv_management: [
    { id: 'i2', region_name: 'Delta', station_name: 'شبرا', unit_name: 'شبرا 1', serial_number: 'B' },
    { id: 'i1', region_name: 'Delta', station_name: 'شبرا', unit_name: 'شبرا 1', serial_number: 'A' },
  ],
}
function builder(table: string) {
  const q: Record<string, unknown> = {}
  for (const m of ['select', 'eq', 'or', 'is', 'not', 'order']) q[m] = (...a: unknown[]) => { calls.push(`${table}.${m}:${a.map(String).join('|')}`); return q }
  q.range = async (from: number) => ({ data: from === 0 ? DATA[table] ?? [] : [], error: null })
  return q
}
const supabase = { from: builder } as never

beforeEach(() => { calls.length = 0 })

describe('scope workbook', () => {
  it('SCOPE-1 a Station workbook: Units first, then every family in physical order, each narrowed by station_id', async () => {
    const sheets = await loadScopeWorkbook(supabase, { kind: 'station', id: 's1', name: 'شبرا' })
    expect(sheets.map((s) => s.name)).toEqual(['Units', 'Compressors', 'Recovery tanks', 'Gas detectors', 'Dispensers', 'Storage vessels', 'Hoses', 'Installed SRVs'])
    for (const t of ['compressors', 'dispensers', 'v_vessel_management', 'v_gas_detector_management', 'v_hose_registry', 'v_installed_srv_management']) {
      expect(calls).toContain(`${t}.eq:station_id|s1`)
    }
    expect(calls).toContain('compressors.is:archived_at|null')
    expect(calls).toContain('dispensers.is:archived_at|null')
    expect(calls).toContain('v_gas_detector_management.not:detector_id|is|null')
    // 2026-09-29: the detector view has no `id`; its row key is detector_id (the Region export failed on `id`).
    expect(calls).toContain('v_gas_detector_management.order:detector_id')
    expect(calls).not.toContain('v_gas_detector_management.order:id')
    expect(calls).toContain('v_vessel_management.eq:asset_type|recovery_tank')
    expect(calls).toContain('v_vessel_management.eq:asset_type|storage_vessel')
  })

  it('SCOPE-2 raw-table rows get Region / Station / Unit names; rows are in hierarchy then serial order', async () => {
    const sheets = await loadScopeWorkbook(supabase, { kind: 'station', id: 's1', name: 'شبرا' })
    expect(sheets.find((s) => s.name === 'Compressors')!.rows[0]).toMatchObject({ region_name: 'Delta', station_name: 'شبرا', unit_name: 'شبرا 1' })
    expect(sheets.find((s) => s.name === 'Installed SRVs')!.rows.map((r) => r.serial_number)).toEqual(['A', 'B'])
  })

  it('SCOPE-3 a Region workbook adds a Stations sheet and narrows by region_id; a Unit workbook by unit_id', async () => {
    const region = await loadScopeWorkbook(supabase, { kind: 'region', id: 'r1', name: 'Delta' })
    expect(region.slice(0, 2).map((s) => s.name)).toEqual(['Stations', 'Units'])
    expect(calls).toContain('v_installed_srv_management.eq:region_id|r1')
    calls.length = 0
    const unit = await loadScopeWorkbook(supabase, { kind: 'unit', id: 'u1', name: 'شبرا 1' })
    expect(unit[0].name).toBe('Unit')
    expect(calls).toContain('v_hose_registry.eq:unit_id|u1')
    expect(calls.some((c) => c.startsWith('v_station_summary'))).toBe(false)
  })

  it('SCOPE-4 ruling 6y: a Unit workbook also carries its Station\'s Station-level storage vessels and storage valves', async () => {
    await loadScopeWorkbook(supabase, { kind: 'unit', id: 'u1', name: 'شبرا 1' })
    expect(calls).toContain('v_vessel_management.or:unit_id.eq.u1,and(unit_id.is.null,station_id.eq.s1)')
    expect(calls).toContain('v_installed_srv_management.or:unit_id.eq.u1,and(unit_id.is.null,station_id.eq.s1,mapping_status.eq.resolved)')
    // Families with no Station-level records stay narrowed by the Unit alone.
    expect(calls).toContain('compressors.eq:unit_id|u1')
    expect(calls).not.toContain('v_installed_srv_management.eq:unit_id|u1')
  })
})
