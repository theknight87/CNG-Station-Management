import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { ExportButtons } from '@/features/export/ExportButtons'
import type { ExportSheet } from '@/features/export/exportData'

const downloads = vi.hoisted(() => [] as Array<{ name: string; type: string; text?: string }>)
vi.mock('@/features/export/exportData', async (orig) => {
  const real = await orig<typeof import('@/features/export/exportData')>()
  return {
    ...real,
    toXlsx: async () => new Blob(['xlsx'], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }),
    downloadBlob: (name: string, blob: Blob) => { downloads.push({ name, type: blob.type }) },
  }
})

const sheet = (rows: number, truncated = false): ExportSheet => ({
  name: 'Installed SRVs', columns: [{ header: 'Serial', value: (r) => r.serial_number }],
  rows: Array.from({ length: rows }, (_, i) => ({ serial_number: `S-${i}` })), truncated,
})

beforeEach(() => { downloads.length = 0 })

describe('export buttons', () => {
  it('EXPUI-1 Excel and CSV each re-run the load and download a dated file, then state the row count', async () => {
    const load = vi.fn(async () => [sheet(3)])
    render(<ExportButtons name="installed-srvs" load={load} />)
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /to excel/i }))
    expect(await screen.findByRole('status')).toHaveProperty('textContent', 'Exported 3 rows.')
    await user.click(screen.getByRole('button', { name: /to csv/i }))
    expect(load).toHaveBeenCalledTimes(2)
    expect(downloads.map((d) => d.name)).toEqual([
      expect.stringMatching(/^cng-installed-srvs-\d{4}-\d{2}-\d{2}\.xlsx$/), expect.stringMatching(/^cng-installed-srvs-\d{4}-\d{2}-\d{2}\.csv$/),
    ])
  })

  it('EXPUI-2 a file cut at the ceiling says so; a failure says nothing was downloaded', async () => {
    const user = userEvent.setup()
    const { unmount } = render(<ExportButtons name="x" load={async () => [sheet(2, true)]} />)
    await user.click(screen.getByRole('button', { name: /to excel/i }))
    expect((await screen.findByRole('status')).textContent).toMatch(/stopped at 10,000 rows.*not the whole list/)
    unmount()
    render(<ExportButtons name="x" load={async () => { throw new Error('permission denied') }} />)
    await user.click(screen.getByRole('button', { name: /to excel/i }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/permission denied.*Nothing was downloaded/)
    expect(downloads).toHaveLength(1)
  })

  it('EXPUI-3 a multi-sheet workbook offers Excel only', () => {
    render(<ExportButtons name="station" label="Export Station" csv={false} load={async () => [sheet(1), sheet(1)]} />)
    expect(screen.getByRole('button', { name: 'Export Station to Excel' })).toBeDefined()
    expect(screen.queryByRole('button', { name: /csv/i })).toBeNull()
  })

  it('EXPUI-4 a custom Excel builder (the calibration request form) replaces the plain table and names the file', async () => {
    const excel = vi.fn(async (sheets: ExportSheet[]) => ({ blob: new Blob([String(sheets[0].rows.length)]), fileName: 'cng-calibration-request-2026-06-04.xlsx' }))
    render(<ExportButtons name="srv-calibration" label="Export 2 selected" load={async () => [sheet(2)]} excel={excel} />)
    await userEvent.setup().click(screen.getByRole('button', { name: 'Export 2 selected to Excel' }))
    expect(excel).toHaveBeenCalledTimes(1)
    expect(excel.mock.calls[0][0][0].rows).toHaveLength(2)
    expect(downloads.map((d) => d.name)).toEqual(['cng-calibration-request-2026-06-04.xlsx'])
  })
})
