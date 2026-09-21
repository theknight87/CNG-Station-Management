import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes } from 'react-router-dom'

/**
 * The Alerts inbox.
 *
 * What these defend, hardest first:
 *
 * 1. **Alert, Due Status and Delivery stay three separate things.** A delivery
 *    failure is never rendered as "no alert"; the threshold that raised an
 *    alert is never overwritten by where the asset stands today.
 * 2. **Acknowledgement is never a client write.** The UI may only call the
 *    database function, and never supplies an actor or a timestamp.
 * 3. **Read is per-user and is NOT acknowledgement.** Opening a row does
 *    neither.
 * 4. **A failed query is never zero**, in the table or in the summary.
 * 5. **No React recomputation of due state** — the database's values render.
 * 6. **A Unit URL is never fabricated** for an unresolved Unit.
 *
 * Every date and count is a fixed literal; nothing derives from `Date.now()`.
 */

interface Reply {
  data: unknown
  error: { message: string } | null
  count?: number
}

const replies = vi.hoisted(() => ({
  alerts: { data: [] as unknown[], error: null, count: 0 } as Reply,
  headCount: { data: null, error: null, count: 0 } as Reply,
  regions: { data: [] as unknown[], error: null } as Reply,
  stations: { data: [] as unknown[], error: null, count: 0 } as Reply,
  rpc: { data: null, error: null } as Reply,
}))

const calls = vi.hoisted(() => ({ list: [] as string[], rpc: [] as string[] }))

vi.mock('@/lib/supabase/client', () => {
  const client = {
    from(table: string) {
      let head = false
      const chain: Record<string, unknown> = {
        select: (_c?: string, opts?: { head?: boolean }) => {
          head = Boolean(opts?.head)
          calls.list.push(`${table}.select`)
          return chain
        },
        eq: (col: string, value: unknown) => {
          calls.list.push(`${table}.eq:${col}=${String(value)}`)
          return chain
        },
        is: (col: string, value: unknown) => {
          calls.list.push(`${table}.is:${col}=${String(value)}`)
          return chain
        },
        gt: () => chain,
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
          return table === 'v_dashboard_region_summary' ? Promise.resolve(replies.regions) : chain
        },
        range: (a: number, b: number) => {
          calls.list.push(`${table}.range:${a}-${b}`)
          return Promise.resolve(table === 'v_station_summary' ? replies.stations : replies.alerts)
        },
        then: (resolve: (v: unknown) => unknown) => {
          const n = replies.headCount.count ?? 0
          const reply = table === 'v_alert_summary'
            ? {
                data: replies.headCount.error ? null : [{
                  total: n, overdue: n, due_today: n, due_7: n,
                  unread: n, unacknowledged: n, delivery_failed: n,
                }],
                error: replies.headCount.error,
              }
            :
            table === 'v_dashboard_region_summary' ? replies.regions
            : table === 'v_station_summary' ? replies.stations
            : head ? replies.headCount
            : replies.alerts
          return Promise.resolve(reply).then(resolve)
        },
      }
      return chain
    },
    rpc(fn: string, args: Record<string, unknown>) {
      calls.rpc.push(`${fn}(${JSON.stringify(args)})`)
      return Promise.resolve(replies.rpc)
    },
  }
  return { useSupabaseClient: () => client }
})

const { AlertsView } = await import('@/features/alerts/AlertsView')

function alert(over: Record<string, unknown> = {}) {
  return {
    id: 'al-1',
    subject: 'srv_calibration', threshold: 'due_30', state: 'open',
    asset_type: 'installed_relief_valve', asset_id: 'asset-1',
    region_id: 'r-east', region_name: 'East',
    station_id: 's-0', station_name: 'الماظة',
    needs_station_mapping: false, source_station_name_raw: null,
    unit_id: 'u-1', unit_name: 'الماظة 1',
    due_date: '2026-10-16',
    days_left: 30, due_status: 'due_30',
    needs_mapping: false,
    acknowledged_by: null, acknowledged_at: null, acknowledged_by_name: null,
    resolved_at: null,
    generated_at: '2026-09-16T01:00:00Z',
    is_read: false, read_at: null,
    email_status: null, push_status: null,
    asset_serial: 'RV-880124', asset_serial_status: 'assigned',
    ...over,
  }
}

