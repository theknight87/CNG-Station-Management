import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

/**
 * The Admin workspace.
 *
 * These do not re-test the authorization rules — those live in SQL and are
 * asserted against a real PostgreSQL in `supabase/tests/rls_authorization.sql`,
 * because a mocked client can be made to say anything. What they defend is the
 * part that is genuinely the frontend's responsibility:
 *
 * 1. **Privileged mutation goes through an RPC, never a table write.** A direct
 *    `from('app_users').update(...)` would be refused in production; a test that
 *    tolerates it here would let that regression reach a browser.
 * 2. **The client never sends an actor.** Attribution is derived server-side, so
 *    no request may carry an actor id or a role claim.
 * 3. **Concurrency is carried.** Every mutation sends the row version it was
 *    decided against, so a stale write is refused rather than applied silently.
 * 4. **Counts come from data.** No queue figure is typed into the UI.
 * 5. **A refusal is reported as a refusal**, and never as a failure to load —
 *    the Prompt 18A misdiagnosis in miniature.
 * 6. **A non-admin reaches a permission state**, not a blank screen.
 */

const db = vi.hoisted(() => ({
  role: 'admin' as string,
  users: [] as Record<string, unknown>[],
  regions: [] as Record<string, unknown>[],
  rules: [] as Record<string, unknown>[],
  queues: [] as Record<string, unknown>[],
  srvQueue: [] as Record<string, unknown>[],
  audit: [] as Record<string, unknown>[],
  stations: [] as Record<string, unknown>[],
  units: [] as Record<string, unknown>[],
  compressors: [] as Record<string, unknown>[],
  selectError: null as null | { message: string },
  rpcError: null as null | { message: string },
  rpcCalls: [] as { fn: string; args: Record<string, unknown> }[],
  tableWrites: [] as { table: string; op: string }[],
}))

function rowsFor(table: string) {
  switch (table) {
    case 'v_admin_users': return db.users
    case 'regions': return db.regions
    case 'alert_rules': return db.rules
    case 'v_admin_data_quality': return db.queues
    case 'v_admin_srv_mapping_queue': return db.srvQueue
    case 'v_admin_audit_log': return db.audit
    case 'stations': return db.stations
    case 'units': return db.units
    case 'compressors': return db.compressors
    default: return []
  }
}

// The real `useSupabaseClient` returns a module-level SINGLETON, so the mock is
// a stable object too. A fresh object per render would re-fire every effect that
// depends on the client and spin the component forever — a defect in the test,
// not in the code under test.
const client = vi.hoisted(() => ({ value: null as unknown }))

vi.mock('@/lib/supabase/client', () => {
  client.value = {
    from: (table: string) => {
      const result = Promise.resolve({
        data: db.selectError ? null : rowsFor(table),
        error: db.selectError,
      })
      // Every terminal call resolves to the same result, so the chain order in
      // the hooks is free to change without rewriting this mock.
      const chain: Record<string, unknown> = {
        then: (...args: unknown[]) =>
          (result.then as (...a: unknown[]) => unknown).apply(result, args),
        insert: () => { db.tableWrites.push({ table, op: 'insert' }); return Promise.resolve({ error: null }) },
        update: () => { db.tableWrites.push({ table, op: 'update' }); return { eq: () => Promise.resolve({ error: null }) } },
        delete: () => { db.tableWrites.push({ table, op: 'delete' }); return { eq: () => Promise.resolve({ error: null }) } },
      }
      for (const method of ['select', 'order', 'eq', 'is', 'limit']) {
        chain[method] = () => chain
      }
      return chain
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      db.rpcCalls.push({ fn, args })
      return Promise.resolve({ data: null, error: db.rpcError })
    },
  }
  return { useSupabaseClient: () => client.value }
})

vi.mock('@/hooks/useAppUser', () => ({
  useAppUser: () => ({
    status: 'active',
    user: { id: 'me', clerk_user_id: 'clerk_me', role: db.role, is_active: true, full_name: 'Me' },
  }),
}))

