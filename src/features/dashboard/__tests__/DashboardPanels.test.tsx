import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

import {
  DataQualityPanel,
  DueMatrix,
  RegionOverview,
  SummaryStrip,
  WarehousePanel,
} from '../DashboardPanels'
import type { DueRow, MappingRow, RegionRow } from '../useDashboard'

const at = (ui: React.ReactElement) => render(<MemoryRouter>{ui}</MemoryRouter>)

const regions: RegionRow[] = [
  { region_id: 'r1', region_code: 'east', region_name: 'East', sort_order: 1, stations: 42, units: 61, assets: 900, overdue: 12, approaching_due: 30, unresolved_mapping: 5 },
  { region_id: 'r2', region_code: 'west', region_name: 'West', sort_order: 2, stations: 40, units: 55, assets: 450, overdue: 0, approaching_due: 0, unresolved_mapping: 0 },
]

describe('summary strip', () => {
  it('PANEL-1 renders real counts and links only to routes that exist', () => {
    at(
      <SummaryStrip
        assets={[
          { asset_kind: 'station', total: 157 },
          { asset_kind: 'installed_relief_valve', total: 2662 },
        ]}
        attentionTotal={20}
        overdueTotal={17}
        unresolvedTotal={9}
      />,
    )
    expect(screen.getByText('157')).toBeDefined()
    expect(screen.getByText('2,662')).toBeDefined()
    expect(screen.getByRole('link', { name: /Installed SRVs/ }).getAttribute('href')).toBe('/manage/srvs')
  })

  it('PANEL-2 a zero metric is still shown — zero is an answer, not a gap', () => {
    at(<SummaryStrip assets={[{ asset_kind: 'station', total: 0 }]} attentionTotal={0} overdueTotal={0} unresolvedTotal={0} />)
    expect(screen.getAllByText('0').length).toBeGreaterThan(0)
  })
})

describe('due matrix', () => {
  const due: DueRow[] = [
    { asset_kind: 'installed_relief_valve', due_status: 'overdue', total: 12 },
    { asset_kind: 'installed_relief_valve', due_status: 'due_7', total: 3 },
    { asset_kind: 'installed_relief_valve', due_status: 'unknown', total: 166 },
  ]

  it('MATRIX-1 a row sums its mutually exclusive buckets', () => {
    at(<DueMatrix due={due} />)
    const row = screen.getByRole('row', { name: /Installed SRVs/ })
    // 12 + 3 + 166 = 181, shown as the row total.
    expect(within(row).getByText('181')).toBeDefined()
  })

  it('MATRIX-2 column headings state ranges, never cumulative thresholds', () => {
    at(<DueMatrix due={due} />)
    expect(screen.getByText('8–15 days')).toBeDefined()
    expect(screen.queryByText(/within 15 days/i)).toBeNull()
  })

  it('MATRIX-3 year-only and invalid dates land in "No exact date", never in Current', () => {
    at(<DueMatrix due={due} />)
    const row = screen.getByRole('row', { name: /Installed SRVs/ })
    // The asset-type cell is a rowheader, not a cell, so index 0 is Overdue.
    // Column order follows DUE_BUCKETS: overdue, today, 1-7, 8-15, 16-30,
    // 31-60, current, no-exact-date, then the row total.
    const cells = within(row).getAllByRole('cell')
    expect(cells[0].textContent).toBe('12')  // Overdue
    expect(cells[6].textContent).toBe('0')   // Current — the 166 must NOT land here
    expect(cells[7].textContent).toBe('166') // No exact date
    expect(cells[8].textContent).toBe('181') // Total
  })

  it('MATRIX-4 says so plainly when nothing is visible, rather than showing an empty grid', () => {
    at(<DueMatrix due={[]} />)
    expect(screen.getByText(/No assets with inspection or calibration dates/i)).toBeDefined()
  })
})

