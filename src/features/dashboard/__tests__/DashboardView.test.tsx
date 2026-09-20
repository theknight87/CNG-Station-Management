import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

/**
 * The rule this file defends: **a database error is never rendered as zero.**
 *
 * A dashboard that shows "0 overdue" because the query failed is a safety
 * system reporting all-clear while blind. These tests drive the real view with
 * a stubbed Supabase client and assert the distinction holds.
 */

const appUserState = vi.hoisted(() => ({ current: { status: 'active', user: { role: 'admin' } } as unknown }))
const queryResult = vi.hoisted(() => ({
  assets: { data: [] as unknown[], error: null as { message: string } | null },
  due: { data: [] as unknown[], error: null as { message: string } | null },
  regions: { data: [] as unknown[], error: null as { message: string } | null },
  mapping: { data: [] as unknown[], error: null as { message: string } | null },
  warehouse: { data: null as unknown, error: null as { message: string } | null },
}))

vi.mock('@/hooks/useAppUser', () => ({ useAppUser: () => appUserState.current }))

// A STABLE client object, exactly like the real singleton. Returning a fresh
// object per render would change the effect's dependency every time and spin
// the dashboard in an endless reload — which is precisely why
// `useSupabaseClient` returns a singleton in production.
const stubClient = vi.hoisted(() => ({ value: null as unknown }))

vi.mock('@/lib/supabase/client', () => {
  const client = {
    rpc() {
      const failure = Object.values(queryResult).find((result) => result.error)?.error ?? null
      return Promise.resolve({
        data: failure ? null : {
          assets: queryResult.assets.data,
          due: queryResult.due.data,
          regions: queryResult.regions.data,
          mapping: queryResult.mapping.data,
          warehouse: queryResult.warehouse.data ?? { total: 0, overdue: 0, approaching_due: 0 },
        },
        error: failure,
      })
      }
  }
  stubClient.value = client
  return { useSupabaseClient: () => client }
})

const { DashboardView } = await import('../DashboardView')

function reset() {
  appUserState.current = { status: 'active', user: { role: 'admin' } }
  queryResult.assets = { data: [], error: null }
  queryResult.due = { data: [], error: null }
  queryResult.regions = { data: [], error: null }
  queryResult.mapping = { data: [], error: null }
  queryResult.warehouse = { data: null, error: null }
}
afterEach(reset)

const renderView = () => render(<MemoryRouter><DashboardView /></MemoryRouter>)

describe('error is never zero', () => {
  it('VIEW-1 a failed query renders an ERROR, not a dashboard of zeros', async () => {
    reset()
    queryResult.due = { data: null as unknown as unknown[], error: { message: 'permission denied for view' } }

    renderView()
    expect(await screen.findByText(/Could not load the operational summary/i)).toBeDefined()
    // The critical assertion: no summary figures are rendered at all.
    expect(screen.queryByText('Overdue')).toBeNull()
    expect(screen.queryByText(/No operational records exist yet/i)).toBeNull()
  })

  it('VIEW-2 the error says explicitly that it is not a report of zero', async () => {
    reset()
    queryResult.regions = { data: null as unknown as unknown[], error: { message: 'connection reset' } }

    renderView()
    const message = await screen.findByText(/not a report of zero/i)
    expect(message).toBeDefined()
    expect(message.textContent).toContain('connection reset')
  })

  it('VIEW-3 ONE failing query fails the whole dashboard, not just its panel', async () => {
    reset()
    queryResult.assets = { data: [{ asset_kind: 'station', total: 157 }], error: null }
    queryResult.mapping = { data: null as unknown as unknown[], error: { message: 'timeout' } }

    renderView()
    expect(await screen.findByText(/Could not load the operational summary/i)).toBeDefined()
    // 157 is real and would render — but showing four good panels beside one
    // silently-empty one is the same lie in a smaller box.
    expect(screen.queryByText('157')).toBeNull()
  })

  it('VIEW-4 a genuinely empty database says so, and is NOT an error', async () => {
    reset()
    renderView()
    expect(await screen.findByText(/No operational records exist yet/i)).toBeDefined()
    expect(screen.getByText(/this is an empty database, not a failure/i)).toBeDefined()
    expect(screen.queryByText(/Could not load/i)).toBeNull()
  })

  it('VIEW-5 real data renders real figures', async () => {
    reset()
    queryResult.assets = { data: [{ asset_kind: 'station', total: 157 }], error: null }
    queryResult.due = {
      data: [{ asset_kind: 'installed_relief_valve', due_status: 'overdue', total: 12 }],
      error: null,
    }

    renderView()
    expect(await screen.findByText('157')).toBeDefined()
    expect(screen.queryByText(/No operational records exist yet/i)).toBeNull()
  })
})

describe('authorization states', () => {
  it('VIEW-6 an inactive account sees a permission state, not a dashboard of zeros', async () => {
    reset()
    appUserState.current = { status: 'pending_approval', user: { role: 'viewer' } }

    renderView()
    expect(await screen.findByText(/do not have access to operational data/i)).toBeDefined()
    // This is the misreading the state exists to prevent: an inactive user
    // concluding the system is empty when they simply cannot read it.
    expect(screen.queryByText(/No operational records exist yet/i)).toBeNull()
  })

  it('VIEW-7 while access is resolving it shows loading, not zeros', async () => {
    reset()
    appUserState.current = { status: 'loading' }

    renderView()
    expect(await screen.findByText(/Resolving your access/i)).toBeDefined()
    expect(screen.queryByText('Overdue')).toBeNull()
  })
})
