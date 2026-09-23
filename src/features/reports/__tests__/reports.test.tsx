import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

/**
 * The Reports workspace.
 *
 * Authorization itself is asserted in SQL against a real PostgreSQL — a mocked
 * client can be made to return anything, so proving RLS here would prove
 * nothing. What these defend is what only the frontend can get wrong:
 *
 * 1. **The export runs the same authorized query as the table.** An export that
 *    reached a different view, or dropped a filter, would hand someone rows the
 *    screen would not show them.
 * 2. **Ordering is deterministic**, so paging cannot duplicate or skip a row.
 * 3. **Filters are dependent**, so a Station outside the chosen Region is not
 *    expressible.
 * 4. **Reports mutate nothing** — no RPC, no write, no acknowledgement.
 * 5. **Empty is a result**, and the two kinds of empty are told apart.
 * 6. **Installed and warehouse SRVs are never one list or one total.**
 */

/**
 * jsdom implements neither `URL.createObjectURL` nor anchor-triggered
 * downloads, so the export path is stubbed at that boundary. The stub captures
 * the bytes, which turns a missing browser API into a stronger assertion: the
 * tests below check the FILE that would have been downloaded, not merely that
 * the button was clicked.
 */
const downloads = vi.hoisted(() => ({ files: [] as { name: string; text: string }[] }))

const db = vi.hoisted(() => ({
  rows: {} as Record<string, Record<string, unknown>[]>,
  counts: {} as Record<string, number>,
  role: 'engineer' as string,
  status: 'active' as string,
  queries: [] as { table: string; ops: string[]; head: boolean }[],
  rpcCalls: [] as string[],
  writes: [] as { table: string; op: string }[],
}))

const client = vi.hoisted(() => ({ value: null as unknown }))

vi.mock('@/lib/supabase/client', () => {
  client.value = {
    from: (table: string) => {
      const trace = { table, ops: [] as string[], head: false }
      db.queries.push(trace)
      const payload = () => ({
        data: db.rows[table] ?? [],
        error: null,
        count: db.counts[table] ?? (db.rows[table] ?? []).length,
      })
      const chain: Record<string, unknown> = {
        then: (...args: unknown[]) =>
          (Promise.resolve(payload()).then as (...a: unknown[]) => unknown).apply(
            Promise.resolve(payload()), args,
          ),
        range: (a: number, b: number) => {
          trace.ops.push(`range:${a}-${b}`)
          const all = db.rows[table] ?? []
          return Promise.resolve({
            data: all.slice(a, b + 1), error: null,
            count: db.counts[table] ?? all.length,
          })
        },
        insert: () => { db.writes.push({ table, op: 'insert' }); return Promise.resolve({ error: null }) },
        update: () => { db.writes.push({ table, op: 'update' }); return { eq: () => Promise.resolve({ error: null }) } },
        delete: () => { db.writes.push({ table, op: 'delete' }); return { eq: () => Promise.resolve({ error: null }) } },
      }
      chain.select = (cols: string, opts?: { head?: boolean; count?: string }) => {
        trace.ops.push(`select:${cols}`)
        if (opts?.head) trace.head = true
        return chain
      }
      for (const method of ['eq', 'gte', 'lte', 'or', 'ilike']) {
        chain[method] = (...args: unknown[]) => {
          trace.ops.push(`${method}:${String(args[0] ?? '')}=${String(args[1] ?? '')}`)
          return chain
        }
      }
      chain.order = (col: string, opts?: { ascending?: boolean }) => {
        trace.ops.push(`order:${col}:${opts?.ascending ? 'asc' : 'desc'}`)
        return chain
      }
      return chain
    },
    rpc: (fn: string) => {
      db.rpcCalls.push(fn)
      return Promise.resolve({ data: null, error: null })
    },
  }
  return { useSupabaseClient: () => client.value }
})

vi.mock('@/hooks/useAppUser', () => ({
  useAppUser: () => (db.status === 'active'
    ? { status: 'active', user: { id: 'me', clerk_user_id: 'c', role: db.role, is_active: true, full_name: 'Me' } }
    : { status: db.status }),
}))