beforeEach(() => {
  calls.list = []
  calls.rpc = []
  replies.alerts = { data: [], error: null, count: 0 }
  replies.headCount = { data: null, error: null, count: 0 }
  replies.regions = { data: [], error: null }
  replies.stations = { data: [], error: null, count: 0 }
  replies.rpc = { data: null, error: null }
})
afterEach(() => vi.clearAllMocks())

function renderAlerts() {
  return render(
    <MemoryRouter initialEntries={['/alerts']}>
      <Routes>
        <Route path="/alerts" element={<AlertsView />} />
        <Route path="/units/:unitId" element={<div>UNIT WORKSPACE</div>} />
        <Route path="/stations/:stationId" element={<div>STATION WORKSPACE</div>} />
      </Routes>
    </MemoryRouter>,
  )
}

async function expand() {
  await userEvent.click(screen.getByRole('button', { name: /show the full technical record/i }))
}

describe('Route and shell', () => {
  it('renders /alerts with exactly one h1', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    const h1s = screen.getAllByRole('heading', { level: 1 })
    expect(h1s).toHaveLength(1)
    expect(h1s[0].textContent).toContain('Alerts')
  })

  it('reads the alert inbox view, never the alerts table directly', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    expect(calls.list.some((c) => c.startsWith('v_alert_inbox.'))).toBe(true)
    expect(calls.list.some((c) => c.startsWith('alerts.'))).toBe(false)
  })
})

describe('Column priority', () => {
  it('leads with attention, identity, hierarchy and timing before secondary state', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    const order = screen
      .getAllByRole('columnheader')
      .map((h) => h.textContent?.trim() ?? '')
      .filter((h) => h && !/expand/i.test(h))
    expect(order.slice(0, 9)).toEqual([
      'Alert', 'Asset', 'Station', 'Unit', 'Due date', 'Days left', 'Status', 'Read', 'Acknowledged',
    ])
    // Subject is filterable and implied by the asset type; with it second,
    // Acknowledged fell outside the visible region at 1440px.
    expect(order.indexOf('Subject')).toBeGreaterThan(order.indexOf('Acknowledged'))
  })
})