describe('region overview', () => {
  it('REGION-1 lists only the regions the query returned', () => {
    at(<RegionOverview regions={regions} />)
    expect(screen.getByText('East')).toBeDefined()
    expect(screen.getByText('West')).toBeDefined()
    // Canal/Alex/Delta/Upper were not returned, so they are absent — an
    // unauthorized region must not appear even as a zero row.
    expect(screen.queryByText('Canal')).toBeNull()
  })

  it('REGION-2 the proportional bar is decoration; the number carries the data', () => {
    const { container } = at(<RegionOverview regions={regions} />)
    const bar = container.querySelector('[aria-hidden="true"][title="900 assets"]')
    expect(bar).not.toBeNull()
    // The same value must be readable as text in the row.
    const row = screen.getByRole('row', { name: /East/ })
    expect(within(row).getByText('900')).toBeDefined()
  })

  it('REGION-3 explains an empty list as a permission fact, not as no data', () => {
    at(<RegionOverview regions={[]} />)
    expect(screen.getByText(/not authorized for any Region/i)).toBeDefined()
  })
})

describe('data quality panel', () => {
  it('DQ-1 surfaces unresolved work with its lifecycle label', () => {
    const mapping: MappingRow[] = [
      { asset_kind: 'installed_relief_valve', mapping_status: 'needs_station_mapping', total: 9 },
      { asset_kind: 'storage_vessel', mapping_status: 'conflict', total: 2 },
    ]
    at(<DataQualityPanel mapping={mapping} />)
    expect(screen.getByText('Needs station mapping')).toBeDefined()
    expect(screen.getByText('9')).toBeDefined()
    expect(screen.getByText('Conflict')).toBeDefined()
  })

  it('DQ-2 NEGATIVE: no Prompt-6 dry-run figure is ever hard-coded', () => {
    const { container } = at(<DataQualityPanel mapping={[]} />)
    const text = container.textContent ?? ''
    for (const dryRunFigure of ['387', '1,599', '1599', '262', '801']) {
      expect(text, `${dryRunFigure} is an import-analysis fact, not production data`).not.toContain(dryRunFigure)
    }
  })

  it('DQ-3 an empty queue reads as "none visible to you", not as an error', () => {
    at(<DataQualityPanel mapping={[]} />)
    expect(screen.getByText(/No unresolved mapping work/i)).toBeDefined()
  })
})

describe('warehouse separation', () => {
  it('WH-1 is labelled as inventory and kept out of station asset counts', () => {
    const { container } = at(<WarehousePanel warehouse={{ total: 2188, overdue: 4, approaching_due: 11 }} />)
    expect(screen.getByRole('heading', { name: /Warehouse inventory/i })).toBeDefined()
    expect(container.textContent).toMatch(/never included in Station or Unit asset counts/i)
    expect(screen.getByText('2,188')).toBeDefined()
  })

  it('WH-2 NEGATIVE: the summary strip has no warehouse metric to confuse with installed assets', () => {
    at(
      <SummaryStrip
        assets={[{ asset_kind: 'installed_relief_valve', total: 10 }]}
        attentionTotal={0}
        overdueTotal={0}
        unresolvedTotal={0}
      />,
    )
    expect(screen.queryByText(/Warehouse/i)).toBeNull()
  })
})

describe('headings are not duplicated', () => {
  it('HEAD-1 each panel labels its section with ONE visible heading', () => {
    // An sr-only h2 beside the visible SectionHeader made every panel announce
    // its name twice. The section now points aria-labelledby at the visible one.
    for (const [ui, name] of [
      [<DueMatrix due={[]} />, /Inspection and calibration/i],
      [<RegionOverview regions={[]} />, /^Regions$/i],
      [<DataQualityPanel mapping={[]} />, /Data quality/i],
      [<WarehousePanel warehouse={{ total: 0, overdue: 0, approaching_due: 0 }} />, /Warehouse inventory/i],
    ] as const) {
      const { unmount } = at(ui)
      expect(screen.getAllByRole('heading', { name }), String(name)).toHaveLength(1)
      unmount()
    }
  })

  it('HEAD-2 every panel section is labelled by its heading', () => {
    const { container } = at(<DueMatrix due={[]} />)
    const section = container.querySelector('section')
    const labelledBy = section?.getAttribute('aria-labelledby')
    expect(labelledBy).toBeTruthy()
    expect(container.querySelector(`#${labelledBy}`)?.tagName).toBe('H2')
  })
})