const { ReportsView } = await import('@/features/reports/ReportsView')
const { ReportWorkspace } = await import('@/features/reports/ReportWorkspace')
const { reportSpec, selectColumnsFor, csvColumnsFor, REPORT_SPECS } = await import('@/features/reports/reportSpecs')
const {
  DataQualityReportSection, SrvReportSection, ActivityReportSection,
} = await import('@/features/reports/sections/ReportSections')

const DUE_ROW = {
  asset_id: 'a1', asset_type: 'installed_relief_valve',
  region_id: 'r1', region_name: 'East',
  station_id: 'st1', station_name: 'Abnub', source_station_name_raw: 'ابنوب',
  station_display: 'Abnub', unit_id: 'un1', unit_name: 'Abnub 1',
  parent_kind: 'compressor', parent_label: 'CMP-001',
  serial_number: '0012345', serial_number_raw: '0012345', serial_status: 'assigned',
  part_number: 'SS-4R3A', manufacturer: 'ACME', model: null, pressure_raw: '250 BAR',
  last_done_date: '2026-01-01', last_done_precision: 'exact_date', last_done_display: '2026-01-01',
  next_due_date: '2026-10-01', next_due_precision: 'exact_date', next_due_display: '2026-10-01',
  days_left: 15, due_status: 'due_15',
  mapping_status: 'resolved', needs_mapping: false,
  source_status_raw: null, needs_review: false, unit_job_number: 'JOB-77',
}

beforeEach(() => {
  db.rows = {
    v_report_due_compliance: [DUE_ROW],
    v_report_due_summary: [{
      total: 1, overdue: 0, due_today: 0, due_7: 0,
      due_30: 0, unknown: 0, unresolved: 0,
    }],
    regions: [{ id: 'r1', name: 'East' }, { id: 'r2', name: 'West' }],
    stations: [{ id: 'st1', station_name: 'Abnub' }],
    units: [{ id: 'un1', unit_name: 'Abnub 1' }],
  }
  db.counts = {}
  db.role = 'engineer'
  db.status = 'active'
  db.queries = []
  db.rpcCalls = []
  db.writes = []
})
afterEach(() => vi.clearAllMocks())

beforeEach(() => {
  downloads.files = []
  const g = globalThis as unknown as {
    URL: { createObjectURL?: (b: Blob) => string; revokeObjectURL?: (u: string) => void }
  }
  g.URL.createObjectURL = (blob: Blob) => {
    // Blob.text() is async and the click path is not; the CSV is captured from
    // the parts the component passed in, which is the same string it wrote.
    const parts = (blob as unknown as { __parts?: string[] }).__parts ?? []
    downloads.files.push({ name: '', text: parts.join('') })
    return 'blob:stub'
  }
  g.URL.revokeObjectURL = () => {}
})

// Capture the Blob's parts, which jsdom's Blob does not expose synchronously.
const RealBlob = globalThis.Blob
class CapturingBlob extends RealBlob {
  __parts: string[]
  constructor(parts: BlobPart[], options?: BlobPropertyBag) {
    super(parts, options)
    this.__parts = parts.map((p) => String(p))
  }
}
globalThis.Blob = CapturingBlob as unknown as typeof Blob

const originalClick = HTMLAnchorElement.prototype.click
beforeEach(() => {
  HTMLAnchorElement.prototype.click = function stubbedClick(this: HTMLAnchorElement) {
    const last = downloads.files[downloads.files.length - 1]
    if (last) last.name = this.download
  }
})
afterEach(() => { HTMLAnchorElement.prototype.click = originalClick })

const withRouter = (ui: React.ReactElement) => <MemoryRouter>{ui}</MemoryRouter>
const dueSpec = reportSpec('due')

function queriesFor(view: string) {
  return db.queries.filter((q) => q.table === view && !q.head)
}