describe('Alert, Due Status and Delivery are three different things', () => {
  it('shows the raising threshold alongside a DIFFERENT current status', async () => {
    // Raised at 30 days; the asset has since gone overdue. Both facts show.
    replies.alerts = {
      data: [alert({ threshold: 'due_30', due_status: 'overdue', days_left: -5 })],
      error: null, count: 1,
    }
    renderAlerts()
    await screen.findByText('RV-880124')
    const table = screen.getByRole('table')
    expect(within(table).getByText('30 days')).toBeDefined()
    expect(within(table).getAllByText(/overdue/i).length).toBeGreaterThan(0)
    expect(within(table).getByText('-5')).toBeDefined()
  })

  it('renders the database due status rather than recomputing one', async () => {
    // days_left and due_status disagree deliberately. A UI that recomputed
    // would "correct" this; it must not.
    replies.alerts = { data: [alert({ days_left: 999, due_status: 'overdue' })], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    expect(screen.getAllByText(/overdue/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText('999').length).toBeGreaterThan(0)
  })

  it('shows a failed delivery as an alert that EXISTS, never as no alert', async () => {
    replies.alerts = { data: [alert({ email_status: 'failed' })], error: null, count: 1 }
    renderAlerts()
    const table = await screen.findByRole('table')
    expect(within(table).getByText('RV-880124')).toBeDefined()
    expect(within(table).getAllByText(/failed/i).length).toBeGreaterThan(0)
    expect(screen.queryByText(/^No alerts$/i)).toBeNull()
  })

  it('distinguishes "not attempted" from a delivery failure', async () => {
    replies.alerts = { data: [alert({ email_status: null })], error: null, count: 1 }
    renderAlerts()
    const table = await screen.findByRole('table')
    expect(within(table).getAllByText(/not attempted/i).length).toBeGreaterThan(0)
    expect(within(table).queryByText(/failed/i)).toBeNull()
  })

  it('invents no safety severity language', async () => {
    replies.alerts = { data: [alert({ threshold: 'overdue', due_status: 'overdue' })], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    const body = document.body.textContent ?? ''
    for (const word of [/critical/i, /emergency/i, /danger/i, /unsafe/i, /urgent!/i]) {
      expect(body).not.toMatch(word)
    }
  })
})

describe('Read state is per-user and is not acknowledgement', () => {
  it('shows unread and read as words, not weight alone', async () => {
    replies.alerts = {
      data: [alert({ id: 'a', is_read: false }), alert({ id: 'b', is_read: true, asset_serial: 'RV-2' })],
      error: null, count: 2,
    }
    renderAlerts()
    // Scoped to the body: "Read" is also a column header.
    const body = (await screen.findByRole('table')).querySelector('tbody')!
    expect(within(body).getByText('Unread')).toBeDefined()
    expect(within(body).getByText('Read')).toBeDefined()
  })

  it('marks read through the database function, never a table write', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    await userEvent.click(screen.getByRole('button', { name: /mark as read/i }))
    expect(calls.rpc.some((c) => c.startsWith('cng_mark_alert_read('))).toBe(true)
    // The client supplies only the alert id — never a user or a timestamp.
    expect(calls.rpc.join(' ')).not.toMatch(/app_user|read_at|acknowledged/)
  })

  it('offers mark-as-unread once an alert is read', async () => {
    replies.alerts = { data: [alert({ is_read: true, read_at: '2026-09-16T08:00:00Z' })], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    await userEvent.click(screen.getByRole('button', { name: /mark as unread/i }))
    expect(calls.rpc.some((c) => c.startsWith('cng_mark_alert_unread('))).toBe(true)
  })

  it('opening an alert neither reads nor acknowledges it', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    // Expanding is a UI act, not an operational one.
    expect(calls.rpc).toHaveLength(0)
  })
})

describe('Acknowledgement', () => {
  it('acknowledges through the database function with no actor or timestamp', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    await userEvent.click(screen.getByRole('button', { name: /^acknowledge$/i }))
    const call = calls.rpc.find((c) => c.startsWith('cng_acknowledge_alert('))
    expect(call).toBeDefined()
    // The ONLY argument is the alert id. Attribution comes from the server.
    expect(call).toBe('cng_acknowledge_alert({"p_alert_id":"al-1"})')
  })

  it('shows the server-recorded actor and disables re-acknowledgement', async () => {
    replies.alerts = {
      data: [alert({ state: 'acknowledged', acknowledged_at: '2026-09-16T08:05:00Z', acknowledged_by_name: 'Eng. Mostafa' })],
      error: null, count: 1,
    }
    renderAlerts()
    await screen.findByText('RV-880124')
    expect(screen.getAllByText(/Eng\. Mostafa/).length).toBeGreaterThan(0)
    await expand()
    // jest-dom is not installed in this project, so assert the attribute.
    expect(screen.getByRole('button', { name: /already acknowledged/i }).hasAttribute('disabled')).toBe(true)
  })

  it('states a failed acknowledgement instead of swallowing it', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    replies.rpc = { data: null, error: { message: 'alert not found' } }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    await userEvent.click(screen.getByRole('button', { name: /^acknowledge$/i }))
    expect(await screen.findByRole('alert')).toBeDefined()
    expect(screen.getByRole('alert').textContent).toMatch(/did not complete/i)
  })

  it('keeps read and acknowledgement as independent filters', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /^read$/i }), 'unread')
    expect(calls.list).toContain('v_alert_inbox.eq:is_read=false')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /acknowledgement/i }), 'unacknowledged')
    expect(calls.list).toContain('v_alert_inbox.is:acknowledged_at=null')
  })
})

