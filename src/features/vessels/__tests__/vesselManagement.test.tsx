import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * Vessels Management.
 *
 * What these defend, hardest first:
 *
 * 1. **A Recovery Tank cannot own an SRV.** `installed_relief_valves` has no
 *    `recovery_tank_id`, no such foreign key, and `srv_parent_kind` does not
 *    include it. The UI must never imply otherwise.
 * 2. **A related SRV comes from the confirmed foreign key**, never from source
 *    text saying "Storage".
 * 3. **The two asset types never bleed together** — every query pins
 *    `asset_type`.
 * 4. **A failed query is never zero**, in the table or in the summary.
 * 5. **Year-only dates never become a countdown** and never read "within date".
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  vessels: { data: [] as unknown[], error: null, count: 0 } as Reply,
  headCount: { data: null, error: null, count: 0 } as Reply,
  relatedSrvs: { data: [] as unknown[], error: null } as Reply,
  regions: { data: [] as unknown[], error: null } as Reply,
}))

const calls = vi.hoisted(() => ({ list: [] as string[] }))

vi.mock('@/lib/supabase/client', () => {
  const client = {
    from(table: string) {
      let head = false
      const chain: Record<string, unknown> = {
        select: (_c?: string, opts?: { head?: boolean }) => {
          head = Boolean(opts?.head)
          return chain
        },
        eq: (col: string, value: string) => {
          calls.list.push(`${table}.eq:${col}=${value}`)
          // Head-only COUNT queries are tagged separately, so a test can tell a
          // summary metric apart from a filter applied to the ROW query.
          if (head) calls.list.push(`${table}.count.eq:${col}=${value}`)
          return chain
        },
        in: (col: string, values: string[]) => {
          calls.list.push(`${table}.in:${col}=[${values.join('|')}]`)
          return chain
        },
        or: (expr: string) => {
          calls.list.push(`${table}.or:${expr}`)
          return chain
        },
        order: (col: string, opts?: { ascending?: boolean }) => {
          calls.list.push(`${table}.order:${col}:${opts?.ascending === false ? 'desc' : 'asc'}`)
          return table === 'v_installed_srv_management' ? Promise.resolve(replies.relatedSrvs) : chain
        },
        range: (a: number, b: number) => {
          calls.list.push(`${table}.range:${a}-${b}`)
          return Promise.resolve(replies.vessels)
        },
        then: (resolve: (v: unknown) => unknown) => {
          const reply =
            table === 'v_dashboard_region_summary' ? replies.regions
            : table === 'v_installed_srv_management' ? replies.relatedSrvs
            : head ? replies.headCount
            : replies.vessels
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
  }
  return { useSupabaseClient: () => client }
})

const { VesselWorkspace } = await import('@/features/vessels/VesselWorkspace')
const { VesselRegistrySection } = await import('@/features/vessels/sections/VesselRegistrySection')

function vessel(over: Record<string, unknown> = {}) {
  return {
    asset_type: 'storage_vessel', id: 'sv-1',
    region_id: 'r-east', region_name: 'East',
    station_id: 's-1', station_name: 'الماظة',
    unit_id: 'u-1', unit_name: 'الماظة 1',
    mapping_status: 'resolved', needs_mapping: false,
    manufacturer: 'CIMC', model: 'CNG-80',
    serial_number: 'SV-00001', serial_number_raw: 'SV-00001', serial_status: 'assigned',
    compressor_type_raw: null,
    last_inspection_date: '2024-03-11', last_inspection_precision: 'exact_date',
    last_inspection_display: '11 Mar 2024',
    next_inspection_date: '2026-10-02', next_inspection_precision: 'exact_date',
    next_inspection_display: '2 Oct 2026',
    days_left: 17, due_status: 'due_30',
    source_status_raw: null, needs_review: false, notes: null,
    serial_missing: false, serial_duplicate: false, serial_duplicate_count: 1,
    ...over,
  }
}

beforeEach(() => {
  calls.list = []
  replies.vessels = { data: [], error: null, count: 0 }
  replies.headCount = { data: null, error: null, count: 0 }
  replies.relatedSrvs = { data: [], error: null }
  replies.regions = { data: [], error: null }
})
afterEach(() => vi.clearAllMocks())

function renderVessels(path = '/manage/vessels/storage') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/manage/vessels" element={<VesselWorkspace />}>
          <Route path="storage" element={<VesselRegistrySection assetType="storage_vessel" />} />
          <Route path="recovery" element={<VesselRegistrySection assetType="recovery_tank" />} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('Workspace and routes', () => {
  it('names both asset types and distinguishes them in words', async () => {
    renderVessels()
    const nav = await screen.findByRole('navigation', { name: /vessel types/i })
    expect(within(nav).getByText('Storage Vessels')).toBeDefined()
    expect(within(nav).getByText('Recovery Tanks')).toBeDefined()
    expect(within(nav).getByText(/no relief-valve relationship/i)).toBeDefined()
  })

  it('marks the active asset type with aria-current', async () => {
    renderVessels('/manage/vessels/recovery')
    const current = await screen.findByRole('link', { current: 'page' })
    expect(current.textContent).toContain('Recovery Tanks')
  })
})

describe('Asset-type isolation', () => {
  it('pins asset_type on the row query', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    expect(calls.list).toContain('v_vessel_management.eq:asset_type=storage_vessel')
    expect(calls.list).not.toContain('v_vessel_management.eq:asset_type=recovery_tank')
  })

  it('pins asset_type on the recovery registry too', async () => {
    replies.vessels = { data: [vessel({ asset_type: 'recovery_tank', id: 'rt-1', serial_number: 'RT-9' })], error: null, count: 1 }
    renderVessels('/manage/vessels/recovery')
    await screen.findByText('RT-9')
    expect(calls.list).toContain('v_vessel_management.eq:asset_type=recovery_tank')
  })

  it('pins asset_type on the unfiltered count used to detect "no match"', async () => {
    replies.vessels = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 400 }
    renderVessels()
    await userEvent.type(screen.getByRole('searchbox', { name: /search storage vessels/i }), 'zzz')
    await screen.findByText(/no results match these filters/i)
    // The fallback count must be scoped to this asset type, or "nothing exists"
    // for Storage could be masked by Recovery Tanks existing.
    expect(calls.list.filter((c) => c === 'v_vessel_management.eq:asset_type=storage_vessel').length).toBeGreaterThan(1)
  })
})

describe('Server-side query', () => {
  it('sends filters to the database', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    await userEvent.selectOptions(screen.getByLabelText(/^mapping$/i), 'needs_unit_mapping')
    await waitFor(() => expect(calls.list).toContain('v_vessel_management.eq:mapping_status=needs_unit_mapping'))
    await userEvent.selectOptions(screen.getByLabelText(/^due$/i), 'overdue')
    await waitFor(() => expect(calls.list).toContain('v_vessel_management.eq:due_status=overdue'))
  })

  it('sorts with the requested column first and a deterministic tie-break', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    calls.list = []
    await userEvent.click(screen.getByRole('button', { name: /^Serial/ }))
    await waitFor(() => {
      const orders = calls.list.filter((c) => c.includes('.order:'))
      expect(orders[0]).toContain('order:serial_number')
      expect(orders[1]).toContain('order:id')
    })
  })

  it('pages with a server range, never by slicing in the browser', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 300 }
    renderVessels()
    await screen.findByText('SV-00001')
    expect(calls.list.some((c) => c.startsWith('v_vessel_management.range:'))).toBe(true)
    expect(screen.getByText(/1–1 of 300/)).toBeDefined()
  })

  it('offers only the mapping states these assets can hold', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    const select = screen.getByLabelText(/^mapping$/i)
    const options = within(select).getAllByRole('option').map((o) => o.textContent ?? '')
    // A vessel IS equipment; there is no equipment parent to resolve.
    expect(options.some((o) => /equipment/i.test(o))).toBe(false)
  })
})

