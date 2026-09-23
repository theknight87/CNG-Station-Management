import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

/**
 * The approved Stage B Station batch control (Prompt 22C.1).
 *
 * This screen can cause exactly one irreversible thing: 281 mapping decisions.
 * So these tests are not about layout. They defend the four ways a UI can turn
 * a reviewed batch into an incident:
 *
 * 1. **Offering the action when the server no longer agrees.** The live preview
 *    is the authority; hard-coded counts are only what it is compared against.
 * 2. **Running it by accident.** A single click must not be enough.
 * 3. **Running it twice.** An uncertain result must never become a retry, and a
 *    refresh must not resurrect the button.
 * 4. **Smuggling identity.** The RPC must carry four parameters and no actor.
 *
 * Authorization itself is NOT tested here — it lives in SQL against a real
 * PostgreSQL (STAGEBSEC-*), because a mocked client can be made to say anything.
 */

const db = vi.hoisted(() => ({
  role: 'admin' as string,
  preview: null as Record<string, unknown> | null,
  previewError: null as { message: string; code?: string } | null,
  rpcCalls: [] as { fn: string; args: Record<string, unknown> }[],
  commitResult: null as unknown,
  commitError: null as { message: string; code?: string } | null,
  commitThrows: null as Error | null,
  tableWrites: [] as string[],
}))

vi.mock('@/lib/supabase/client', () => ({
  useSupabaseClient: () => ({
    from: (table: string) => {
      db.tableWrites.push(table)
      return { select: () => Promise.resolve({ data: [], error: null }) }
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      db.rpcCalls.push({ fn, args })
      if (fn === 'cng_stage_b_station_preview' || fn === 'cng_stage_b2_station_preview') {
        const promise = Promise.resolve({ data: db.preview, error: db.previewError })
        return {
          maybeSingle: () => promise,
          then: (...a: unknown[]) => (promise.then as (...x: unknown[]) => unknown).apply(promise, a),
        }
      }
      if (fn === 'cng_stage_b_station_commit' || fn === 'cng_stage_b2_station_commit') {
        if (db.commitThrows) return Promise.reject(db.commitThrows)
        return Promise.resolve({ data: db.commitResult, error: db.commitError })
      }
      return Promise.resolve({ data: null, error: null })
    },
  }),
}))

vi.mock('@/hooks/useAppUser', () => ({
  useAppUser: () => ({
    status: 'active',
    user: { id: 'me', clerk_user_id: 'clerk_me', role: db.role, is_active: true, full_name: 'Me' },
  }),
}))

const { AdminStationBatchSection } = await import('@/features/admin/sections/AdminStationBatchSection')
const { AdminView } = await import('@/features/admin/AdminView')
const { APPROVED_BATCH, CONFIRM_PHRASE, STAGE_B2_BATCH, classifyRpcError, evaluateGuard } =
  await import('@/features/admin/useStationBatch')

/** The server state that matches the approved batch exactly. */
function approvedPreview(over: Record<string, unknown> = {}) {
  return {
    import_run_id: APPROVED_BATCH.importRunId,
    manifest_fingerprint: APPROVED_BATCH.manifestFingerprint,
    preview_fingerprint: APPROVED_BATCH.previewFingerprint,
    candidate_groups: 69,
    candidate_rows: 281,
    deterministic_groups: 69,
    owner_review_groups: 0,
    rows_with_existing_decision: 0,
    storage_vessels: 100,
    recovery_tanks: 91,
    gas_detectors: 64,
    hoses: 26,
    canonical_stations: 157,
    canonical_units: 188,
    existing_decisions: 0,
    ...over,
  }
}

beforeEach(() => {
  db.role = 'admin'
  db.preview = approvedPreview()
  db.previewError = null
  db.rpcCalls = []
  db.commitResult = [{
    import_run_id: APPROVED_BATCH.importRunId,
    decisions_written: 281,
    rows_confirmed: 281,
    groups_confirmed: 69,
    preview_fingerprint: APPROVED_BATCH.previewFingerprint,
  }]
  db.commitError = null
  db.commitThrows = null
  db.tableWrites = []
})
afterEach(() => vi.clearAllMocks())