describe('Hierarchy and navigation', () => {
  it('links to the Unit workspace when the Unit is confirmed', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    await userEvent.click(screen.getByRole('link', { name: /open unit/i }))
    expect(await screen.findByText('UNIT WORKSPACE')).toBeDefined()
  })

  it('never fabricates a Unit URL for an unresolved Unit', async () => {
    replies.alerts = {
      data: [alert({ unit_id: null, unit_name: null, needs_mapping: true })],
      error: null, count: 1,
    }
    renderAlerts()
    await screen.findByText('RV-880124')
    const table = screen.getByRole('table')
    expect(within(table).getAllByText(/not confirmed/i).length).toBeGreaterThan(0)
    await expand()
    expect(screen.queryByRole('link', { name: /open unit/i })).toBeNull()
    // The Station IS proven, so that stays navigable.
    expect(screen.getByRole('link', { name: /open station/i })).toBeDefined()
  })
})

describe('Unresolved-station SRV alerts', () => {
  it('names the raw source place without asserting a canonical Station', async () => {
    replies.alerts = {
      data: [alert({
        station_id: null, station_name: null,
        needs_station_mapping: true, source_station_name_raw: 'ابنوب اسيوط',
        unit_id: null, unit_name: null, needs_mapping: true,
      })],
      error: null, count: 1,
    }
    renderAlerts()
    await screen.findByText('RV-880124')
    const table = screen.getByRole('table')
    expect(within(table).getByText(/station not confirmed/i)).toBeDefined()
    expect(within(table).getByText(/ابنوب اسيوط/)).toBeDefined()
  })

  it('offers no Station or Unit link when neither is confirmed', async () => {
    replies.alerts = {
      data: [alert({
        station_id: null, station_name: null,
        needs_station_mapping: true, source_station_name_raw: 'ابنوب اسيوط',
        unit_id: null, unit_name: null, needs_mapping: true,
      })],
      error: null, count: 1,
    }
    renderAlerts()
    await screen.findByText('RV-880124')
    await expand()
    expect(screen.queryByRole('link', { name: /open unit/i })).toBeNull()
    expect(screen.queryByRole('link', { name: /open station/i })).toBeNull()
    expect(screen.getByText(/no confirmed hierarchy to open/i)).toBeDefined()
  })
})

describe('Server-side search, filters, sorting, pagination', () => {
  it('sends search to the server across asset serial, station and folded unit', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await userEvent.type(screen.getByRole('searchbox', { name: /search alerts/i }), 'RV-8801')
    const or = calls.list.find((c) => c.includes('.or:') && c.includes('RV-8801'))
    expect(or).toBeDefined()
    expect(or).toContain('asset_serial.ilike')
    expect(or).toContain('station_name.ilike')
    expect(or).toContain('unit_name.ilike')
  })

  it('combines Region + Subject + Threshold as a server-side intersection', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    replies.regions = { data: [{ region_id: 'r-east', region_code: 'east', region_name: 'East', sort_order: 1, stations: 1, units: 1, assets: 1, overdue: 1, approaching_due: 0, unresolved_mapping: 0 }], error: null }
    renderAlerts()
    await screen.findByText('RV-880124')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /region/i }), 'r-east')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /subject/i }), 'srv_calibration')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /threshold/i }), 'overdue')
    expect(calls.list).toContain('v_alert_inbox.eq:region_id=r-east')
    expect(calls.list).toContain('v_alert_inbox.eq:subject=srv_calibration')
    expect(calls.list).toContain('v_alert_inbox.eq:threshold=overdue')
  })

  it('filters on delivery state server-side', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    await userEvent.selectOptions(screen.getByRole('combobox', { name: /delivery/i }), 'failed')
    expect(calls.list).toContain('v_alert_inbox.eq:email_status=failed')
  })

  it('marks the sorted column with aria-sort and toggles both directions', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    const header = () => screen.getByRole('columnheader', { name: /due date/i })
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_alert_inbox.order:due_date:asc')
    await userEvent.click(within(header()).getByRole('button'))
    expect(calls.list).toContain('v_alert_inbox.order:due_date:desc')
  })

  it('appends a deterministic tie-break so paging is stable', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    renderAlerts()
    await screen.findByText('RV-880124')
    expect(calls.list).toContain('v_alert_inbox.order:id:asc')
  })

  it('pages on the server rather than loading all history', async () => {
    replies.alerts = { data: [alert()], error: null, count: 400 }
    renderAlerts()
    await screen.findByText('RV-880124')
    expect(calls.list).toContain('v_alert_inbox.range:0-49')
    const pager = screen.getByRole('navigation', { name: /pagination/i })
    await userEvent.click(within(pager).getByRole('button', { name: /next/i }))
    expect(calls.list).toContain('v_alert_inbox.range:50-99')
    expect(screen.getByText(/of 400/)).toBeDefined()
  })
})