const { AdminView } = await import('@/features/admin/AdminView')
const { AdminUsersSection } = await import('@/features/admin/sections/AdminUsersSection')
const { AdminAlertSettingsSection } = await import('@/features/admin/sections/AdminAlertSettingsSection')
const { AdminDataQualitySection } = await import('@/features/admin/sections/AdminDataQualitySection')
const { AdminAuditLogSection } = await import('@/features/admin/sections/AdminAuditLogSection')
const { describeAdminError } = await import('@/features/admin/useAdminUsers')
const { describeMappingError } = await import('@/features/admin/useAdminDataQuality')

const OTHER_USER = {
  id: 'u2', clerk_user_id: 'clerk_other', email: 'other@example.test',
  full_name: 'Other Engineer', role: 'engineer', is_active: true,
  created_at: '2026-01-01T00:00:00Z', updated_at: '2026-02-02T10:00:00Z',
  region_grants: [{ region_id: 'r1', region_name: 'East', can_map: true }],
}

beforeEach(() => {
  db.role = 'admin'
  db.users = [OTHER_USER]
  db.regions = [{ id: 'r1', name: 'East' }, { id: 'r2', name: 'West' }]
  db.rules = [{
    id: 'rule1', subject: 'srv_calibration', threshold: 'due_30',
    days_before: 30, is_enabled: true, updated_at: '2026-02-02T10:00:00Z',
  }]
  db.queues = [{ asset: 'installed_relief_valve', queue: 'needs_station_mapping', open_count: 217 }]
  db.srvQueue = []
  db.audit = []
  db.stations = [{ id: 'st1', station_name: 'TESTDATA Station' }]
  db.units = [{ id: 'un1', unit_name: 'TESTDATA Unit 1' }]
  db.compressors = [{ id: 'cp1', serial_number: 'CMP-001' }]
  db.selectError = null
  db.rpcError = null
  db.rpcCalls = []
  db.tableWrites = []
})
afterEach(() => vi.clearAllMocks())

const withRouter = (ui: React.ReactElement) => <MemoryRouter>{ui}</MemoryRouter>

describe('the Admin workspace shell', () => {
  it('shows a non-admin a permission state rather than an empty screen', async () => {
    db.role = 'engineer'
    render(withRouter(<AdminView />))
    expect(await screen.findByText(/restricted to administrators/i)).toBeDefined()
    expect(screen.queryByRole('navigation', { name: /admin sections/i })).toBeNull()
  })

  it('offers the admin sections as links, so each one is deep-linkable', async () => {
    render(withRouter(<AdminView />))
    const nav = await screen.findByRole('navigation', { name: /admin sections/i })
    expect(nav).toBeDefined()
    for (const label of ['Users', 'Alert Settings', 'Data Quality', 'Audit Log']) {
      expect(screen.getByRole('link', { name: label })).toBeDefined()
    }
  })
})