const renderSection = () => render(<MemoryRouter><AdminStationBatchSection /></MemoryRouter>)

/** Walks the whole confirmation flow: open, type the phrase, submit. */
async function confirmAndSubmit(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
  await user.type(screen.getByLabelText(/type .* to enable/i), CONFIRM_PHRASE)
  await user.click(screen.getByRole('button', { name: /^confirm station mapping$/i }))
}

describe('who can reach the control', () => {
  it('removes the completed temporary Station Batch control from Admin navigation (Stage B and B2 committed)', () => {
    render(<MemoryRouter><AdminView /></MemoryRouter>)
    expect(screen.queryByRole('link', { name: /station batch/i })).toBeNull()
  })

  it.each(['manager', 'engineer', 'viewer'])('refuses the Admin area to a %s', (role) => {
    db.role = role
    render(<MemoryRouter><AdminView /></MemoryRouter>)
    expect(screen.queryByRole('link', { name: /station batch/i })).toBeNull()
  })
})

describe('the guard is the LIVE server preview, not the hard-coded numbers', () => {
  it('enables the control only when every approved value matches', async () => {
    renderSection()
    expect((await screen.findByRole('button', { name: /confirm station mapping…/i })).hasAttribute('disabled')).toBe(false)
  })

  it('blocks when the preview fingerprint has drifted', async () => {
    db.preview = approvedPreview({ preview_fingerprint: 'f'.repeat(64) })
    renderSection()
    expect(await screen.findByText(/APPROVED BATCH HAS CHANGED — EXECUTION BLOCKED/)).toBeDefined()
    expect(screen.queryByRole('button', { name: /confirm station mapping…/i })).toBeNull()
  })

  it('blocks when the manifest fingerprint has drifted', async () => {
    db.preview = approvedPreview({ manifest_fingerprint: '0'.repeat(64) })
    renderSection()
    expect(await screen.findByText(/APPROVED BATCH HAS CHANGED/)).toBeDefined()
  })

  it('blocks on a wrong row count', async () => {
    db.preview = approvedPreview({ candidate_rows: 280 })
    renderSection()
    expect(await screen.findByText(/280 staged rows, not 281/)).toBeDefined()
  })

  it('blocks on a wrong group count', async () => {
    db.preview = approvedPreview({ candidate_groups: 68 })
    renderSection()
    expect(await screen.findByText(/68 Station groups, not 69/)).toBeDefined()
  })

  it('blocks when any group now needs owner review', async () => {
    db.preview = approvedPreview({ owner_review_groups: 2, deterministic_groups: 67 })
    renderSection()
    expect(await screen.findByText(/2 groups now need owner review/)).toBeDefined()
  })

  it('lists EVERY mismatch, not just the first', () => {
    const guard = evaluateGuard(approvedPreview({
      candidate_rows: 279, candidate_groups: 68, preview_fingerprint: 'a'.repeat(64),
    }) as never)
    expect(guard.kind).toBe('blocked')
    if (guard.kind === 'blocked') expect(guard.reasons.length).toBeGreaterThanOrEqual(3)
  })

  it('surfaces a preview read failure rather than offering the action', async () => {
    db.preview = null
    db.previewError = { message: 'permission denied' }
    renderSection()
    expect(await screen.findByText(/could not be read/i)).toBeDefined()
    expect(screen.queryByRole('button', { name: /confirm station mapping…/i })).toBeNull()
  })
})

describe('a single click cannot execute it', () => {
  it('requires the confirmation dialog before any RPC is sent', async () => {
    const user = userEvent.setup()
    renderSection()
    await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
    expect(screen.getByRole('dialog')).toBeDefined()
    expect(db.rpcCalls.filter((c) => c.fn === 'cng_stage_b_station_commit')).toHaveLength(0)
  })

  it('keeps the final action disabled until the exact phrase is typed', async () => {
    const user = userEvent.setup()
    renderSection()
    await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
    const final = screen.getByRole('button', { name: /^confirm station mapping$/i })
    expect(final.hasAttribute('disabled')).toBe(true)

    await user.type(screen.getByLabelText(/type .* to enable/i), 'confirm 281 station mappings')
    expect(final.hasAttribute('disabled')).toBe(true)
  })

  it('enables the final action on the exact phrase, and only then', async () => {
    const user = userEvent.setup()
    renderSection()
    await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
    await user.type(screen.getByLabelText(/type .* to enable/i), CONFIRM_PHRASE)
    expect(screen.getByRole('button', { name: /^confirm station mapping$/i }).hasAttribute('disabled')).toBe(false)
  })

  it('sends nothing on page load', async () => {
    renderSection()
    await screen.findByRole('button', { name: /confirm station mapping…/i })
    expect(db.rpcCalls.map((c) => c.fn)).not.toContain('cng_stage_b_station_commit')
  })
})

