import { describe, expect, it } from 'vitest'

import { classifySerialCell, cellToText, looksLikePartNumber, readIdentifier } from '../normalize/identifiers'
import { normalizeDate } from '../normalize/dates'
import { normalizeRegion, CANONICAL_REGIONS } from '../normalize/regions'
import { normalizeName, similarity, splitNumberedName } from '../normalize/text'

describe('identifiers are TEXT, always', () => {
  it('ID-1 renders an int-typed serial as text without numeric formatting', () => {
    expect(cellToText(21586)).toBe('21586')
    expect(classifySerialCell(21586).serialNumber).toBe('21586')
  })

  it('ID-2 keeps a float-typed serial exactly, decimals and all', () => {
    // The gas-detector serial 1803.02075 must not become 1803.02 or 1803.
    expect(classifySerialCell(1803.02075).serialNumber).toBe('1803.02075')
  })

  it('ID-3 NEVER pads a missing leading zero and never strips one that is there', () => {
    expect(classifySerialCell('007123').serialNumber).toBe('007123')
    // A value that lost its zero in Excel stays lost: it is not reconstructed.
    expect(classifySerialCell(7123).serialNumber).toBe('7123')
  })

  it('ID-4 refuses scientific notation instead of silently accepting lost digits', () => {
    const result = classifySerialCell(1.23456789e21)
    expect(result.serialNumber).toBeNull()
    expect(result.raw).toMatch(/e\+?21/i)
  })

  it('ID-5 treats a placeholder as NULL while preserving the literal as raw evidence', () => {
    const dash = classifySerialCell('-')
    expect(dash.serialNumber).toBeNull()
    expect(dash.raw).toBe('-')

    const na = classifySerialCell('N/A')
    expect(na.serialNumber).toBeNull()
    expect(na.raw).toBe('N/A')
  })

  it('ID-6 never treats 0 as a placeholder', () => {
    expect(classifySerialCell(0).serialNumber).toBe('0')
  })

  it('ID-7 missing serial is NULL, not a fabricated placeholder', () => {
    const r = classifySerialCell(null)
    expect(r.serialNumber).toBeNull()
    expect(r.raw).toBeNull()
    expect(r.serialStatus).toBe('unknown')
    expect(JSON.stringify(r)).not.toMatch(/unknown serial|N\/A|TBD|-{2,}/i)
  })

  it('ID-8 a plain identifier column keeps its raw alongside its value', () => {
    expect(readIdentifier(30157)).toEqual({ value: '30157', raw: '30157' })
  })
})

describe('the owner-confirmed SS-4R3A rule, and ONLY that rule', () => {
  it('OWNER-1 SS-4R3A becomes a part number with a NULL serial', () => {
    const r = classifySerialCell('SS-4R3A')
    expect(r.partNumber).toBe('SS-4R3A')
    expect(r.serialNumber).toBeNull()
    expect(r.serialStatus).toBe('not_yet_assigned')
    expect(r.raw).toBe('SS-4R3A')
    expect(r.ownerConfirmedRule).toBe('owner_confirmed_part_number:SS-4R3A')
  })

  it('OWNER-2 NEGATIVE: a similar-looking value is NOT reclassified', () => {
    for (const lookalike of ['SS-4R3B', 'SS-4R3', 'ss-4r3a', 'SS-5R3A', 'AB-1234X', 'SS4R3A']) {
      const r = classifySerialCell(lookalike)
      expect(r.partNumber, `${lookalike} must NOT become a part number`).toBeNull()
      expect(r.serialNumber).toBe(lookalike)
      expect(r.ownerConfirmedRule).toBeUndefined()
    }
  })

  it('OWNER-3 the shape heuristic only FLAGS; it never reclassifies', () => {
    const r = classifySerialCell('AB-1234X')
    expect(looksLikePartNumber('AB-1234X')).toBe(true)
    expect(r.suspectedPartNumber).toBe(true)
    // Flagged, yet still a serial. The flag has no write path.
    expect(r.serialNumber).toBe('AB-1234X')
    expect(r.partNumber).toBeNull()
  })
})

