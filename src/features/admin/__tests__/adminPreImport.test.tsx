import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

/**
 * The Prompt 19A surfaces: the pre-import mapping queue, the completed audit
 * log, and the admin channel policy.
 *
 * These do not re-test authorization — that lives in SQL, against a real
 * PostgreSQL, because a mocked client can be made to say anything. What they
 * defend is what only the frontend can get wrong:
 *
 * 1. **A candidate is never shown as a confirmation.** The single most damaging
 *    thing this screen could do is make a 0.71 similarity score look like a fact.
 * 2. **Raw, candidate and confirmed stay three different things on screen.**
 * 3. **Every mutation is an RPC carrying the row version it saw**, and never an
 *    actor.
 * 4. **The queue is not a fixed window** — an admin working 1,104 rows must be
 *    able to reach all of them.
 * 5. **In-app is stated as mandatory, not offered as a toggle that refuses.**
 */

const db = vi.hoisted(() => ({
  queues: [] as Record<string, unknown>[],
  staged: [] as Record<string, unknown>[],
  srv: [] as Record<string, unknown>[],
  audit: [] as Record<string, unknown>[],
  policy: [] as Record<string, unknown>[],
  users: [] as Record<string, unknown>[],
  regions: [] as Record<string, unknown>[],
  stations: [] as Record<string, unknown>[],
  units: [] as Record<string, unknown>[],
  rules: [] as Record<string, unknown>[],
  rpcCalls: [] as { fn: string; args: Record<string, unknown> }[],
  tableWrites: [] as { table: string; op: string }[],
  queries: [] as { table: string; ops: string[] }[],
}))

function rowsFor(table: string) {
  switch (table) {
    case 'v_admin_data_quality': return db.queues
    case 'v_admin_staged_mapping_queue': return db.staged
    case 'v_admin_srv_mapping_queue': return db.srv
    case 'v_admin_audit_log': return db.audit
    case 'notification_channel_policy': return db.policy
    case 'v_admin_users': return db.users
    case 'regions': return db.regions
    case 'stations': return db.stations
    case 'units': return db.units
    case 'alert_rules': return db.rules
    default: return []
  }
}

const client = vi.hoisted(() => ({ value: null as unknown }))

vi.mock('@/lib/supabase/client', () => {
  client.value = {
    from: (table: string) => {
      const trace = { table, ops: [] as string[] }
      db.queries.push(trace)
      const result = Promise.resolve({ data: rowsFor(table), error: null })
      const chain: Record<string, unknown> = {
        then: (...args: unknown[]) =>
          (result.then as (...a: unknown[]) => unknown).apply(result, args),
        insert: () => { db.tableWrites.push({ table, op: 'insert' }); return Promise.resolve({ error: null }) },
        update: () => { db.tableWrites.push({ table, op: 'update' }); return { eq: () => Promise.resolve({ error: null }) } },
        delete: () => { db.tableWrites.push({ table, op: 'delete' }); return { eq: () => Promise.resolve({ error: null }) } },
      }
      for (const method of ['select', 'order', 'eq', 'is', 'limit', 'or', 'gte', 'lte', 'ilike']) {
        chain[method] = (...args: unknown[]) => {
          trace.ops.push(`${method}:${String(args[0] ?? '')}`)
          return chain
        }
      }
      return chain
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      db.rpcCalls.push({ fn, args })
      return Promise.resolve({ data: null, error: null })
    },
  }
  return { useSupabaseClient: () => client.value }
})

vi.mock('@/hooks/useAppUser', () => ({
  useAppUser: () => ({
    status: 'active',
    user: { id: 'me', clerk_user_id: 'clerk_me', role: 'admin', is_active: true, full_name: 'Me' },
  }),
}))

const { AdminDataQualitySection } = await import('@/features/admin/sections/AdminDataQualitySection')
const { AdminAuditLogSection } = await import('@/features/admin/sections/AdminAuditLogSection')
const { AdminAlertSettingsSection } = await import('@/features/admin/sections/AdminAlertSettingsSection')
const { MANDATORY_CHANNELS } = await import('@/features/admin/useChannelPolicy')