describe('the Reports shell', () => {
  it('offers every required report category as a deep link', async () => {
    render(withRouter(<ReportsView />))
    const nav = await screen.findByRole('navigation', { name: /report categories/i })
    for (const label of [
      'Due & Overdue', 'SRV', 'Vessels', 'Gas Detectors', 'Hoses',
      'Data Quality', 'Notification Activity',
    ]) {
      expect(within(nav).getByRole('link', { name: label })).toBeDefined()
    }
  })

  it('shows a permission state to an account that is not active', async () => {
    db.status = 'pending_approval'
    render(withRouter(<ReportsView />))
    expect(await screen.findByText(/an active account is required/i)).toBeDefined()
    expect(screen.queryByRole('navigation', { name: /report categories/i })).toBeNull()
  })
})

describe('the query the report issues', () => {
  it('reads the report view, never an asset table directly', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    expect(queriesFor('v_report_due_compliance').length).toBeGreaterThan(0)
    for (const forbidden of ['installed_relief_valves', 'storage_vessels', 'gas_detectors', 'hoses']) {
      expect(db.queries.some((q) => q.table === forbidden)).toBe(false)
    }
  })

  it('orders deterministically, ending with the row identity', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    const ops = queriesFor('v_report_due_compliance')[0].ops
    const orders = ops.filter((o) => o.startsWith('order:'))
    expect(orders[0]).toBe('order:next_due_date:asc')
    // Without this tiebreak two rows sharing a due date could swap between
    // pages, showing one twice and omitting the other.
    expect(orders[orders.length - 1]).toBe(`order:${dueSpec.idColumn}:asc`)
  })

  it('pages with a bounded range rather than fetching everything', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    const ops = queriesFor('v_report_due_compliance')[0].ops
    expect(ops.some((o) => o === 'range:0-49')).toBe(true)
  })

  it('selects only the columns the report declares', () => {
    const cols = selectColumnsFor(dueSpec)
    expect(cols).toContain('asset_id')
    expect(cols).toContain('next_due_precision')
    expect(cols).not.toContain('*')
  })

  it('never selects a column the view does not have', () => {
    // Warehouse stock hangs off no Unit, so `unit_id` must not be requested.
    const warehouse = selectColumnsFor(reportSpec('srv-warehouse'))
    expect(warehouse).not.toContain('unit_id')
    expect(selectColumnsFor(dueSpec)).toContain('unit_id')
  })
})

describe('filters', () => {
  it('applies Region, due state and search to the server query', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    await userEvent.selectOptions(screen.getByLabelText(/due state/i), 'overdue')
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))

    const ops = queriesFor('v_report_due_compliance').at(-1)!.ops.join(' ')
    expect(ops).toMatch(/eq:region_id=r1/)
    expect(ops).toMatch(/eq:due_status=overdue/)
  })

  it('does not query on every keystroke — Apply commits', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    const before = queriesFor('v_report_due_compliance').length
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    expect(queriesFor('v_report_due_compliance').length).toBe(before)
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))
    expect(queriesFor('v_report_due_compliance').length).toBeGreaterThan(before)
  })

  it('offers no Station until a Region is chosen, and no Unit until a Station is', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    expect((screen.getByLabelText('Station') as HTMLSelectElement).disabled).toBe(true)
    expect((screen.getByLabelText('Unit') as HTMLSelectElement).disabled).toBe(true)

    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    expect((screen.getByLabelText('Station') as HTMLSelectElement).disabled).toBe(false)
    expect((screen.getByLabelText('Unit') as HTMLSelectElement).disabled).toBe(true)
  })

  it('scopes the Station list to the chosen Region', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    const ops = db.queries.filter((q) => q.table === 'stations').at(-1)!.ops.join(' ')
    expect(ops).toMatch(/eq:region_id=r1/)
  })

  it('clears a Station and Unit when the Region changes', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    await userEvent.selectOptions(screen.getByLabelText('Station'), 'st1')
    expect((screen.getByLabelText('Station') as HTMLSelectElement).value).toBe('st1')
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r2')
    // A Station/Unit pair from another Region is not expressible.
    expect((screen.getByLabelText('Station') as HTMLSelectElement).value).toBe('')
    expect((screen.getByLabelText('Unit') as HTMLSelectElement).value).toBe('')
  })

  it('resets paging when the filters change', async () => {
    db.rows.v_report_due_compliance = Array.from({ length: 120 }, (_, i) => ({
      ...DUE_ROW, asset_id: `a${i}`, serial_number: `S-${i}`,
    }))
    db.counts.v_report_due_compliance = 120
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('S-0')
    const pager = await screen.findByLabelText('Due & Overdue report page number')
    expect((pager as HTMLSelectElement).options).toHaveLength(3)
    fireEvent.change(pager, { target: { value: '1' } })
    expect((pager as HTMLSelectElement).value).toBe('1')
    await screen.findByText('S-50')
    await waitFor(() => expect([...queriesFor('v_report_due_compliance')].reverse().find((query) => query.ops.some((op) => op.startsWith('range:')))!.ops).toContain('range:50-99'))

    await userEvent.selectOptions(screen.getByLabelText(/due state/i), 'overdue')
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))
    // Page 2 of the old question must not survive into the new one.
    await waitFor(() => expect([...queriesFor('v_report_due_compliance')].reverse().find((query) => query.ops.some((op) => op.startsWith('range:')))!.ops).toContain('range:0-49'))
  })
})

