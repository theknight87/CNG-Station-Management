import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import { describe, expect, it } from 'vitest'

import { applyDateRange, EMPTY_DATE_RANGE, hasDateRange, inDateRange, presetRange, rangeText, type DateOption } from '@/components/data/dateRange'
import { applyAssetFilters, EMPTY_ASSET_FILTERS, hasAssetFilters } from '@/components/data/assetFilters'
import { regionTone } from '@/components/data/assetColors'
import { RegionChip } from '@/components/data/AssetChips'
import { SectionTabs } from '@/components/layout/SectionTabs'

function builder() {
  const calls: [string, string, unknown][] = []
  const b = {
    ilike(c: string, v: unknown) { calls.push(['ilike', c, v]); return b },
    lte(c: string, v: unknown) { calls.push(['lte', c, v]); return b },
    gte(c: string, v: unknown) { calls.push(['gte', c, v]); return b },
    lt(c: string, v: unknown) { calls.push(['lt', c, v]); return b },
    eq(c: string, v: unknown) { calls.push(['eq', c, v]); return b },
    in(c: string, v: unknown) { calls.push(['in', c, v]); return b },
    or(e: string) { calls.push(['or', e, null]); return b },
  }
  return { b, calls }
}

const NEXT: DateOption = { column: 'next_calibration_date', label: 'Next calibration', precision: 'next_calibration_precision' }
const LAST: DateOption = { column: 'last_calibration_date', label: 'Last calibration', precision: 'last_calibration_precision' }
const SENT: DateOption = { column: 'sent_at', label: 'Sent' }

describe('date filter (owner request 2026-09-29)', () => {
  it('DATE-1 From and To are inclusive days; the upper bound is "before the next day"', () => {
    const { b, calls } = builder()
    applyDateRange(b, { dateFrom: '2026-09-01', dateTo: '2026-12-31' }, NEXT)
    expect(calls).toEqual([
      ['gte', 'next_calibration_date', '2026-09-01'],
      ['lt', 'next_calibration_date', '2027-01-01'],
      // Principle #17: a year-only or unknown date is never a calendar day, so it is never matched.
      ['eq', 'next_calibration_precision', 'exact_date'],
    ])
  })

  it('DATE-2 the tab\'s own date is used; one end alone works; a reversed range reads the right way round', () => {
    const { b, calls } = builder()
    applyDateRange(b, { dateFrom: '', dateTo: '2025-02-28' }, LAST)
    applyDateRange(b, { dateFrom: '2026-09-30', dateTo: '2026-09-01' }, SENT)
    expect(calls).toEqual([
      ['lt', 'last_calibration_date', '2025-03-01'], ['eq', 'last_calibration_precision', 'exact_date'],
      ['gte', 'sent_at', '2026-09-01'], ['lt', 'sent_at', '2026-10-01'],
    ])
  })

  it('DATE-3 no dates, no filter; a malformed value is ignored', () => {
    const { b, calls } = builder()
    applyDateRange(b, EMPTY_DATE_RANGE, NEXT)
    applyDateRange(b, { dateFrom: '2026-9-1', dateTo: '' }, NEXT)
    expect(calls).toEqual([])
    expect(hasDateRange(EMPTY_DATE_RANGE)).toBe(false)
  })

  it('DATE-4 the registry filters carry the date range and report it as a filter', () => {
    const { b, calls } = builder()
    const f = { ...EMPTY_ASSET_FILTERS, dateFrom: '2026-10-01' }
    applyAssetFilters(b, f, { serial: 'serial_number', date: { column: 'next_test_date', label: 'Next test', precision: 'next_test_precision' } })
    expect(calls).toEqual([['gte', 'next_test_date', '2026-10-01'], ['eq', 'next_test_precision', 'exact_date']])
    expect(hasAssetFilters(f)).toBe(true)
  })

  it('DATE-5 quick ranges count from the given day', () => {
    expect(presetRange('next30', '2026-09-29')).toEqual({ dateFrom: '2026-09-29', dateTo: '2026-10-29' })
    expect(presetRange('past', '2026-09-29')).toEqual({ dateFrom: '', dateTo: '2026-09-28' })
    expect(presetRange('thisMonth', '2026-02-10')).toEqual({ dateFrom: '2026-02-01', dateTo: '2026-02-28' })
    expect(presetRange('thisMonth', '2026-12-10')).toEqual({ dateFrom: '2026-12-01', dateTo: '2026-12-31' })
    expect(presetRange('thisYear', '2026-09-29')).toEqual({ dateFrom: '2026-01-01', dateTo: '2026-12-31' })
  })

  it('DATE-7 the picker button reads the range in words', () => {
    expect(rangeText(EMPTY_DATE_RANGE)).toBe('Any date')
    expect(rangeText({ dateFrom: '2026-09-01', dateTo: '2026-09-30' })).toBe('1 Sept 2026 – 30 Sept 2026'.replace(/Sept/g, new Date(Date.UTC(2026, 8, 1)).toLocaleDateString('en-GB', { month: 'short', timeZone: 'UTC' })))
    expect(rangeText({ dateFrom: '', dateTo: '2026-01-05' })).toMatch(/^Until 5 Jan 2026$/)
  })

  it('DATE-6 the in-memory test agrees, and a timestamp counts on its own day', () => {
    const opts = SENT
    const f = { dateFrom: '2026-09-01', dateTo: '2026-09-30' }
    expect(inDateRange({ sent_at: '2026-09-30T21:00:00+00:00' }, f, opts)).toBe(true)
    expect(inDateRange({ sent_at: '2026-10-01T00:00:00+00:00' }, f, opts)).toBe(false)
    expect(inDateRange({ sent_at: null }, f, opts)).toBe(false)
    expect(inDateRange({ next_calibration_date: '2026-09-10', next_calibration_precision: 'year_only' }, f, NEXT)).toBe(false)
  })
})

describe('Region colours (owner request 2026-09-29)', () => {
  it('REGION-1 each of the six Regions has its own colour, in every form, whatever the case', () => {
    const names = ['East', 'West', 'Canal', 'Delta', 'Alex', 'Upper']
    for (const form of ['dot', 'chip', 'stripe'] as const) {
      expect(new Set(names.map((n) => regionTone(n)[form])).size).toBe(6)
    }
    expect(regionTone('EAST ')).toEqual(regionTone('east'))
    // Kept apart from the due-status reds and ambers and from the brand/"ok" green.
    for (const n of names) expect(regionTone(n).dot).not.toMatch(/red|amber|orange|yellow|green|emerald|lime/)
  })

  it('REGION-2 the chip always writes the name, so colour is never the only signal', () => {
    render(<RegionChip name="Delta" />)
    expect(screen.getByText('Delta').className).toContain(regionTone('Delta').chip.split(' ')[0])
  })
})

describe('Section tabs', () => {
  it('TABS-1 routes as links; the current one carries aria-current and shows its count', () => {
    render(
      <MemoryRouter initialEntries={['/x/b']}>
        <SectionTabs label="Sections" tabs={[{ to: '/x/a', label: 'Alpha', hint: 'first' }, { to: '/x/b', label: 'Beta', count: 3 }]} />
      </MemoryRouter>,
    )
    const current = screen.getByRole('link', { current: 'page' })
    expect(current.textContent).toContain('Beta')
    expect(current.textContent).toContain('3')
    expect(screen.getByRole('link', { name: /alpha/i }).getAttribute('aria-current')).toBeNull()
  })
})