const STAGED_VESSEL = {
  staging_row_id: 'sr1',
  source_row_key: 'V.xlsx#Sheet1#11',
  import_run_id: 'run1',
  target_table: 'storage_vessels',
  outcome: 'ready_unresolved',
  staged_mapping_status: 'needs_station_mapping',
  updated_at: '2026-03-03T09:00:00Z',
  source_file: 'V.xlsx', source_sheet: 'Sheet1', source_row: 11,
  source_raw: { Station: 'ابنوب' },
  raw_region: 'EAST', raw_station: 'ابنوب', raw_location: 'Storage',
  raw_serial: 'SV-001', raw_manufacturer: 'ACME RAW', raw_model: null,
  normalized_region: 'East', serial_number: 'SV-001', manufacturer: 'ACME', model: null,
  candidate_proposals: [{ name: 'Abnub Assiut', score: 0.71 }],
  candidate_kind: 'unmatched',
  decision_id: null, confirmed_station_id: null, confirmed_station_name: null,
  confirmed_unit_id: null, confirmed_unit_name: null, confirmed_mapping_status: null,
  decided_by: null, decided_by_name: null, decided_at: null, decision_reason: null,
  source_row_hash: 'hash-1', reviewed_source_row_hash: null,
  decision_is_stale_source: false,
}

const STAGED_HOSE = {
  ...STAGED_VESSEL,
  staging_row_id: 'sr2', source_row_key: 'H.xlsx#Sheet1#4',
  target_table: 'hoses', source_file: 'H.xlsx', source_row: 4,
  candidate_proposals: null, raw_serial: 'HS-001', serial_number: 'HS-001',
}

beforeEach(() => {
  db.queues = [
    { asset: 'storage_vessels', queue: 'staged_awaiting_decision', open_count: 433 },
    { asset: 'hoses', queue: 'staged_decided', open_count: 2 },
  ]
  db.staged = [STAGED_VESSEL]
  db.srv = []
  db.audit = []
  db.policy = [
    { channel: 'email', is_enabled: true, note: null, updated_at: '2026-03-01T00:00:00Z' },
    { channel: 'in_app', is_enabled: true, note: null, updated_at: '2026-03-01T00:00:00Z' },
    { channel: 'web_push', is_enabled: false, note: null, updated_at: '2026-03-01T00:00:00Z' },
  ]
  db.users = [{ id: 'me', full_name: 'Me', email: 'me@example.test' }]
  db.regions = [{ id: 'r1', name: 'East' }]
  db.stations = [{ id: 'st1', station_name: 'TESTDATA Station' }]
  db.units = [{ id: 'un1', unit_name: 'TESTDATA Unit 1' }]
  db.rules = []
  db.rpcCalls = []
  db.tableWrites = []
  db.queries = []
})
afterEach(() => vi.clearAllMocks())

const withRouter = (ui: React.ReactElement) => <MemoryRouter>{ui}</MemoryRouter>

async function openStagedQueue(assetType = 'storage_vessels') {
  render(withRouter(<AdminDataQualitySection />))
  await userEvent.selectOptions(await screen.findByLabelText(/asset type/i), assetType)
}