describe('summary metrics', () => {
  it('counts on the server, under the same filters, not from the loaded page', async () => {
    db.rows.v_report_due_summary = [{
      total: 4210, overdue: 100, due_today: 2, due_7: 8,
      due_30: 20, unknown: 300, unresolved: 400,
    }]
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    const total = (await screen.findByText('Total Records')).closest('div')!
    expect(within(total).getByText('4,210')).toBeDefined()
    const summaries = db.queries.filter((q) => q.table === 'v_report_due_summary')
    expect(summaries).toHaveLength(1)
    expect(summaries[0].ops).toContain('select:*')
  })

  it('offers an Unknown Due Date metric, so a non-exact date is never hidden', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    expect(await screen.findByText(/unknown due date/i)).toBeDefined()
  })
})

describe('CSV export', () => {
  it('re-runs the same view, filters and order as the table', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.selectOptions(screen.getByLabelText('Region'), 'r1')
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))
    db.queries = []

    await userEvent.click(screen.getByRole('button', { name: /export csv/i }))
    const exportQuery = queriesFor('v_report_due_compliance').at(-1)!
    const ops = exportQuery.ops.join(' ')
    expect(exportQuery.table).toBe(dueSpec.view)
    // Same Region filter. An export that dropped it would widen the scope.
    expect(ops).toMatch(/eq:region_id=r1/)
    expect(ops).toMatch(/order:asset_id:asc/)
    // Bounded pages, not one unbounded scan.
    expect(ops).toMatch(/range:0-999/)
  })

  it('writes a file named for the report and the Cairo business date', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.click(screen.getByRole('button', { name: /export csv/i }))
    expect(downloads.files).toHaveLength(1)
    expect(downloads.files[0].name).toMatch(/^cng-due-\d{4}-\d{2}-\d{2}\.csv$/)
  })

  it('writes the declared headers and the authorized rows, and nothing else', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.click(screen.getByRole('button', { name: /export csv/i }))
    const csv = downloads.files[0].text
    const lines = csv.replace(/^\uFEFF/, '').split('\r\n')
    expect(lines[0]).toBe(dueSpec.columns.map((c) => c.header).join(','))
    // The one authorized row, with its identifier intact and its NULL blank.
    expect(lines[1]).toContain('0012345')
    expect(lines[1]).toContain('JOB-77')
    expect(lines).toHaveLength(3)
  })

  it('neutralizes a formula payload that reached the database as data', async () => {
    db.rows.v_report_due_compliance = [{
      ...DUE_ROW, manufacturer: '=cmd|\' /C calc\'!A0', serial_number: '+1234',
    }]
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('+1234')
    await userEvent.click(screen.getByRole('button', { name: /export csv/i }))
    const csv = downloads.files[0].text
    // Guarded, and the original still recoverable — the guard prefixes, it
    // never edits.
    expect(csv).toContain(`"'=cmd|' /C calc'!A0"`)
    expect(csv).toContain(`"'+1234"`)
    expect(csv).not.toMatch(/,=cmd/)
  })

  it('exports the same columns, in the same order, as the table', () => {
    const csvHeaders = csvColumnsFor(dueSpec).map((c) => c.header)
    expect(csvHeaders).toEqual(dueSpec.columns.map((c) => c.header))
  })

  it('exports raw values, so a year-only date never leaves as a calendar date', () => {
    const cols = csvColumnsFor(dueSpec)
    const nextDue = cols.find((c) => c.header === 'Next Due')!
    const yearOnly = {
      ...DUE_ROW, next_due_date: null, next_due_precision: 'year_only',
      next_due_display: '2022 (year only)',
    }
    // The raw date column is NULL for a year-only value, so the CSV cell is
    // blank rather than a date nobody proved.
    expect(nextDue.value(yearOnly)).toBeNull()
  })
})

