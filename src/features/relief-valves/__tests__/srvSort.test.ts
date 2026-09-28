import { describe, expect, it } from 'vitest'

import { byValues, pressureBar } from '@/features/relief-valves/srvSort'

describe('SRV table ordering (owner request 2026-09-28)', () => {
  it('puts BAR and PSI on one scale: 400 PSI sorts before 90 BAR', () => {
    const rows = [
      { id: 'a', pressure_max: 90, pressure_unit: 'BAR' },
      { id: 'b', pressure_max: 400, pressure_unit: 'PSI' },
      { id: 'c', pressure_max: 5, pressure_unit: null },
    ]
    expect([...rows].sort(byValues(pressureBar)).map((r) => r.id)).toEqual(['b', 'a', 'c'])
  })

  it('orders Region, then Station, then pressure, with missing values last', () => {
    const rows = [
      { id: '1', r: 'West', s: 'A', pressure_max: 10, pressure_unit: 'BAR' },
      { id: '2', r: 'East', s: 'B', pressure_max: 5, pressure_unit: 'BAR' },
      { id: '3', r: 'East', s: 'A', pressure_max: 20, pressure_unit: 'BAR' },
      { id: '4', r: 'East', s: 'A', pressure_max: 3, pressure_unit: 'BAR' },
      { id: '5', r: null, s: 'A', pressure_max: 1, pressure_unit: 'BAR' },
    ]
    const order = byValues<(typeof rows)[number]>((x) => x.r, (x) => x.s, pressureBar)
    expect([...rows].sort(order).map((x) => x.id)).toEqual(['4', '3', '2', '1', '5'])
  })
})