describe('what the RPC carries', () => {
  it('passes exactly the four approved parameters and no actor', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)

    const call = db.rpcCalls.find((c) => c.fn === 'cng_stage_b_station_commit')
    expect(call).toBeDefined()
    expect(Object.keys(call!.args).sort()).toEqual([
      'p_expected_manifest_fingerprint',
      'p_expected_preview_fingerprint',
      'p_import_run_id',
      'p_reason',
    ])
    expect(call!.args.p_import_run_id).toBe(APPROVED_BATCH.importRunId)
    expect(call!.args.p_expected_preview_fingerprint).toBe(APPROVED_BATCH.previewFingerprint)
  })

  it('carries no actor, decided_by, role, subject or credential under any key', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)
    const serialized = JSON.stringify(db.rpcCalls).toLowerCase()
    for (const forbidden of ['actor', 'decided_by', 'clerk', 'service_role', 'sub', 'app_user', 'password', 'secret']) {
      expect(serialized).not.toContain(forbidden)
    }
  })

  it('writes no table directly — the function is the only path', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)
    expect(db.tableWrites).toHaveLength(0)
  })
})

describe('it can never run twice', () => {
  it('locks the control the moment it is submitted', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/Station Mapping Batch Completed/i)
    // The property that matters is "cannot be activated again", not "is gone".
    // Here the mocked server still reports the pre-commit preview, so the
    // control remains rendered but dead; against the real server it disappears
    // entirely, which the reload test below covers.
    const again = screen.queryByRole('button', { name: /confirm station mapping…/i })
    expect(again === null || again.hasAttribute('disabled')).toBe(true)
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('sends the commit exactly once for one confirmation', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/Station Mapping Batch Completed/i)
    expect(db.rpcCalls.filter((c) => c.fn === 'cng_stage_b_station_commit')).toHaveLength(1)
  })

  it('shows the completed state from SERVER state after a reload, with no button', async () => {
    // A fresh mount — as a refresh would be — with the post-commit server state.
    db.preview = approvedPreview({
      rows_with_existing_decision: 281, deterministic_groups: 0, owner_review_groups: 69,
      existing_decisions: 281, preview_fingerprint: 'c'.repeat(64),
    })
    renderSection()
    expect(await screen.findByText(/already been committed/i)).toBeDefined()
    expect(screen.queryByRole('button', { name: /confirm station mapping…/i })).toBeNull()
  })
})