describe('reports mutate nothing', () => {
  it('issues no RPC and no write, on any report', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    await userEvent.click(screen.getByRole('button', { name: /export csv/i }))
    expect(db.rpcCalls).toEqual([])
    expect(db.writes).toEqual([])
  })

  it('never acknowledges an alert from the activity report', async () => {
    db.rows.v_alert_inbox = [{
      id: 'al1', generated_at: '2026-09-01T00:00:00Z', subject: 'srv_calibration',
      threshold: 'due_30', asset_type: 'installed_relief_valve', asset_serial: 'S-1',
      asset_serial_status: 'assigned', region_name: 'East', station_name: 'Abnub',
      unit_name: 'Abnub 1', unit_id: 'un1', due_date: '2026-10-01', state: 'open',
      acknowledged_by_name: null, acknowledged_at: null,
      email_status: null, push_status: null,
    }]
    render(withRouter(<ActivityReportSection />))
    await screen.findByText('S-1')
    expect(db.rpcCalls).toEqual([])
    expect(screen.queryByRole('button', { name: /acknowledge/i })).toBeNull()
    // Reading a report is not reading an alert, and neither is acknowledging.
    expect(db.writes).toEqual([])
  })

  it('states that a blank delivery column is not a delivery', async () => {
    render(withRouter(<ActivityReportSection />))
    expect(await screen.findByText(/blank column means no delivery was ever attempted/i))
      .toBeDefined()
  })
})

describe('SRV installed and warehouse stay apart', () => {
  it('renders two separately labelled reports with their own totals', async () => {
    db.rows.v_installed_srv_management = [{ id: 'i1', serial_number: 'INST-1', unit_id: 'un1' }]
    db.rows.v_warehouse_srv_management = [{ id: 'w1', serial_number: 'WH-1' }]
    db.counts.v_installed_srv_management = 7
    db.counts.v_warehouse_srv_management = 3
    render(withRouter(<SrvReportSection />))
    expect(await screen.findByText('INST-1')).toBeDefined()
    expect(screen.getByText('WH-1')).toBeDefined()
    // Two reports, two totals. Never summed: 7 installed valves and 3 in stock
    // are not 10 of anything.
    expect(screen.getByRole('heading', { name: 'SRV (Installed)' })).toBeDefined()
    expect(screen.getByRole('heading', { name: 'SRV (Warehouse)' })).toBeDefined()
    expect(screen.queryByText('10')).toBeNull()
  })
})

describe('data quality is read-only', () => {
  it('offers no mapping control, only a pointer to Admin', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [{
      dq_key: 'canonical:dq1', record_id: 'dq1', source_layer: 'canonical',
      asset_type: 'hose', issue_kind: 'needs_unit_mapping',
      region_name: 'East', station_name: 'Abnub', raw_station: null,
      detail: 'unit not proven', severity: null,
      source_file: null, source_row: null, needs_review: true,
      observed_at: '2026-09-01T00:00:00Z', unit_id: null,
    }]
    render(withRouter(<DataQualityReportSection />))
    await screen.findByText('unit not proven')
    expect(screen.getByRole('link', { name: /resolve mappings in admin/i })).toBeDefined()
    expect(screen.queryByRole('button', { name: /resolve|decide|map|confirm/i })).toBeNull()
    expect(db.rpcCalls).toEqual([])
  })

  it('tells a non-admin where corrections happen without offering a dead link', async () => {
    db.role = 'viewer'
    render(withRouter(<DataQualityReportSection />))
    expect(await screen.findByText(/corrections are made by an administrator/i)).toBeDefined()
    expect(screen.queryByRole('link', { name: /resolve mappings/i })).toBeNull()
  })
})