describe('user administration', () => {
  it('changes a role through the audited RPC, never a table write', async () => {
    render(withRouter(<AdminUsersSection />))
    const select = await screen.findByLabelText(/role for other engineer/i)
    await userEvent.selectOptions(select, 'manager')

    expect(db.tableWrites).toEqual([])
    expect(db.rpcCalls).toHaveLength(1)
    expect(db.rpcCalls[0].fn).toBe('cng_admin_set_user_role')
  })

  it('never sends an actor or a role claim of its own', async () => {
    render(withRouter(<AdminUsersSection />))
    await userEvent.selectOptions(await screen.findByLabelText(/role for other engineer/i), 'viewer')
    const args = db.rpcCalls[0].args
    // Attribution is derived from the verified Clerk subject inside the
    // function. Anything the client could send here would be forgeable.
    for (const key of Object.keys(args)) {
      expect(key).not.toMatch(/actor|clerk|caller|as_user|acting/i)
    }
  })

  it('carries the row version it decided against, so a stale write is refused', async () => {
    render(withRouter(<AdminUsersSection />))
    await userEvent.selectOptions(await screen.findByLabelText(/role for other engineer/i), 'viewer')
    expect(db.rpcCalls[0].args.p_expected_updated_at).toBe(OTHER_USER.updated_at)

    await userEvent.click(await screen.findByRole('button', { name: /deactivate other engineer/i }))
    expect(db.rpcCalls[1].fn).toBe('cng_admin_set_user_active')
    expect(db.rpcCalls[1].args.p_expected_updated_at).toBe(OTHER_USER.updated_at)
  })

  it('revokes a Region through the RPC as well', async () => {
    render(withRouter(<AdminUsersSection />))
    await userEvent.click(await screen.findByRole('button', { name: /revoke east from other engineer/i }))
    expect(db.tableWrites).toEqual([])
    expect(db.rpcCalls[0].fn).toBe('cng_admin_revoke_region')
  })

  it('reports a refused change as a refusal, not as a screen that failed to load', async () => {
    db.rpcError = { message: 'permission denied for function cng_admin_set_user_role' }
    render(withRouter(<AdminUsersSection />))
    await userEvent.selectOptions(await screen.findByLabelText(/role for other engineer/i), 'admin')
    expect(await screen.findByText(/that change was refused/i)).toBeDefined()
    // The list is still on screen: one write failed, the page did not.
    expect(screen.getByLabelText(/role for other engineer/i)).toBeDefined()
  })

  it('explains a stale write in terms an administrator can act on', () => {
    expect(describeAdminError('stale_write: the row changed')).toMatch(/reload/i)
    expect(describeAdminError('cannot demote the last active administrator'))
      .toMatch(/no active administrator/i)
  })
})

describe('alert settings', () => {
  it('toggles only the active state, through the RPC, with the row version', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    await userEvent.click(await screen.findByRole('button', { name: /disable srv_calibration due_30/i }))
    expect(db.tableWrites).toEqual([])
    expect(db.rpcCalls[0].fn).toBe('cng_admin_set_alert_rule_enabled')
    expect(db.rpcCalls[0].args.p_is_enabled).toBe(false)
    expect(db.rpcCalls[0].args.p_expected_updated_at).toBe('2026-02-02T10:00:00Z')
  })

  it('offers no control that would edit a rule threshold or its window', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    await screen.findByRole('button', { name: /disable/i })
    // The identity columns are DISPLAYED, never editable: changing them would
    // reinterpret alerts that were already raised.
    expect(screen.queryByRole('textbox')).toBeNull()
    expect(screen.queryByRole('spinbutton')).toBeNull()
    expect(screen.queryByRole('combobox')).toBeNull()
  })
})

