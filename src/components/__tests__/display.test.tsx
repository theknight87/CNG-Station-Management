import { describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'

import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { EntityName, Identifier } from '@/components/data/TechnicalText'
import { DateValue } from '@/components/data/DateValue'
import { drivesAlerts } from '@/components/data/dateSemantics'
import { StatusBadge } from '@/components/data/StatusBadge'
import { mappingStatusKind, mappingStatusLabel } from '@/components/data/statusSemantics'

describe('NULL presentation (CLAUDE.md §11.5)', () => {
  it('NULLUI-1 NEGATIVE: never renders N/A, Unknown, a dash-as-data, or 0', () => {
    const { container } = render(<ValueOrNull value={null} />)
    const text = container.textContent ?? ''
    expect(text).not.toMatch(/N\/A/i)
    expect(text).not.toMatch(/\bunknown\b/i)
    expect(text).not.toBe('0')
    // The visible glyph is an em dash, marked aria-hidden, with real words for
    // assistive technology — not a hyphen masquerading as a value.
    expect(text).not.toContain('-')
  })

  it('NULLUI-2 gives assistive technology real words, not silence', () => {
    const { container } = render(<NullValue />)
    // The em dash is hidden from assistive technology; the words are not.
    expect(container.querySelector('[aria-hidden="true"]')?.textContent).toBe('—')
    expect(container.querySelector('.sr-only')?.textContent).toBe('not recorded')
    expect(screen.getAllByText('not recorded').length).toBeGreaterThan(0)
  })

  it('NULLUI-3 an empty string is absence, not a value', () => {
    const { container } = render(<ValueOrNull value="   " />)
    expect(container.textContent).toContain('not recorded')
  })

  it('NULLUI-4 a real 0 is a VALUE and is rendered', () => {
    // Principle: 0 is never a placeholder. A zero reading is data.
    const { container } = render(<ValueOrNull value={0} />)
    expect(container.textContent).toBe('0')
  })
})

describe('Arabic and mixed-direction values (prompt §18)', () => {
  it('DIR-1 an Arabic entity name gets dir="auto" and bidi isolation', () => {
    const { container } = render(<EntityName name="الماظة 1" />)
    const span = container.querySelector('span')
    expect(span?.getAttribute('dir')).toBe('auto')
    expect(span?.className).toContain('unicode-bidi:isolate')
    expect(span?.textContent).toBe('الماظة 1')
  })

  it('DIR-2 a Latin name uses the same component without special-casing', () => {
    const { container } = render(<EntityName name="Shobra 1" />)
    expect(container.querySelector('span')?.getAttribute('dir')).toBe('auto')
  })

  it('DIR-3 an identifier is forced LTR, monospaced, and never truncated', () => {
    const { container } = render(<Identifier value="EKC/DXB/MGNC/275/DN-25-VM/309" />)
    const span = container.querySelector('span')
    expect(span?.getAttribute('dir')).toBe('ltr')
    expect(span?.className).toContain('font-technical')
    // It is never ellipsed — half a serial is worse than a wide column. Inside
    // a table the cell is nowrap, so a long identifier widens the column and
    // the scroll region handles it (browser-verified at 1024px and 390px).
    expect(span?.className).not.toContain('truncate')
    expect(span?.className).not.toContain('break-all')
  })

  it('DIR-4 a missing name falls back to the null marker, not an empty box', () => {
    const { container } = render(<EntityName name={null} />)
    expect(container.textContent).toContain('not recorded')
  })
})

describe('date precision (principle #17)', () => {
  it('DATEUI-1 an exact date renders as a machine-readable time', () => {
    const { container } = render(
      <DateValue date={{ value: '2026-08-08', precision: 'exact_date', raw: '8/8/2026', year: 2026 }} />,
    )
    expect(container.querySelector('time')?.getAttribute('datetime')).toBe('2026-08-08')
  })

  it('DATEUI-2 NEGATIVE: a year-only value NEVER renders as a calendar date', () => {
    const { container } = render(
      <DateValue date={{ value: null, precision: 'year_only', raw: '2021', year: 2021 }} />,
    )
    const text = container.textContent ?? ''
    expect(text).toContain('2021')
    expect(text).toContain('year only')
    expect(text).not.toContain('2021-01-01')
    expect(text).not.toContain('2021-12-31')
    expect(container.querySelector('time')).toBeNull()
  })

  it('DATEUI-3 invalid keeps the source status text beside a missing date', () => {
    const { container } = render(
      <DateValue
        date={{ value: null, precision: 'invalid', raw: 'منتهية', year: null, sourceStatusRaw: 'منتهية' }}
      />,
    )
    // The source word is kept verbatim, beside an explicitly absent date.
    expect(container.textContent).toContain('منتهية')
    expect(container.querySelector('.sr-only')?.textContent).toBe('no valid date in the source')
    // And it never became a date or a computed compliance status.
    expect(container.querySelector('time')).toBeNull()
    expect(container.textContent).not.toMatch(/expired|overdue/i)
  })

  it('DATEUI-4 only an exact date may drive an alert', () => {
    expect(drivesAlerts({ value: '2026-08-08', precision: 'exact_date', raw: null, year: 2026 })).toBe(true)
    expect(drivesAlerts({ value: null, precision: 'year_only', raw: '2021', year: 2021 })).toBe(false)
    expect(drivesAlerts({ value: null, precision: 'invalid', raw: 'x', year: null })).toBe(false)
    expect(drivesAlerts(null)).toBe(false)
  })
})

describe('status semantics (prompt §15)', () => {
  it('STATUSUI-1 a status is never colour alone: icon plus word plus description', () => {
    const { container } = render(<StatusBadge kind="overdue" />)
    expect(container.querySelector('svg')).not.toBeNull()
    expect(container.textContent).toContain('Overdue')
    expect(container.textContent).toContain('past its due date')
  })

  it('STATUSUI-2 an unresolved mapping is NOT presented as an error', () => {
    const { container } = render(<StatusBadge kind="unmapped" />)
    expect(container.textContent).toContain('Needs mapping')
    // It must not borrow the destructive/overdue treatment: a missing mapping
    // is missing evidence, not a faulty asset (principle #19).
    expect(container.querySelector('span')?.className).not.toContain('overdue')
    expect(container.querySelector('span')?.className).not.toContain('destructive')
  })

  it('STATUSUI-3 the mapping lifecycle maps onto the vocabulary exactly', () => {
    expect(mappingStatusKind('resolved')).toBe('ok')
    expect(mappingStatusKind('conflict')).toBe('conflict')
    expect(mappingStatusKind('needs_station_mapping')).toBe('unmapped')
    expect(mappingStatusKind('needs_unit_mapping')).toBe('unmapped')
    expect(mappingStatusKind('needs_equipment_mapping')).toBe('unmapped')

    expect(mappingStatusLabel('needs_station_mapping')).toBe('Needs station mapping')
    expect(mappingStatusLabel('needs_equipment_mapping')).toBe('Needs equipment mapping')
  })
})