describe('empty states', () => {
  it('distinguishes "nothing imported yet" from "nothing matched"', async () => {
    db.rows.v_report_due_compliance = []
    db.counts.v_report_due_compliance = 0
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    // Unfiltered and empty: production simply has no canonical assets yet.
    expect(await screen.findByText(/no canonical assets have been imported yet/i)).toBeDefined()

    await userEvent.selectOptions(screen.getByLabelText(/due state/i), 'overdue')
    await userEvent.click(screen.getByRole('button', { name: 'Apply' }))
    expect(await screen.findByText(/no records match the selected filters/i)).toBeDefined()
  })

  it('does not present an empty report as an error', async () => {
    db.rows.v_report_due_compliance = []
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText(/no canonical assets have been imported yet/i)
    expect(screen.queryByText(/could not be loaded/i)).toBeNull()
  })

  it('invents no sample rows', async () => {
    db.rows.v_report_due_compliance = []
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText(/no canonical assets have been imported yet/i)
    expect(screen.queryByRole('table')).toBeNull()
  })
})

describe('NULL and identifiers on screen', () => {
  it('shows a NULL technical value as not recorded, never as N/A or 0', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    await screen.findByText('0012345')
    // `model` is NULL for an SRV: the column exists, the value does not.
    expect(screen.getAllByText(/not recorded/i).length).toBeGreaterThan(0)
    expect(screen.queryByText('N/A')).toBeNull()
  })

  it('preserves a leading-zero serial and the owner-confirmed part number', async () => {
    render(withRouter(<ReportWorkspace spec={dueSpec} />))
    expect(await screen.findByText('0012345')).toBeDefined()
    const srvSpec = reportSpec('srv')
    // SS-4R3A is a Part Number and lives in its own column, never the serial.
    expect(srvSpec.columns.find((c) => c.key === 'part_number')?.header).toBe('Part Number')
    expect(srvSpec.columns.find((c) => c.key === 'serial_number')?.header).toBe('Serial')
  })
})


/**
 * Prompt 20A — the completeness correction.
 *
 * The Data Quality report read canonical assets alone, so with no import
 * committed it showed "clean" while the staged import carried real unresolved
 * evidence. And the gas-detector report read a view that deliberately includes
 * recorded ABSENCE, which is not a device.
 */