describe('data quality', () => {
  it('shows the queue count that came from the data', async () => {
    render(withRouter(<AdminDataQualitySection />))
    expect(await screen.findByText('217')).toBeDefined()
  })

  it('states a genuine zero rather than hiding an empty queue behind a figure', async () => {
    db.queues = [{ asset: 'hose', queue: 'unresolved', open_count: 0 }]
    render(withRouter(<AdminDataQualitySection />))
    expect(await screen.findByText(/no open data-quality queues/i)).toBeDefined()
  })

  it('hard-codes no count anywhere in the module', async () => {
    const { readFileSync, readdirSync } = await import('node:fs')
    const dir = 'src/features/admin'
    const files = readdirSync(dir, { recursive: true }) as string[]
    // The tests themselves legitimately mention the historical figures in
    // describing what must not be shipped, so only shipped source is scanned.
    const shipped = files.filter((f) => /\.tsx?$/.test(f) && !f.includes('__tests__'))
    expect(shipped.length).toBeGreaterThan(0)
    for (const file of shipped) {
      const source = readFileSync(`${dir}/${file}`, 'utf8')
      // 1104 and its component figures are a PIPELINE fact about a dry run.
      // Typing one into a screen would make the UI lie the moment a record is
      // resolved.
      expect(source).not.toMatch(/\b(1104|1,104|433|403|219|49)\b/)
    }
  })

  it('offers the mapping decision one level at a time, and sends no status', async () => {
    db.srvQueue = [{
      id: 'srv1', mapping_status: 'needs_station_mapping', updated_at: '2026-03-03T09:00:00Z',
      region_id: null, region_name: null, station_id: null, station_name: null,
      unit_id: null, unit_name: null,
      source_station_name_raw: 'ابنوب', source_region_raw: 'East',
      serial_number: null, serial_number_raw: 'SS-4R3A', serial_status: 'unknown',
      part_number: null, manufacturer: null, manufacturer_raw: null, set_pressure_raw: null,
      expected_parent_kind: 'compressor',
      source_file: 'SRV.xlsx', source_sheet: 'Sheet1', source_row: 42,
    }]
    render(withRouter(<AdminDataQualitySection />))
    await userEvent.click(await screen.findByRole('button', { name: /^resolve relief valve/i }))

    // Unit and equipment are unreachable until the level above is confirmed.
    expect((await screen.findByLabelText(/^unit$/i)).hasAttribute('disabled')).toBe(true)
    expect(screen.getByLabelText(/parent kind/i).hasAttribute('disabled')).toBe(true)

    await userEvent.selectOptions(screen.getByLabelText('Station'), 'st1')
    await userEvent.click(screen.getByRole('button', { name: /record decision/i }))

    expect(db.rpcCalls[0].fn).toBe('cng_admin_map_srv')
    const args = db.rpcCalls[0].args
    expect(args.p_station_id).toBe('st1')
    expect(args.p_unit_id).toBeNull()
    expect(args.p_parent_id).toBeNull()
    expect(args.p_expected_updated_at).toBe('2026-03-03T09:00:00Z')
    // The status is DERIVED in SQL. A client that could assert it could declare
    // a record resolved without proving anything.
    expect(Object.keys(args)).not.toContain('p_mapping_status')
  })

  it('preserves the raw source evidence on screen beside the confirmed value', async () => {
    db.srvQueue = [{
      id: 'srv1', mapping_status: 'needs_station_mapping', updated_at: '2026-03-03T09:00:00Z',
      region_id: null, region_name: null, station_id: null, station_name: null,
      unit_id: null, unit_name: null,
      source_station_name_raw: 'ابنوب', source_region_raw: 'East',
      serial_number: null, serial_number_raw: 'SS-4R3A', serial_status: 'unknown',
      part_number: null, manufacturer: null, manufacturer_raw: null, set_pressure_raw: null,
      expected_parent_kind: 'compressor',
      source_file: 'SRV.xlsx', source_sheet: 'Sheet1', source_row: 42,
    }]
    render(withRouter(<AdminDataQualitySection />))
    expect(await screen.findByText('ابنوب')).toBeDefined()
    expect(screen.getByText('SS-4R3A')).toBeDefined()
    expect(screen.getByText(/SRV\.xlsx/)).toBeDefined()
  })

  it('translates a hierarchy refusal without softening it into a suggestion', () => {
    expect(describeMappingError('violates foreign key constraint "irv_unit_station_fk"'))
      .toMatch(/does not belong to the confirmed Station/i)
    expect(describeMappingError('violates foreign key constraint "irv_compressor_unit_fk"'))
      .toMatch(/does not belong to the confirmed Unit/i)
  })
})

describe('the audit log', () => {
  it('offers no way to edit or delete history', async () => {
    db.audit = [{
      id: 'a1', action: 'user_role_changed', entity_table: 'app_users', entity_id: 'u2',
      actor_id: 'me', actor_label: 'Me', summary: 'engineer -> manager',
      occurred_at: '2026-03-03T09:00:00Z',
    }]
    render(withRouter(<AdminAuditLogSection />))
    expect(await screen.findByText('engineer -> manager')).toBeDefined()
    expect(screen.queryByRole('button', { name: /delete|edit|remove/i })).toBeNull()
  })

  it('states an empty filter result rather than leaving the table blank', async () => {
    db.audit = []
    render(withRouter(<AdminAuditLogSection />))
    expect(await screen.findByText(/no audit entries match/i)).toBeDefined()
  })
})