describe('the pre-import mapping queue', () => {
  it('offers a per-record queue for each of the four pre-import asset types', async () => {
    render(withRouter(<AdminDataQualitySection />))
    const select = await screen.findByLabelText(/asset type/i)
    const values = within(select).getAllByRole('option').map((o) => (o as HTMLOptionElement).value)
    expect(values).toEqual(['', 'storage_vessels', 'recovery_tanks', 'gas_detectors', 'hoses'])
  })

  it('shows the raw source evidence, unchanged', async () => {
    await openStagedQueue()
    expect(await screen.findByText('ابنوب')).toBeDefined()
    expect(screen.getByText('EAST')).toBeDefined()
    expect(screen.getByText('Storage')).toBeDefined()
    expect(screen.getByText(/V\.xlsx.*Sheet1.*11/)).toBeDefined()
  })

  it('labels an automated candidate as a SUGGESTION and never as a mapping', async () => {
    await openStagedQueue()
    const suggestion = await screen.findByText(/suggested: abnub assiut/i)
    expect(suggestion).toBeDefined()
    // ...and the confirmed column says, in its own words, that nothing is decided.
    expect(screen.getByText('Not decided')).toBeDefined()
    expect(screen.getByText(/confirms nothing and is not applied/i)).toBeDefined()
  })

  it('records a decision through the RPC, carrying the version it saw and no actor', async () => {
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^decide staged row/i }))
    await userEvent.selectOptions(await screen.findByLabelText(/confirmed station/i), 'st1')
    await userEvent.click(screen.getByRole('button', { name: /record decision/i }))

    expect(db.tableWrites).toEqual([])
    expect(db.rpcCalls).toHaveLength(1)
    expect(db.rpcCalls[0].fn).toBe('cng_admin_decide_staged_mapping')
    const args = db.rpcCalls[0].args
    expect(args.p_staging_row_id).toBe('sr1')
    expect(args.p_station_id).toBe('st1')
    // Station confirmed, Unit genuinely not: sent as NULL, not as a guess.
    expect(args.p_unit_id).toBeNull()
    // `decided_at` was null (no decision yet) — the guard that makes a duplicate
    // decision fail rather than silently replacing one.
    expect(args.p_expected_decision_at).toBeNull()
    // The resulting status is derived in SQL and is not ours to assert.
    expect(Object.keys(args)).not.toContain('p_mapping_status')
    for (const key of Object.keys(args)) {
      expect(key).not.toMatch(/actor|clerk|caller|as_user|acting/i)
    }
  })

  it('cannot submit a decision without a Station', async () => {
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^decide staged row/i }))
    const submit = screen.getByRole('button', { name: /record decision/i })
    expect((submit as HTMLButtonElement).disabled).toBe(true)
  })

  it('offers a Unit only once a Station is confirmed', async () => {
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^decide staged row/i }))
    const unit = await screen.findByLabelText(/confirmed unit/i)
    expect((unit as HTMLSelectElement).disabled).toBe(true)
    await userEvent.selectOptions(screen.getByLabelText(/confirmed station/i), 'st1')
    expect((screen.getByLabelText(/confirmed unit/i) as HTMLSelectElement).disabled).toBe(false)
  })

  it('states that Station-only is a valid end state for a hose', async () => {
    db.staged = [STAGED_HOSE]
    await openStagedQueue('hoses')
    await userEvent.click(await screen.findByRole('button', { name: /^decide staged row/i }))
    expect(screen.getByText(/the Unit is optional for a hose/i)).toBeDefined()
  })

  it('shows a confirmed decision as confirmed, with who made it', async () => {
    db.staged = [{
      ...STAGED_VESSEL,
      decision_id: 'd1', confirmed_station_id: 'st1', confirmed_station_name: 'TESTDATA Station',
      confirmed_unit_id: 'un1', confirmed_unit_name: 'TESTDATA Unit 1',
      confirmed_mapping_status: 'resolved',
      decided_by: 'me', decided_by_name: 'Me', decided_at: '2026-03-04T09:00:00Z',
    }]
    await openStagedQueue()
    expect(await screen.findByText('Station + Unit')).toBeDefined()
    expect(screen.getByText(/TESTDATA Station · TESTDATA Unit 1/)).toBeDefined()
    expect(screen.getByText(/by Me/)).toBeDefined()
  })

  it('sends the existing decision version when replacing one', async () => {
    db.staged = [{
      ...STAGED_VESSEL,
      decision_id: 'd1', confirmed_station_id: 'st1', confirmed_station_name: 'TESTDATA Station',
      confirmed_mapping_status: 'needs_unit_mapping',
      decided_by: 'me', decided_by_name: 'Me', decided_at: '2026-03-04T09:00:00Z',
    }]
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^change decision for staged row/i }))
    await userEvent.click(screen.getByRole('button', { name: /replace decision/i }))
    expect(db.rpcCalls[0].args.p_expected_decision_at).toBe('2026-03-04T09:00:00Z')
  })

  it('filters by mapping status, Region and Station, and is not a fixed window', async () => {
    render(withRouter(<AdminDataQualitySection />))
    await userEvent.selectOptions(await screen.findByLabelText(/asset type/i), 'gas_detectors')
    await userEvent.selectOptions(screen.getByLabelText(/mapping status/i), 'needs_station_mapping')
    await userEvent.selectOptions(screen.getByLabelText(/region/i), 'East')
    await userEvent.type(screen.getByLabelText(/station search/i), 'abn')

    const staged = db.queries.filter((q) => q.table === 'v_admin_staged_mapping_queue')
    const last = staged[staged.length - 1]
    expect(last.ops.join(' ')).toMatch(/eq:target_table/)
    expect(last.ops.join(' ')).toMatch(/eq:staged_mapping_status/)
    expect(last.ops.join(' ')).toMatch(/eq:normalized_region/)
    expect(last.ops.join(' ')).toMatch(/ilike:raw_station/)
    // Paging is bounded per request, not capped: the limit grows on Load more.
    expect(last.ops.some((o) => o.startsWith('limit:'))).toBe(true)
  })

  it('offers Load more when another page exists', async () => {
    db.staged = Array.from({ length: 51 }, (_, i) => ({
      ...STAGED_VESSEL, staging_row_id: `sr${i}`, source_row_key: `V.xlsx#Sheet1#${i}`,
    }))
    await openStagedQueue()
    expect(await screen.findByRole('button', { name: /load more/i })).toBeDefined()
  })

  it('says so plainly when the queue is complete, rather than implying more', async () => {
    await openStagedQueue()
    expect(await screen.findByText(/this is the whole queue under these filters/i)).toBeDefined()
    expect(screen.queryByRole('button', { name: /load more/i })).toBeNull()
  })

  it('shows the live queue counts and hard-codes none of them', async () => {
    render(withRouter(<AdminDataQualitySection />))
    // 433 here comes from the mocked DATA, which is the point: the same figure
    // typed into a component would fail the source scan in adminModule.test.tsx.
    expect(await screen.findByText('433')).toBeDefined()
  })
})