describe('data quality covers all three layers', () => {
  const CANONICAL = {
    dq_key: 'canonical:c1', record_id: 'c1', source_layer: 'canonical',
    asset_type: 'installed_relief_valve', issue_kind: 'needs_equipment_mapping',
    region_name: 'East', station_name: 'Abnub', raw_station: null,
    detail: 'parent not proven', severity: null,
    source_file: null, source_row: null, needs_review: true,
    observed_at: '2026-09-03T00:00:00Z', unit_id: 'un1',
  }
  const STAGED_STALE = {
    dq_key: 'staged:s1', record_id: 's1', source_layer: 'staged',
    asset_type: 'storage_vessel', issue_kind: 'stale_source_decision',
    region_name: null, station_name: 'Abnub', raw_station: 'ابنوب',
    detail: 'V.xlsx#Sheet1#11', severity: null,
    source_file: 'V.xlsx', source_row: 11, needs_review: true,
    observed_at: '2026-09-02T00:00:00Z', unit_id: null,
  }
  const IMPORT_ISSUE = {
    dq_key: 'issue:i1', record_id: 'i1', source_layer: 'import_issue',
    asset_type: null, issue_kind: 'suspected_part_number_in_serial_column',
    region_name: 'West', station_name: null, raw_station: 'SS-4R3A',
    detail: 'part number in a serial column', severity: 'warning',
    source_file: 'SRV.xlsx', source_row: 9, needs_review: true,
    observed_at: '2026-09-01T00:00:00Z', unit_id: null,
  }

  it('reads the unified view, not the canonical queue alone', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [CANONICAL, STAGED_STALE, IMPORT_ISSUE]
    render(withRouter(<DataQualityReportSection />))
    await screen.findByText('parent not proven')
    expect(db.queries.some((q) => q.table === 'v_report_data_quality')).toBe(true)
    // The old source, read alone, is what made the report look clean.
    expect(db.queries.some((q) => q.table === 'v_data_quality_queue')).toBe(false)
  })

  it('shows canonical, staged and import-issue evidence together', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [CANONICAL, STAGED_STALE, IMPORT_ISSUE]
    render(withRouter(<DataQualityReportSection />))
    expect(await screen.findByText('parent not proven')).toBeDefined()
    expect(screen.getByText('V.xlsx#Sheet1#11')).toBeDefined()
    expect(screen.getByText('part number in a serial column')).toBeDefined()
    expect(screen.getByText('canonical')).toBeDefined()
    expect(screen.getByText('staged')).toBeDefined()
    expect(screen.getByText('import_issue')).toBeDefined()
  })

  it('shows a stale source decision as its own, distinctly named condition', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [STAGED_STALE]
    render(withRouter(<DataQualityReportSection />))
    expect((await screen.findAllByText('Stale Source Decision')).length).toBeGreaterThanOrEqual(2)
    // Never relabelled as awaiting, nor as a recorded decision.
    expect(screen.queryByText('staged_awaiting_decision')).toBeNull()
    expect(screen.queryByText('staged_decision_recorded')).toBeNull()
  })

  it('counts a stale source decision separately in the summary', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [STAGED_STALE]
    db.counts.v_report_data_quality = 3
    render(withRouter(<DataQualityReportSection />))
    expect((await screen.findAllByText('Stale Source Decision')).length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText('Awaiting Decision')).toBeDefined()
  })

  it('tells a Region-scoped role that staging is out of scope, not absent', async () => {
    db.role = 'viewer'
    db.rows.v_report_data_quality = [CANONICAL]
    render(withRouter(<DataQualityReportSection />))
    expect(await screen.findByText(/remain visible to managers and administrators only/i))
      .toBeDefined()
    expect(screen.getByText(/not absent, they are out of scope for this account/i)).toBeDefined()
  })

  it('describes the three layers to a manager', async () => {
    db.role = 'manager'
    db.rows.v_report_data_quality = [CANONICAL, STAGED_STALE]
    render(withRouter(<DataQualityReportSection />))
    expect(await screen.findByText(/three layers/i)).toBeDefined()
    expect(screen.getByText(/never counted as confirmed/i)).toBeDefined()
  })

  it('offers no re-review, map or confirm action anywhere', async () => {
    db.role = 'admin'
    db.rows.v_report_data_quality = [CANONICAL, STAGED_STALE, IMPORT_ISSUE]
    render(withRouter(<DataQualityReportSection />))
    await screen.findByText('V.xlsx#Sheet1#11')
    for (const action of [/re-review/i, /^map$/i, /^confirm/i, /^decide/i, /supersede/i]) {
      expect(screen.queryByRole('button', { name: action })).toBeNull()
    }
    expect(db.rpcCalls).toEqual([])
    expect(db.writes).toEqual([])
  })
})