describe('dates carry explicit precision', () => {
  it('DATE-1 a real Excel date is exact', () => {
    const d = normalizeDate(new Date(Date.UTC(2026, 7, 8)))
    expect(d.precision).toBe('exact_date')
    expect(d.value).toBe('2026-08-08')
  })

  it('DATE-2 a text d/m/y date is exact and read day-first', () => {
    const d = normalizeDate('8/3/2026')
    expect(d.precision).toBe('exact_date')
    expect(d.value).toBe('2026-03-08')
  })

  it('DATE-3 NEGATIVE: a year-only value NEVER becomes an exact date', () => {
    for (const input of [2021, '2022']) {
      const d = normalizeDate(input)
      expect(d.precision).toBe('year_only')
      expect(d.value, `${input} must not gain a day`).toBeNull()
      expect(d.year).toBe(Number(input))
      // Specifically: not 1 January, not 31 December, not mid-year.
      expect(JSON.stringify(d)).not.toContain('-01-01')
      expect(JSON.stringify(d)).not.toContain('-12-31')
    }
  })

  it('DATE-4 an empty cell is unknown, not invalid and not a date', () => {
    expect(normalizeDate(null).precision).toBe('unknown')
    expect(normalizeDate('').precision).toBe('unknown')
  })

  it('DATE-5 junk stays invalid and is never repaired', () => {
    for (const junk of ['209/2021', '16/8/3033', '______', 'شهادة المنشأ']) {
      const d = normalizeDate(junk)
      expect(d.precision, junk).toBe('invalid')
      expect(d.value).toBeNull()
      expect(d.raw).toBe(junk)
    }
  })

  it('DATE-6 منتهي / منتهية is preserved as source status text, never as a date', () => {
    for (const word of ['منتهي', 'منتهية']) {
      const d = normalizeDate(word)
      expect(d.precision).toBe('invalid')
      expect(d.value).toBeNull()
      expect(d.sourceStatusRaw).toBe(word)
    }
  })

  it('DATE-7 a rolled-over date such as 31 February is invalid, not 3 March', () => {
    const d = normalizeDate('31/2/2025')
    expect(d.precision).toBe('invalid')
    expect(d.value).toBeNull()
  })
})

describe('regions', () => {
  it('REGION-1 maps every documented alias', () => {
    expect(normalizeRegion('EAST').value).toBe('East')
    expect(normalizeRegion('west').value).toBe('West')
    expect(normalizeRegion('غرب').value).toBe('West')
    expect(normalizeRegion('DELTA').value).toBe('Delta')
    expect(normalizeRegion(' Canal ').value).toBe('Canal')
  })

  it('REGION-2 NEGATIVE: an unknown region creates no seventh Region', () => {
    const r = normalizeRegion('Sinai')
    expect(r.value).toBeNull()
    expect(r.raw).toBe('Sinai')
    expect(CANONICAL_REGIONS).toHaveLength(6)
    expect(CANONICAL_REGIONS).not.toContain('Sinai' as never)
  })
})

describe('text normalization proposes, never resolves', () => {
  it('TEXT-1 folds Arabic orthography for COMPARISON only', () => {
    expect(normalizeName('الماظة')).toBe(normalizeName('الماظه'))
  })

  it('TEXT-2 recognizes <base> <n> without acting on it', () => {
    expect(splitNumberedName('الخمائل 2')).toEqual({ base: 'الخمائل', index: 2 })
    expect(splitNumberedName('الخمائل')).toBeNull()
  })

  it('TEXT-3 similarity is a score, not a decision', () => {
    expect(similarity('شبرا', 'شبرا')).toBe(1)
    expect(similarity('شبرا', 'طنطا')).toBeLessThan(0.6)
  })
})