describe('the audit log', () => {
  const ENTRY = {
    id: 'a1', action: 'user_role_changed', entity_table: 'app_users', entity_id: 'u2',
    actor_id: 'me', actor_label: 'Me', summary: 'engineer -> manager',
    before_data: { role: 'engineer' }, after_data: { role: 'manager' },
    occurred_at: '2026-03-03T09:00:00Z',
  }

  it('renders actor, timestamp, action, entity type and entity id', async () => {
    db.audit = [ENTRY]
    render(withRouter(<AdminAuditLogSection />))
    const table = await screen.findByRole('table')
    // Scoped to the table: 'Me' is also an option in the actor filter, and a
    // bare text query would not tell the two apart.
    expect(within(table).getByText('Me')).toBeDefined()
    expect(screen.getByText('2026-03-03 09:00:00')).toBeDefined()
    expect(screen.getByText('user_role_changed')).toBeDefined()
    expect(screen.getByText('app_users')).toBeDefined()
    expect(screen.getByText('u2')).toBeDefined()
  })

  it('shows the before and after values on request', async () => {
    db.audit = [ENTRY]
    render(withRouter(<AdminAuditLogSection />))
    await userEvent.click(await screen.findByRole('button', { name: /show before and after/i }))
    expect(screen.getByText('Before')).toBeDefined()
    expect(screen.getByText('After')).toBeDefined()
    expect(screen.getByText(/"role": "engineer"/)).toBeDefined()
    expect(screen.getByText(/"role": "manager"/)).toBeDefined()
  })

  it('states an absent before value as a fact rather than a placeholder', async () => {
    db.audit = [{ ...ENTRY, before_data: null }]
    render(withRouter(<AdminAuditLogSection />))
    await userEvent.click(await screen.findByRole('button', { name: /show before and after/i }))
    expect(screen.getByText(/this record was created/i)).toBeDefined()
  })

  it('applies the date range, actor, action and entity filters to the query', async () => {
    db.audit = [ENTRY]
    render(withRouter(<AdminAuditLogSection />))
    await screen.findByRole('table')
    await userEvent.type(screen.getByLabelText(/^from$/i), '2026-03-01')
    await userEvent.type(screen.getByLabelText(/^to$/i), '2026-03-31')
    await userEvent.selectOptions(screen.getByLabelText(/^actor$/i), 'me')
    await userEvent.selectOptions(screen.getByLabelText(/^action$/i), 'user_role_changed')
    await userEvent.selectOptions(screen.getByLabelText(/record type/i), 'app_users')

    const audits = db.queries.filter((q) => q.table === 'v_admin_audit_log')
    const ops = audits[audits.length - 1].ops.join(' ')
    expect(ops).toMatch(/gte:occurred_at/)
    expect(ops).toMatch(/lte:occurred_at/)
    expect(ops).toMatch(/eq:actor_id/)
    expect(ops).toMatch(/eq:action/)
    expect(ops).toMatch(/eq:entity_table/)
  })

  it('offers no way to edit or delete history', async () => {
    db.audit = [ENTRY]
    render(withRouter(<AdminAuditLogSection />))
    await screen.findByRole('table')
    expect(screen.queryByRole('button', { name: /delete|remove|edit/i })).toBeNull()
    expect(db.tableWrites).toEqual([])
  })
})