describe('gas detectors exclude recorded absence', () => {
  it('reads the installed-only view, not the management view', async () => {
    db.rows.v_report_gas_detectors = [{
      detector_id: 'g1', serial_number: 'GD-1', region_name: 'East',
      station_display: 'Abnub', unit_id: 'un1',
    }]
    render(withRouter(<ReportWorkspace spec={reportSpec('gas-detectors')} />))
    await screen.findByText('GD-1')
    expect(db.queries.some((q) => q.table === 'v_report_gas_detectors')).toBe(true)
    // The management view UNIONs recorded absence; the asset report must not
    // read it, or "this area has no detector" becomes a detector.
    expect(db.queries.some((q) => q.table === 'v_gas_detector_management')).toBe(false)
  })

  it('orders by a detector identity that cannot be NULL', async () => {
    db.rows.v_report_gas_detectors = [{
      detector_id: 'g1', serial_number: 'GD-1', unit_id: 'un1',
    }]
    render(withRouter(<ReportWorkspace spec={reportSpec('gas-detectors')} />))
    await screen.findByText('GD-1')
    const ops = queriesFor('v_report_gas_detectors')[0].ops
    // A NULL sort key is what makes a paginated result non-deterministic: two
    // NULLs cannot be ordered against each other.
    expect(ops.filter((o) => o.startsWith('order:')).at(-1)).toBe('order:detector_id:asc')
    expect(reportSpec('gas-detectors').idColumn).toBe('detector_id')
  })

  it('leaves the due report reading installed detectors only, as before', () => {
    // 0042 already filtered detector_id IS NOT NULL; 20A changes nothing there.
    expect(reportSpec('due').view).toBe('v_report_due_compliance')
  })
})

describe('the Station column matches the view that serves it (Prompt 20B)', () => {
  /**
   * The production defect: every report shared one `HIERARCHY_COLUMNS`
   * constant naming `station_display`, a column that exists only on the two
   * views whose Station can be unconfirmed. Vessels, Gas Detectors and Hoses
   * asked three views for a column they never had, and PostgREST answered
   * `column v_report_gas_detectors.station_display does not exist`.
   *
   * `scripts/verify-report-contract.mjs` proves the columns exist against a
   * real schema. These assert the SEMANTIC half that a column check cannot:
   * that the fallback is used where a Station may genuinely be unconfirmed,
   * and NOT used where `station_id` is NOT NULL and there is nothing to fall
   * back to.
   */
  const stationKeyOf = (id: Parameters<typeof reportSpec>[0]) =>
    reportSpec(id).columns.find((c) => c.header === 'Station')?.key

  it.each(['due', 'srv'] as const)(
    '%s keeps the raw-source fallback, because its Station may be unconfirmed',
    (id) => {
      expect(stationKeyOf(id)).toBe('station_display')
    },
  )

  it.each(['vessels', 'gas-detectors', 'hoses'] as const)(
    '%s reads station_name — station_id is NOT NULL, so no fallback exists',
    (id) => {
      expect(stationKeyOf(id)).toBe('station_name')
    },
  )

  it('never asks a view for station_display unless that report also searches the raw name', () => {
    // The two are the same evidence: a report that can show a raw source
    // Station name is exactly one that can also search it. If they ever
    // disagree, one of the two was changed without the other.
    for (const spec of REPORT_SPECS) {
      const usesDisplay = spec.columns.some((c) => c.key === 'station_display')
      const searchesRaw = (spec.filterColumns.search ?? []).includes('source_station_name_raw')
      if (usesDisplay) expect(searchesRaw).toBe(true)
    }
  })

  it('exports the Station column the table shows, for every report', () => {
    // The CSV is generated from the same spec columns, so a divergence here
    // would mean the export reached for a field the query never selected.
    for (const spec of REPORT_SPECS) {
      const stationColumn = spec.columns.find((c) => c.header === 'Station')
      if (!stationColumn) continue
      expect(selectColumnsFor(spec)).toContain(stationColumn.key)
      expect(csvColumnsFor(spec).map((c) => c.header)).toContain('Station')
    }
  })

  it('selects every column it renders, filters, searches and orders by', () => {
    // The frontend-side mirror of the contract script: whatever a report uses
    // must be in its own select list, whether or not the view has it.
    for (const spec of REPORT_SPECS) {
      const selected = new Set(selectColumnsFor(spec))
      for (const c of spec.columns) expect(selected.has(c.key)).toBe(true)
      expect(selected.has(spec.idColumn)).toBe(true)
    }
  })
})