describe('Hierarchy and mapping presentation', () => {
  it('shows the confirmed Station and Unit for a resolved record', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    expect(await screen.findByText('SV-00001')).toBeDefined()
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
    expect(screen.getAllByText('الماظة 1').length).toBeGreaterThan(0)
  })

  it('states an unresolved Unit rather than guessing one', async () => {
    replies.vessels = {
      data: [vessel({ mapping_status: 'needs_unit_mapping', needs_mapping: true, unit_id: null, unit_name: null })],
      error: null, count: 1,
    }
    renderVessels()
    expect(await screen.findByText(/needs unit mapping/i)).toBeDefined()
    expect(screen.getAllByText(/not confirmed/i).length).toBeGreaterThan(0)
    // The Station IS confirmed and is still shown.
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
  })

  it('draws conflict distinctly from needs-mapping', async () => {
    replies.vessels = {
      data: [vessel({ mapping_status: 'conflict', needs_mapping: true })],
      error: null, count: 1,
    }
    renderVessels()
    expect(await screen.findByText('Conflict')).toBeDefined()
    const table = screen.getByRole('table')
    expect(within(table).queryByText(/needs unit mapping/i)).toBeNull()
  })
})

describe('Related SRVs', () => {
  it('lists relief valves for a storage vessel from the confirmed relationship', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    replies.relatedSrvs = {
      data: [{
        id: 'v-1', serial_number: 'RV-880124', serial_status: 'assigned',
        part_number: null, tag_number: 'PSV-101',
        next_calibration_display: '10 Sep 2026', next_calibration_precision: 'exact_date',
        due_status: 'overdue',
      }],
      error: null,
    }
    renderVessels()
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    expect(await screen.findByText(/relief valves on this vessel/i)).toBeDefined()
    expect(screen.getByText('RV-880124')).toBeDefined()
    // The relationship is queried by the confirmed parent, not by source text.
    expect(calls.list).toContain('v_installed_srv_management.eq:parent_kind=storage_vessel')
    expect(calls.list).toContain('v_installed_srv_management.eq:parent_id=sv-1')
  })

  it('states why a "Storage" source text does not count as a relationship', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    replies.relatedSrvs = { data: [], error: null }
    renderVessels()
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    expect(await screen.findByText(/names a kind of parent, not this vessel/i)).toBeDefined()
  })

  it('never claims a relief-valve relationship for a Recovery Tank', async () => {
    replies.vessels = {
      data: [vessel({ asset_type: 'recovery_tank', id: 'rt-1', serial_number: 'RT-9' })],
      error: null, count: 1,
    }
    renderVessels('/manage/vessels/recovery')
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    // No section, and no query was even attempted.
    expect(screen.queryByText(/relief valves on this vessel/i)).toBeNull()
    expect(calls.list.some((c) => c.startsWith('v_installed_srv_management.'))).toBe(false)
  })

  it('reports a failed related-SRV query rather than showing "no valves"', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    replies.relatedSrvs = { data: null, error: { message: 'permission denied' } }
    renderVessels()
    await userEvent.click((await screen.findAllByRole('button', { name: /show the full technical record/i }))[0])
    expect(await screen.findByText(/could not be loaded, so none are listed/i)).toBeDefined()
    expect(screen.queryByText(/no relief valve has this vessel confirmed/i)).toBeNull()
  })
})

