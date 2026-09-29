import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Record editor rules (owner request 2026-09-29): the editor shows only what an admin types.
 * - Next calibration of relief valves and gas detectors is one year after the last, never typed.
 * - Date precision, serial status and the review flags are not shown; they follow the value saved.
 * - Set pressure is ONE value written to both pressure_min and pressure_max (no range).
 */

const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]> }))
vi.mock('@/hooks/useAppUser', () => ({ useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: 'admin' } }) }))

const col = (name: string, type: string, enum_values: string[] | null = null) => ({ name, type, enum_values, nullable: true })
const columns = [
  col('serial_number', 'text'), col('serial_status', 'enum', ['assigned', 'not_yet_assigned', 'unknown']),
  col('pressure_min', 'numeric'), col('pressure_max', 'numeric'), col('pressure_unit', 'enum', ['BAR', 'PSI']),
  col('last_calibration_date', 'date'), col('last_calibration_precision', 'enum', ['exact_date', 'unknown']),
  col('next_calibration_date', 'date'), col('next_calibration_precision', 'enum', ['exact_date', 'unknown']),
  col('warehouse_issue_date', 'date'), col('warehouse_issue_precision', 'enum', ['exact_date', 'unknown']),
  col('needs_review', 'boolean'), col('review_reason', 'text'), col('notes', 'text'),
]
const row = {
  id: 'v1', updated_at: '2026-09-29T00:00:00Z', serial_number: 'S-1', serial_status: 'assigned', pressure_min: 270, pressure_max: 280,
  pressure_unit: 'BAR', last_calibration_date: '2025-02-12', last_calibration_precision: 'exact_date', next_calibration_date: '2026-02-19',
  next_calibration_precision: 'exact_date', warehouse_issue_date: null, warehouse_issue_precision: 'unknown', needs_review: false,
  review_reason: null, notes: null,
}
const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    if (fn === 'cng_admin_record_for_edit') return { data: { row, columns }, error: null }
    if (fn === 'cng_admin_update_record') return { data: { ...row, ...(args.p_changes as object) }, error: null }
    return { data: null, error: null }
  }),
  from: () => { const q = { select: () => q, eq: () => q, is: () => q, order: async () => ({ data: [], error: null }) }; return q },
  storage: { from: () => ({ createSignedUrl: async () => ({ data: null }) }) },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { RecordAdminTools } = await import('@/features/record-tools/RecordAdminTools')
const { oneYearAfter, parsePressure } = await import('@/features/record-tools/recordTools')

beforeEach(() => { calls.rpc.length = 0 })
const saved = () => calls.rpc.find(([fn]) => fn === 'cng_admin_update_record')?.[1].p_changes as Record<string, unknown> | undefined

async function openEditor(table: 'warehouse_relief_valves' | 'gas_detectors' | 'storage_vessels') {
  const user = userEvent.setup()
  render(<RecordAdminTools record={{ table, id: 'v1' }} />)
  await user.click(await screen.findByRole('button', { name: /edit record/i }))
  await screen.findByLabelText('Serial number')
  return user
}

describe('record editor rules (2026-09-29)', () => {
  it('EDRULE-1 hides precision, serial status, review flags and (for an SRV) the next calibration; one Set pressure field', async () => {
    await openEditor('warehouse_relief_valves')
    for (const hidden of [/precision/i, /^serial status$/i, /^needs review$/i, /^review reason$/i, /^next calibration date$/i, /^pressure min$/i, /^pressure max$/i]) {
      expect(screen.queryByLabelText(hidden)).toBeNull()
    }
    expect((screen.getByLabelText('Set pressure') as HTMLInputElement).value).toBe('270-280')
    expect(screen.getByLabelText('Last calibration date')).toBeDefined()
    expect(screen.getByText(/one year after the last calibration/i)).toBeDefined()
  })

  it('EDRULE-2 a new last calibration sets the next one year later, both exact; the pressure is one value on both ends', async () => {
    const user = await openEditor('warehouse_relief_valves')
    const last = screen.getByLabelText('Last calibration date')
    await user.clear(last); await user.type(last, '2026-03-10')
    const pressure = screen.getByLabelText('Set pressure')
    await user.clear(pressure); await user.type(pressure, '275')
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    expect(saved()).toEqual({
      last_calibration_date: '2026-03-10', last_calibration_precision: 'exact_date',
      next_calibration_date: '2027-03-10', next_calibration_precision: 'exact_date',
      pressure_min: 275, pressure_max: 275,
    })
  })

  it('EDRULE-3 the serial status follows the serial; an untouched range is not rewritten', async () => {
    const user = await openEditor('gas_detectors')
    const serial = screen.getByLabelText('Serial number')
    await user.clear(serial)
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    expect(saved()).toEqual({ serial_number: null, serial_status: 'unknown' })
  })

  it('EDRULE-4 a pressure that is not one number is refused before anything is sent', async () => {
    const user = await openEditor('warehouse_relief_valves')
    const pressure = screen.getByLabelText('Set pressure')
    await user.clear(pressure); await user.type(pressure, '270-290')
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/one number/i)
    expect(saved()).toBeUndefined()
  })

  it('EDRULE-5 other assets keep a typed next date (only SRVs and gas detectors are annual)', async () => {
    await openEditor('storage_vessels')
    expect(screen.getByLabelText('Next calibration date')).toBeDefined()
  })

  it('EDRULE-6 one year later matches PostgreSQL (29 Feb -> 28 Feb); one pressure value only', () => {
    expect(oneYearAfter('2026-03-10')).toBe('2027-03-10')
    expect(oneYearAfter('2024-02-29')).toBe('2025-02-28')
    expect(oneYearAfter('2025-12-31')).toBe('2026-12-31')
    expect(oneYearAfter('')).toBeNull()
    expect(parsePressure('275')).toBe(275)
    expect(parsePressure('27.5')).toBe(27.5)
    expect(parsePressure(' ')).toBeNull()
    expect(parsePressure('270-280')).toBeUndefined()
  })
})
