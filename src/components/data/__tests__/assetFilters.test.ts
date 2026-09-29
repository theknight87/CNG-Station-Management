import { describe, expect, it } from 'vitest'

import { applyAssetFilters, EMPTY_ASSET_FILTERS, parseRange } from '@/components/data/assetFilters'
import { chipTone, regionDot } from '@/components/data/assetColors'

function builder() {
  const calls: [string, string, unknown][] = []
  const b = {
    ilike(c: string, v: unknown) { calls.push(['ilike', c, v]); return b },
    lte(c: string, v: unknown) { calls.push(['lte', c, v]); return b },
    gte(c: string, v: unknown) { calls.push(['gte', c, v]); return b },
    lt(c: string, v: unknown) { calls.push(['lt', c, v]); return b },
    eq(c: string, v: unknown) { calls.push(['eq', c, v]); return b },
  }
  return { b, calls }
}

describe('registry filters (Vessels, Gas Detectors, Hoses)', () => {
  it('serial, station, manufacturer and a pressure range', () => {
    const { b, calls } = builder()
    applyAssetFilters(b, { ...EMPTY_ASSET_FILTERS, serial: 'A1', station: 'الهرم', maker: 'Safe', pressure: '30-35', pressureUnit: 'BAR' },
      { serial: 'serial_number', station: 'station_name', maker: 'manufacturer', pressure: 'working_pressure_value', pressureUnit: 'working_pressure_unit' })
    expect(calls).toEqual([
      ['ilike', 'serial_number', '%A1%'], ['ilike', 'station_name', '%الهرم%'], ['ilike', 'manufacturer', 'Safe'],
      ['gte', 'working_pressure_value', 30], ['lte', 'working_pressure_value', 35], ['eq', 'working_pressure_unit', 'BAR'],
    ])
  })

  it('a column the dataset lacks is not filtered, and empty filters filter nothing', () => {
    const { b, calls } = builder()
    applyAssetFilters(b, { ...EMPTY_ASSET_FILTERS, pressure: '30' }, { serial: 'serial_number' })
    applyAssetFilters(b, EMPTY_ASSET_FILTERS, { serial: 'serial_number', station: 'station_name' })
    expect(calls).toEqual([])
    expect(parseRange('35-30')).toEqual({ lo: 30, hi: 35 })
    expect(parseRange('abc')).toBeNull()
  })

  it('colours: each region has its own dot; the same maker always gets the same colour, whatever its case', () => {
    const dots = ['East', 'West', 'Delta', 'Canal', 'Alex', 'Upper'].map(regionDot)
    expect(new Set(dots).size).toBe(6)
    expect(chipTone('Safe')).toBe(chipTone('SAFE'))
    expect(chipTone('Technical')).not.toBe(chipTone('EKC'))
    expect(chipTone('Mercer')).not.toBe(chipTone('COI'))
  })
})