describe('Technical values', () => {
  it('never turns a year-only date into a countdown or into "within date"', async () => {
    replies.vessels = {
      data: [vessel({
        next_inspection_date: null, next_inspection_precision: 'year_only',
        next_inspection_display: '2027', days_left: null, due_status: 'unknown',
      })],
      error: null, count: 1,
    }
    renderVessels()
    expect(await screen.findByText('2027')).toBeDefined()
    expect(screen.getByText(/year only/i)).toBeDefined()
    const table = screen.getByRole('table')
    expect(within(table).getByText(/no exact date/i)).toBeDefined()
    expect(within(table).queryByText(/within date/i)).toBeNull()
  })

  it('keeps source status text beside a missing date instead of converting it', async () => {
    replies.vessels = {
      data: [vessel({
        next_inspection_date: null, next_inspection_precision: 'unknown', next_inspection_display: null,
        days_left: null, due_status: 'unknown', source_status_raw: 'منتهية',
      })],
      error: null, count: 1,
    }
    renderVessels()
    expect(await screen.findByText('منتهية')).toBeDefined()
  })

  it('preserves an identifier exactly, including leading zeros', async () => {
    replies.vessels = { data: [vessel({ serial_number: '000420-A', serial_number_raw: '000420-A' })], error: null, count: 1 }
    renderVessels()
    expect(await screen.findByText('000420-A')).toBeDefined()
  })

  it('distinguishes a not-yet-assigned serial from an absent one', async () => {
    replies.vessels = {
      data: [vessel({ serial_number: null, serial_number_raw: null, serial_status: 'not_yet_assigned' })],
      error: null, count: 1,
    }
    renderVessels()
    expect(await screen.findByText(/not yet assigned/i)).toBeDefined()
  })

  it('shows a NULL serial as "not recorded"', async () => {
    replies.vessels = {
      data: [vessel({ serial_number: null, serial_number_raw: null, serial_status: 'unknown' })],
      error: null, count: 1,
    }
    renderVessels()
    expect((await screen.findAllByText(/not recorded/i)).length).toBeGreaterThan(0)
  })

  it('invents no capacity, pressure, manufacture year or certificate column', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    const headers = screen.getAllByRole('columnheader').map((h) => h.textContent?.trim() ?? '')
    for (const absent of ['Capacity', 'Design pressure', 'Working pressure', 'Manufacture year', 'Certificate']) {
      expect(headers).not.toContain(absent)
    }
  })
})

