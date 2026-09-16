import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

/**
 * The Prompt 16-18 reconciliation surfaces: the notification bell and the
 * per-user preference screen.
 *
 * What these defend:
 *
 * 1. **The badge counts UNREAD, never unacknowledged.** Conflating the two would
 *    invite the reading that clearing a badge discharges an operational duty.
 * 2. **An unknown count shows nothing.** A failed request must not render a
 *    confident `0` — that is a fabricated value standing in for missing data.
 * 3. **The client never names a user.** Preferences are written with no
 *    app_user_id; RLS binds the row to its owner.
 * 4. **Nothing is enabled by default.** An account with no preference rows shows
 *    both channels off, because that is exactly what the engine does.
 */

const db = vi.hoisted(() => ({
  unread: 0 as number | null,
  countError: null as null | { message: string },
  prefRows: [] as Record<string, unknown>[],
  writes: [] as { op: string; table: string; payload?: unknown }[],
}))

vi.mock('@/lib/supabase/client', () => ({
  useSupabaseClient: () => ({
    from: (table: string) => ({
      select: (_cols: string, opts?: { head?: boolean; count?: string }) => {
        if (opts?.head) {
          const result = { count: db.countError ? null : db.unread, error: db.countError }
          return { eq: () => Promise.resolve(result) }
        }
        return { is: () => Promise.resolve({ data: db.prefRows, error: null }) }
      },
      insert: (payload: unknown) => {
        db.writes.push({ op: 'insert', table, payload })
        return Promise.resolve({ error: null })
      },
      update: (payload: unknown) => {
        db.writes.push({ op: 'update', table, payload })
        return { eq: () => Promise.resolve({ error: null }) }
      },
    }),
  }),
}))

const { AlertBell } = await import('@/features/alerts/AlertBell')
const { NotificationPreferences } = await import('@/features/alerts/NotificationPreferences')

beforeEach(() => {
  db.unread = 0
  db.countError = null
  db.prefRows = []
  db.writes = []
})
afterEach(() => vi.clearAllMocks())

const withRouter = (ui: React.ReactElement) => <MemoryRouter>{ui}</MemoryRouter>

describe('The notification bell', () => {
  it('links to the Alerts page rather than opening a second inbox', async () => {
    render(withRouter(<AlertBell />))
    const link = await screen.findByRole('link', { name: /alerts/i })
    expect(link.getAttribute('href')).toBe('/alerts')
  })

  it('shows the unread count when there is one', async () => {
    db.unread = 7
    render(withRouter(<AlertBell />))
    expect(await screen.findByRole('link', { name: /7 unread/i })).toBeDefined()
    expect(screen.getByText('7')).toBeDefined()
  })

  it('caps the badge but keeps the exact number for screen readers', async () => {
    db.unread = 412
    render(withRouter(<AlertBell />))
    expect(await screen.findByRole('link', { name: /412 unread/i })).toBeDefined()
    expect(screen.getByText('99+')).toBeDefined()
  })

  it('shows no badge at zero', async () => {
    db.unread = 0
    render(withRouter(<AlertBell />))
    await screen.findByRole('link', { name: /alerts/i })
    expect(screen.queryByText('0')).toBeNull()
  })

  it('shows no badge when the count could not be read, rather than a confident zero', async () => {
    db.countError = { message: 'network' }
    render(withRouter(<AlertBell />))
    const link = await screen.findByRole('link', { name: /alerts/i })
    expect(link.textContent).toBe('')
    expect(screen.queryByText('0')).toBeNull()
  })
})

describe('Notification preferences', () => {
  it('defaults every channel to OFF when the account has no preference rows', async () => {
    render(<NotificationPreferences />)
    const buttons = await screen.findAllByRole('button', { name: /off — turn on/i })
    // Email and browser notifications: nobody is subscribed by default.
    expect(buttons).toHaveLength(2)
  })

  it('reflects a stored preference and its urgency floor', async () => {
    db.prefRows = [{ id: 'p1', channel: 'email', is_enabled: true, min_threshold: 'due_7' }]
    render(<NotificationPreferences />)
    expect(await screen.findByRole('button', { name: /on — turn off/i })).toBeDefined()
    const select = screen.getByLabelText(/minimum urgency for email/i) as HTMLSelectElement
    expect(select.value).toBe('due_7')
  })

  it('writes no user identifier when creating a preference', async () => {
    render(<NotificationPreferences />)
    const buttons = await screen.findAllByRole('button', { name: /off — turn on/i })
    await userEvent.click(buttons[0])

    const write = db.writes.find((w) => w.op === 'insert')
    expect(write).toBeDefined()
    // RLS fills the owner. A client that could name one could write another's.
    expect(JSON.stringify(write!.payload)).not.toMatch(/app_user|user_id|clerk/i)
  })

  it('updates the existing row instead of inserting a duplicate', async () => {
    db.prefRows = [{ id: 'p1', channel: 'email', is_enabled: true, min_threshold: null }]
    render(<NotificationPreferences />)
    await userEvent.click(await screen.findByRole('button', { name: /on — turn off/i }))
    expect(db.writes.filter((w) => w.op === 'insert')).toHaveLength(0)
    expect(db.writes.filter((w) => w.op === 'update')).toHaveLength(1)
  })

  it('states that Region comes from access, not from preference', async () => {
    render(<NotificationPreferences />)
    expect(await screen.findByText(/set by\s+your access, not here/i)).toBeDefined()
  })
})