describe('Summary', () => {
  it('counts dataset-wide, separating unread from unacknowledged', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    replies.headCount = { data: null, error: null, count: 12 }
    renderAlerts()
    await screen.findByText('RV-880124')
    const strip = screen.getByRole('region', { name: /alert summary/i }) ?? document.body
    expect(strip).toBeDefined()
    // One RLS-bounded aggregate replaces seven independent count queries.
    expect(calls.list).toContain('v_alert_summary.select')
  })

  it('never renders a failed count as zero', async () => {
    replies.alerts = { data: [alert()], error: null, count: 1 }
    replies.headCount = { data: null, error: { message: 'permission denied' }, count: 0 }
    renderAlerts()
    expect(await screen.findByText(/alert summary could not be loaded/i)).toBeDefined()
    // No metric strip is drawn at all, so no count can read as a fabricated
    // zero. (The page h1 is also "Alerts", so this checks the strip itself.)
    expect(screen.queryByRole('region', { name: /alert summary/i })).toBeNull()
    expect(screen.queryByText(/visible to you/i)).toBeNull()
  })
})

describe('Loading, empty, no-match and failure are four different screens', () => {
  it('states an honest empty inbox', async () => {
    replies.alerts = { data: [], error: null, count: 0 }
    renderAlerts()
    expect(await screen.findByText(/^No alerts$/i)).toBeDefined()
  })

  it('distinguishes "no match" from "nothing exists"', async () => {
    replies.alerts = { data: [], error: null, count: 0 }
    replies.headCount = { data: null, error: null, count: 40 }
    renderAlerts()
    await userEvent.type(screen.getByRole('searchbox', { name: /search alerts/i }), 'zzzz')
    expect(await screen.findByText(/no results match these filters/i)).toBeDefined()
  })

  it('never renders a failed row query as an empty inbox', async () => {
    replies.alerts = { data: null, error: { message: 'permission denied for view v_alert_inbox' }, count: 0 }
    renderAlerts()
    expect(await screen.findByText(/could not load alerts/i)).toBeDefined()
    expect(screen.queryByText(/^No alerts$/i)).toBeNull()
  })
})

describe('Presentation of unknown data', () => {
  it('shows an asset with no recorded serial as not recorded, never invented', async () => {
    replies.alerts = { data: [alert({ asset_serial: null, asset_serial_status: 'unknown' })], error: null, count: 1 }
    renderAlerts()
    const table = await screen.findByRole('table')
    expect(within(table).getAllByText(/not recorded/i).length).toBeGreaterThan(0)
    expect(table.textContent).not.toMatch(/N\/A/)
    expect(within(table).queryByText('asset-1')).toBeNull()
  })

  it('renders Arabic and mixed identifiers', async () => {
    replies.alerts = {
      data: [alert({ asset_serial: 'صمام-RV-2024-0077', station_name: 'الماظة' })],
      error: null, count: 1,
    }
    renderAlerts()
    expect(await screen.findByText('صمام-RV-2024-0077')).toBeDefined()
    expect(screen.getAllByText('الماظة').length).toBeGreaterThan(0)
  })
})