describe('admin channel policy', () => {
  it('is presented as an organization question, separate from user opt-in', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    expect(await screen.findByText(/Delivery channels/)).toBeDefined()
    expect(screen.getByText(/This is not a user preference/i)).toBeDefined()
    expect(screen.getByText(/disabling a channel here changes nobody's preference/i)).toBeDefined()
  })

  it('disables a channel through the RPC with the row version, writing no preference', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    await userEvent.click(await screen.findByRole('button', { name: /disable email delivery/i }))
    expect(db.rpcCalls[0].fn).toBe('cng_admin_set_channel_policy')
    expect(db.rpcCalls[0].args.p_channel).toBe('email')
    expect(db.rpcCalls[0].args.p_is_enabled).toBe(false)
    expect(db.rpcCalls[0].args.p_expected_updated_at).toBe('2026-03-01T00:00:00Z')
    // The distinction the whole design rests on: no preference row is touched.
    expect(db.tableWrites).toEqual([])
    expect(db.queries.some((q) => q.table === 'notification_preferences')).toBe(false)
  })

  it('states that in-app is mandatory instead of offering a toggle that refuses', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    expect(await screen.findByText(/cannot be disabled — it is the alert read surface/i)).toBeDefined()
    expect(screen.queryByRole('button', { name: /disable in-app/i })).toBeNull()
    expect(MANDATORY_CHANNELS).toContain('in_app')
  })

  it('shows a disabled channel as suppressed for everyone, not as unsubscribed', async () => {
    render(withRouter(<AdminAlertSettingsSection />))
    const enable = await screen.findByRole('button', { name: /enable web push delivery/i })
    expect(enable).toBeDefined()
    expect(screen.getByText('Disabled')).toBeDefined()
  })
})


/**
 * Prompt 19B — a decision whose source evidence has changed.
 *
 * The screen must say WHY a previous ruling stopped counting. Showing it as
 * confirmed would apply a decision about different evidence; showing nothing
 * would leave an administrator re-deciding a row with no idea what happened to
 * their earlier answer.
 */
describe('a stale-source decision in the queue', () => {
  const STALE = {
    ...STAGED_VESSEL,
    source_row_hash: 'hash-2',
    reviewed_source_row_hash: 'hash-1',
    decision_is_stale_source: true,
    decision_id: 'd1',
    confirmed_station_id: 'st-old', confirmed_station_name: 'OLD Station',
    confirmed_unit_id: 'un-old', confirmed_unit_name: 'OLD Unit',
    confirmed_mapping_status: 'resolved',
    decided_by: 'me', decided_by_name: 'Me', decided_at: '2026-03-04T09:00:00Z',
  }

  it('states that the previous decision requires re-review, and why', async () => {
    db.staged = [STALE]
    await openStagedQueue()
    expect(await screen.findByText(
      /previous decision requires re-review because source evidence changed/i,
    )).toBeDefined()
  })

  it('does not present it as confirmed', async () => {
    db.staged = [STALE]
    await openStagedQueue()
    expect(screen.getByText('Needs re-review')).toBeDefined()
    expect(screen.queryByText('Station + Unit')).toBeNull()
    expect(screen.queryByText('Station only')).toBeNull()
    // The old answer is visible as context, explicitly marked as not applied.
    expect(screen.getByText(/which is not applied/i)).toBeDefined()
  })

  it('offers re-review rather than a change to an answer that still stands', async () => {
    db.staged = [STALE]
    await openStagedQueue()
    expect(await screen.findByRole('button', { name: /^re-review staged row/i })).toBeDefined()
    expect(screen.queryByRole('button', { name: /^change decision for/i })).toBeNull()
  })

  it('pre-fills nothing, so the old answer cannot be clicked through', async () => {
    db.staged = [STALE]
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^re-review staged row/i }))
    expect((screen.getByLabelText(/confirmed station/i) as HTMLSelectElement).value).toBe('')
    expect((screen.getByLabelText(/confirmed unit/i) as HTMLSelectElement).value).toBe('')
    // ...and nothing can be submitted until a Station is chosen afresh.
    expect((screen.getByRole('button', { name: /record re-reviewed decision/i }) as HTMLButtonElement)
      .disabled).toBe(true)
  })

  it('records the re-review through the normal audited path, carrying the old version', async () => {
    db.staged = [STALE]
    await openStagedQueue()
    await userEvent.click(await screen.findByRole('button', { name: /^re-review staged row/i }))
    await userEvent.selectOptions(screen.getByLabelText(/confirmed station/i), 'st1')
    await userEvent.click(screen.getByRole('button', { name: /record re-reviewed decision/i }))

    expect(db.rpcCalls).toHaveLength(1)
    expect(db.rpcCalls[0].fn).toBe('cng_admin_decide_staged_mapping')
    expect(db.rpcCalls[0].args.p_station_id).toBe('st1')
    // Supersedes the earlier ruling rather than creating a second active one.
    expect(db.rpcCalls[0].args.p_expected_decision_at).toBe('2026-03-04T09:00:00Z')
    // The hash is never sent: the database reads it from the staging row.
    for (const key of Object.keys(db.rpcCalls[0].args)) {
      expect(key).not.toMatch(/hash/i)
    }
  })
})