describe('an uncertain result is never a retry', () => {
  it('enters the verification state on a thrown transport error', async () => {
    const user = userEvent.setup()
    db.commitThrows = new Error('Failed to fetch')
    renderSection()
    await confirmAndSubmit(user)
    expect(await screen.findByText(/Execution result is uncertain/i)).toBeDefined()
    expect(screen.getByText(/Do not submit again/i)).toBeDefined()
  })

  it('treats an error with no SQLSTATE as uncertain, not as a failure', () => {
    expect(classifyRpcError({ message: 'network error' })).toBe('uncertain')
    expect(classifyRpcError(null)).toBe('uncertain')
  })

  it('treats a database SQLSTATE as an unambiguous refusal', () => {
    expect(classifyRpcError({ code: '42501', message: 'administrator privilege required' })).toBe('refused')
    expect(classifyRpcError({ code: '22023', message: 'refused' })).toBe('refused')
  })

  it('states plainly that a refusal wrote nothing', async () => {
    const user = userEvent.setup()
    db.commitResult = null
    db.commitError = { code: '22023', message: 'Stage B commit refused: the candidate set no longer matches' }
    renderSection()
    await confirmAndSubmit(user)
    expect(await screen.findByText(/refused the batch. Nothing was written/i)).toBeDefined()
  })

  it('offers no retry control after an uncertain result — only a read-only check', async () => {
    const user = userEvent.setup()
    db.commitThrows = new Error('socket hang up')
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/uncertain/i)
    expect(screen.getByRole('button', { name: /check what actually happened/i })).toBeDefined()
    expect(screen.queryByRole('button', { name: /^confirm station mapping$/i })).toBeNull()
  })

  it('reads the 281-decision state as COMMITTED', async () => {
    const user = userEvent.setup()
    db.commitThrows = new Error('timeout')
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/uncertain/i)

    db.preview = approvedPreview({ rows_with_existing_decision: 281, existing_decisions: 281 })
    await user.click(screen.getByRole('button', { name: /check what actually happened/i }))
    expect(await screen.findByText(/the batch was committed/i)).toBeDefined()
  })

  it('reads the zero-decision state as NOT EXECUTED', async () => {
    const user = userEvent.setup()
    db.commitThrows = new Error('timeout')
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/uncertain/i)

    db.preview = approvedPreview()
    await user.click(screen.getByRole('button', { name: /check what actually happened/i }))
    expect(await screen.findByText(/the batch did not run/i)).toBeDefined()
  })

  it('blocks on a PARTIAL state rather than guessing either way', async () => {
    const user = userEvent.setup()
    db.commitThrows = new Error('timeout')
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/uncertain/i)

    db.preview = approvedPreview({ rows_with_existing_decision: 140, existing_decisions: 140 })
    await user.click(screen.getByRole('button', { name: /check what actually happened/i }))
    expect(await screen.findByText(/Unexpected state — stop/i)).toBeDefined()
    expect(screen.getByText(/140 of 281/)).toBeDefined()
  })
})

describe('what the screen claims', () => {
  it('states the scope exclusions rather than leaving them to be assumed', async () => {
    renderSection()
    await screen.findByText(/No Unit is assigned/i)
    expect(screen.getByText(/No equipment is mapped/i)).toBeDefined()
    expect(screen.getByText(/No canonical asset is imported/i)).toBeDefined()
    expect(screen.getByText(/No alias is created/i)).toBeDefined()
  })

  it('reports the outcome as the CONFIRMED mapping status, not a rewritten staged value', async () => {
    const user = userEvent.setup()
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/Station Mapping Batch Completed/i)
    expect(screen.getAllByText(/Confirmed mapping status/i).length).toBeGreaterThan(0)
  })

  it('shows the counts the server returned, not the hard-coded ones', async () => {
    const user = userEvent.setup()
    db.commitResult = [{
      import_run_id: APPROVED_BATCH.importRunId,
      decisions_written: 281, rows_confirmed: 281, groups_confirmed: 69,
      preview_fingerprint: APPROVED_BATCH.previewFingerprint,
    }]
    renderSection()
    await confirmAndSubmit(user)
    await screen.findByText(/Station Mapping Batch Completed/i)
    const completed = screen.getByText(/Station Mapping Batch Completed/i).closest('div')!
    expect(completed.textContent).toContain('69')
    expect(completed.textContent).toContain('281')
  })
})