describe('States', () => {
  it('a failed table query is an error, never an empty registry', async () => {
    replies.vessels = { data: null, error: { message: 'permission denied' }, count: 0 }
    renderVessels()
    expect(await screen.findByText(/could not load storage vessels/i)).toBeDefined()
    expect(screen.queryByText(/no storage vessels are currently recorded/i)).toBeNull()
  })

  it('a failed summary count states the failure rather than showing zeros', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    replies.headCount = { data: null, error: { message: 'boom' }, count: 0 }
    renderVessels()
    expect(await screen.findByText(/attention summary could not be loaded/i)).toBeDefined()
  })

  it('reports a genuinely empty registry honestly', async () => {
    replies.vessels = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 0 }
    renderVessels()
    expect(await screen.findByText(/no storage vessels are currently recorded/i)).toBeDefined()
  })
})


/**
 * DUPLICATE SERIAL CANDIDATES (Prompt 24B).
 *
 * The condition is REPORTED. It is never a verdict, never a merge, never a
 * deletion, and never a reason to hide a record (data principle 16).
 */
describe('Duplicate serial candidates', () => {
  const pair = [
    vessel({
      id: 'sv-d1', serial_number: 'SV-DUP-1', serial_number_raw: 'SV-DUP-1',
      serial_duplicate: true, serial_duplicate_count: 2,
    }),
    vessel({
      id: 'sv-d2', serial_number: 'SV-DUP-1', serial_number_raw: 'SV-DUP-1',
      station_name: 'الخمائل', serial_duplicate: true, serial_duplicate_count: 2,
    }),
  ]

  it('asks the server for the duplicate metadata rather than deriving it in the page', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    // The whole point: one comparison, computed under RLS, not a client-side
    // scan of whichever page happens to be loaded.
    expect(calls.list.some((c) => c.startsWith('v_vessel_management.range'))).toBe(true)
  })

  it('flags BOTH members of a candidate group and deduplicates neither', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    renderVessels()
    await screen.findAllByText('SV-DUP-1')
    // Two rows survive. Nothing was collapsed into one.
    expect(screen.getAllByText('SV-DUP-1').length).toBe(2)
    expect(screen.getAllByText('Duplicate serial candidate').length).toBe(2)
  })

  it('says CANDIDATE and never asserts a fault or offers a destructive action', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    const { container } = renderVessels()
    await screen.findAllByText('Duplicate serial candidate')
    const text = container.textContent ?? ''
    expect(/duplicate asset/i.test(text)).toBe(false)
    expect(/invalid/i.test(text)).toBe(false)
    expect(/\berror\b/i.test(text)).toBe(false)
    expect(/delete|merge|remove duplicate/i.test(text)).toBe(false)
  })

  it('explains the condition for a screen reader, in review language', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    const { container } = renderVessels()
    await screen.findAllByText('Duplicate serial candidate')
    const text = container.textContent ?? ''
    expect(text).toContain('2 independent records visible to you record this same serial')
    expect(text).toContain('a human must review')
  })

  it('leaves a unique serial and a blank serial unflagged', async () => {
    replies.vessels = {
      data: [
        vessel({ id: 'sv-u', serial_number: 'SV-UNIQUE' }),
        vessel({
          id: 'sv-b', serial_number: null, serial_number_raw: null,
          serial_status: 'unknown', serial_missing: true,
          serial_duplicate: false, serial_duplicate_count: null,
        }),
      ],
      error: null,
      count: 2,
    }
    renderVessels()
    await screen.findByText('SV-UNIQUE')
    expect(screen.queryByText('Duplicate serial candidate')).toBeNull()
  })

  it('filters server-side, and the filter narrows without hiding half a pair', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    renderVessels()
    await screen.findAllByText('SV-DUP-1')
    calls.list = []
    await userEvent.click(screen.getByRole('checkbox', { name: /duplicate serial candidates only/i }))
    await waitFor(() => {
      const rows = calls.list.filter((c) => c === 'v_vessel_management.eq:serial_duplicate=true')
      const counts = calls.list.filter(
        (c) => c === 'v_vessel_management.count.eq:serial_duplicate=true',
      )
      // One MORE than the summary's own count query: the row query is now narrowed.
      expect(rows.length).toBeGreaterThan(counts.length)
    })
    // Both halves carry the flag, so both remain visible under the filter.
    expect(screen.getAllByText('SV-DUP-1').length).toBe(2)
  })

  it('does not narrow the ROW query unless the filter is asked for', async () => {
    replies.vessels = { data: [vessel()], error: null, count: 1 }
    renderVessels()
    await screen.findByText('SV-00001')
    // The summary COUNTS candidates unconditionally, which is the point of the
    // metric. The row query must not be narrowed by it.
    expect(calls.list).toContain('v_vessel_management.count.eq:serial_duplicate=true')
    const rowFilters = calls.list.filter(
      (c) => c === 'v_vessel_management.eq:serial_duplicate=true',
    )
    const countFilters = calls.list.filter(
      (c) => c === 'v_vessel_management.count.eq:serial_duplicate=true',
    )
    expect(rowFilters.length).toBe(countFilters.length)
  })

  it('counts candidates across the whole authorized dataset, not the page', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    replies.headCount = { data: null, error: null, count: 16 }
    renderVessels()
    await screen.findAllByText('SV-DUP-1')
    expect(calls.list).toContain('v_vessel_management.count.eq:serial_duplicate=true')
    const summary = await screen.findByRole('region', { name: /attention summary/i })
    expect(within(summary).getByText('Duplicate serial')).toBeDefined()
  })

  it('renders an Arabic Station name unchanged beside the badge', async () => {
    replies.vessels = { data: pair, error: null, count: 2 }
    renderVessels()
    await screen.findAllByText('Duplicate serial candidate')
    expect(screen.getByText('الخمائل')).toBeDefined()
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
  })

  it('shows the recorded serial exactly as stored, beside the badge and never instead of it', async () => {
    replies.vessels = { data: [pair[0]], error: null, count: 1 }
    renderVessels()
    const badge = await screen.findByText('Duplicate serial candidate')
    const cell = badge.closest('th, td')
    expect(cell).not.toBeNull()
    expect(cell?.textContent).toContain('SV-DUP-1')
  })
})
