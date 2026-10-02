import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

import {
  DueMatrix,
  ManufacturerPanel,
  RegionOverview,
  SummaryStrip,
  TopStationsPanel,
  WarehousePanel,
} from '../DashboardPanels'
import type { DueRow, RegionRow } from '../useDashboard'

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
    // Index 1 is the phone-only "Due ≤30d" column (CSS-hidden from 640px up);
    // then DUE_BUCKETS order: today, 1-7, 8-15, 16-30, 31-60, current,
    // no-exact-date, then the row total.
    const cells = within(row).getAllByRole('cell')
    expect(cells[0].textContent).toBe('12')  // Overdue
    expect(cells[7].textContent).toBe('0')   // Current — the 166 must NOT land here
    expect(cells[8].textContent).toBe('166') // No exact date
    expect(cells[9].textContent).toBe('181') // Total
  })

  it('MATRIX-5 the phone "Due ≤30d" column is the exact sum of the four dated windows out to 30 days', () => {
    at(<DueMatrix due={[...due, { asset_kind: 'installed_relief_valve', due_status: 'due_60', total: 5 }]} />)
    const row = screen.getByRole('row', { name: /Installed SRVs/ })
    const cells = within(row).getAllByRole('cell')
    const windows = cells.slice(2, 6).reduce((sum, c) => sum + Number(c.textContent), 0)
    expect(Number(cells[1].textContent)).toBe(windows)
    expect(cells[1].textContent).toBe('3') // the 5 due in 31–60 days are NOT folded into ≤30d
    expect(cells[6].textContent).toBe('5')
    // Phone row: Overdue + Due ≤30d + 31–60 days + Current + No exact date = Total.
    expect(Number(cells[0].textContent) + windows + Number(cells[6].textContent) + Number(cells[7].textContent)
      + Number(cells[8].textContent)).toBe(Number(cells[9].textContent))
    // It is shown only below 640px, the ≤30-day windows only from 640px up; 31–60 days is never folded in.
    expect(cells[1].className).toContain('sm:hidden')
    expect(cells[2].className).toContain('hidden sm:table-cell')
    expect(cells[6].className).not.toContain('hidden')
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

describe('insights (owner request 2026-10-02: replace the Data quality strip)', () => {
  it('INS-1 lists Stations worst first, each linking to its Station, with overdue, due-soon and total', () => {
    at(<TopStationsPanel stations={[
      { station_id: 's1', station_name: 'شبرا', region_name: 'East', overdue: 16, approaching_due: 4, assets: 40 },
      { station_id: 's2', station_name: 'الكابتن', region_name: 'Delta', overdue: 12, approaching_due: 0, assets: 20 },
    ]} />)
    const link = screen.getByRole('link', { name: 'شبرا' })
    expect(link.getAttribute('href')).toBe('/stations/s1')
    const rows = screen.getAllByRole('row').slice(1)
    expect(rows[0].textContent).toContain('16')
    expect(rows[0].textContent).toContain('40')
    expect(rows[1].textContent).toContain('الكابتن')
  })

  it('INS-2 an empty Station list says no visible Station is overdue, not an error', () => {
    at(<TopStationsPanel stations={[]} />)
    expect(screen.getByText(/No Station visible to you has an overdue asset/i)).toBeDefined()
  })

  it('INS-3 shows each manufacturer with its overdue share, computed from the counts', () => {
    at(<ManufacturerPanel manufacturers={[
      { manufacturer: 'EKC', total: 264, overdue: 146, approaching_due: 3 },
      { manufacturer: 'COI', total: 346, overdue: 13, approaching_due: 0 },
    ]} />)
    expect(screen.getByText('EKC')).toBeDefined()
    expect(screen.getByText('55%')).toBeDefined()
    expect(screen.getByText('4%')).toBeDefined()
    expect(screen.getByRole('link', { name: /open installed srvs/i }).getAttribute('href')).toBe('/manage/srvs/installed')
  })

  it('INS-4 NEGATIVE: no Data quality strip remains on the dashboard panels', () => {
    const { container } = at(<ManufacturerPanel manufacturers={[]} />)
    expect(container.textContent).not.toMatch(/Data quality/i)
    expect(screen.getByText(/No installed relief valve visible to you/i)).toBeDefined()
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
      [<TopStationsPanel stations={[]} />, /Stations with the most overdue assets/i],
      [<ManufacturerPanel manufacturers={[]} />, /Installed SRVs by manufacturer/i],
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