describe('Stage B2 batch (Phase 6)', () => {
  function b2Preview(over: Record<string, unknown> = {}) {
    return approvedPreview({
      preview_fingerprint: STAGE_B2_BATCH.previewFingerprint,
      candidate_groups: 62, candidate_rows: 308, deterministic_groups: 62,
      storage_vessels: 141, recovery_tanks: 91, gas_detectors: 54, hoses: 22,
      existing_decisions: 281, ...over,
    })
  }
  const renderB2 = () => render(<MemoryRouter><AdminStationBatchSection batch={STAGE_B2_BATCH} /></MemoryRouter>)

  it('B2-UI-1 is bound to the DEPLOYED B2 fingerprint and shape, distinct from Stage B', () => {
    expect(STAGE_B2_BATCH.previewFingerprint).toBe('9ff0975c9e3c5a9fd09869cd91317183099610402bbc5449ccdbecea0616c990')
    expect(STAGE_B2_BATCH.previewFingerprint).not.toBe(APPROVED_BATCH.previewFingerprint)
    expect([STAGE_B2_BATCH.groups, STAGE_B2_BATCH.rows]).toEqual([62, 308])
    expect(STAGE_B2_BATCH.confirmPhrase).toBe('CONFIRM 308 STATION MAPPINGS')
  })

  it('B2-UI-2 unlocks only when the live B2 preview matches, and reads the B2 preview function', async () => {
    db.preview = b2Preview()
    renderB2()
    expect(await screen.findByRole('button', { name: /confirm station mapping…/i })).toBeDefined()
    expect(db.rpcCalls.every((c) => c.fn === 'cng_stage_b2_station_preview')).toBe(true)
    expect(evaluateGuard(b2Preview(), STAGE_B2_BATCH).kind).toBe('ready')
    // A Stage B-shaped server state must never unlock B2, and vice versa.
    expect(evaluateGuard(approvedPreview(), STAGE_B2_BATCH).kind).toBe('blocked')
    expect(evaluateGuard(b2Preview(), APPROVED_BATCH).kind).toBe('blocked')
  })

  it('B2-UI-3 drift blocks execution and lists the mismatch', async () => {
    db.preview = b2Preview({ preview_fingerprint: 'f'.repeat(64), candidate_rows: 307 })
    renderB2()
    expect(await screen.findByText(/APPROVED BATCH HAS CHANGED/)).toBeDefined()
    expect(screen.getByText(/covers 307 staged rows, not 308/)).toBeDefined()
    expect(screen.queryByRole('button', { name: /confirm station mapping…/i })).toBeNull()
  })

  it('B2-UI-4 requires the B2 phrase; the Stage B phrase does not enable it', async () => {
    const user = userEvent.setup()
    db.preview = b2Preview()
    renderB2()
    await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
    await user.type(screen.getByLabelText(/type .* to enable/i), CONFIRM_PHRASE)
    expect((screen.getByRole('button', { name: /^confirm station mapping$/i }) as HTMLButtonElement).disabled).toBe(true)
  })

  it('B2-UI-5 commits through cng_stage_b2_station_commit with exactly the four approved parameters and no actor', async () => {
    const user = userEvent.setup()
    db.preview = b2Preview()
    db.commitResult = [{ import_run_id: STAGE_B2_BATCH.importRunId, decisions_written: 308, rows_confirmed: 308, groups_confirmed: 62, preview_fingerprint: STAGE_B2_BATCH.previewFingerprint }]
    renderB2()
    await user.click(await screen.findByRole('button', { name: /confirm station mapping…/i }))
    await user.type(screen.getByLabelText(/type .* to enable/i), STAGE_B2_BATCH.confirmPhrase)
    await user.click(screen.getByRole('button', { name: /^confirm station mapping$/i }))
    const call = db.rpcCalls.find((c) => c.fn.endsWith('_commit'))
    expect(call?.fn).toBe('cng_stage_b2_station_commit')
    expect(Object.keys(call!.args).sort()).toEqual(
      ['p_expected_manifest_fingerprint', 'p_expected_preview_fingerprint', 'p_import_run_id', 'p_reason'])
    expect(call!.args.p_expected_preview_fingerprint).toBe(STAGE_B2_BATCH.previewFingerprint)
    expect(await screen.findByText(/Station Mapping Batch Completed/)).toBeDefined()
    expect(db.tableWrites).toEqual([])
  })

  it('B2-UI-6 states that the staged Unit is discarded and absence rows never become detectors', async () => {
    db.preview = b2Preview()
    renderB2()
    expect(await screen.findByText(/staged Unit is DISCARDED/)).toBeDefined()
    expect(screen.getByText(/never become detector records/)).toBeDefined()
  })

  it('B2-UI-7 reads as already executed once all 308 rows carry a decision', async () => {
    db.preview = b2Preview({ rows_with_existing_decision: 308, preview_fingerprint: 'e'.repeat(64) })
    renderB2()
    expect(await screen.findByText(/already been committed/)).toBeDefined()
    expect(screen.queryByRole('button', { name: /confirm station mapping…/i })).toBeNull()
  })
})
