import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { beforeEach, describe, expect, it, vi } from 'vitest'

const state = vi.hoisted(() => ({ role: 'admin' as string, photos: [] as unknown[], rpcError: null as null | { code: string; message: string } }))
const calls = vi.hoisted(() => ({ rpc: [] as Array<[string, Record<string, unknown>]>, upload: [] as unknown[] }))

vi.mock('@/hooks/useAppUser', () => ({
  useOptionalAppUser: () => ({ status: 'active', user: { id: 'u1', role: state.role } }),
}))

const row = {
  id: 'r1', updated_at: '2026-09-23T10:00:00+00:00', serial_number: 'S-1', notes: null,
  pressure_min: 300, pressure_unit: 'BAR', next_calibration_date: null, next_calibration_precision: 'unknown',
}
const columns = [
  { name: 'serial_number', type: 'text', enum_values: null, nullable: true },
  { name: 'notes', type: 'text', enum_values: null, nullable: true },
  { name: 'pressure_min', type: 'numeric', enum_values: null, nullable: true },
  { name: 'pressure_unit', type: 'enum', enum_values: ['BAR', 'PSI'], nullable: true },
  { name: 'next_calibration_date', type: 'date', enum_values: null, nullable: true },
  { name: 'next_calibration_precision', type: 'enum', enum_values: ['exact_date', 'year_only', 'unknown', 'invalid'], nullable: false },
]

const client = {
  rpc: vi.fn(async (fn: string, args: Record<string, unknown>) => {
    calls.rpc.push([fn, args])
    if (fn === 'cng_admin_record_for_edit') return { data: { row, columns }, error: null }
    if (fn === 'cng_admin_update_record') return state.rpcError ? { data: null, error: state.rpcError } : { data: { ...row, ...(args.p_changes as object) }, error: null }
    return { data: 'p1', error: null }
  }),
  from: () => {
    const q = { select: () => q, eq: () => q, is: () => q, order: async () => ({ data: state.photos, error: null }) }
    return q
  },
  storage: {
    from: () => ({
      createSignedUrl: async (path: string) => ({ data: { signedUrl: `https://x/${path}` } }),
      upload: async (...a: unknown[]) => { calls.upload.push(a); return { error: null } },
    }),
  },
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => client }))

const { RecordAdminTools } = await import('@/features/record-tools/RecordAdminTools')
const { toValue } = await import('@/features/record-tools/recordTools')

beforeEach(() => {
  state.role = 'admin'; state.photos = []; state.rpcError = null
  calls.rpc.length = 0; calls.upload.length = 0
})

describe('admin record tools', () => {
  it('ADMINUI-1 a non-admin sees photos but no Edit or Add photo control', async () => {
    state.role = 'engineer'
    state.photos = [{ id: 'p1', storage_path: 'hoses/r1/a.jpg', caption: 'Nameplate', uploaded_at: 'x' }]
    render(<RecordAdminTools record={{ table: 'hoses', id: 'r1' }} />)
    expect(await screen.findByAltText('Nameplate')).toBeDefined()
    expect(screen.queryByRole('button', { name: /edit record/i })).toBeNull()
    expect(screen.queryByText(/add photo/i)).toBeNull()
    expect(screen.queryByRole('button', { name: /remove photo/i })).toBeNull()
  })

  it('ADMINUI-2 admin saves ONLY the changed fields with the version read, and a typed date becomes exact', async () => {
    const user = userEvent.setup()
    render(<RecordAdminTools record={{ table: 'installed_relief_valves', id: 'r1' }} />)
    await user.click(await screen.findByRole('button', { name: /edit record/i }))
    const serial = await screen.findByLabelText('Serial number')
    await user.clear(serial); await user.type(serial, 'S-2')
    const date = screen.getByLabelText('Next calibration date')
    await user.type(date, '2027-01-31')
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    const save = calls.rpc.find(([fn]) => fn === 'cng_admin_update_record')!
    expect(save[1]).toEqual({
      p_table: 'installed_relief_valves', p_id: 'r1', p_expected_updated_at: row.updated_at,
      p_changes: { serial_number: 'S-2', next_calibration_date: '2027-01-31', next_calibration_precision: 'exact_date' },
    })
    expect(await screen.findByText(/in the audit log/i)).toBeDefined()
  })

  it('ADMINUI-3 the payload never carries an actor or identity', async () => {
    const user = userEvent.setup()
    render(<RecordAdminTools record={{ table: 'hoses', id: 'r1' }} />)
    await user.click(await screen.findByRole('button', { name: /edit record/i }))
    await user.type(await screen.findByLabelText('Notes'), 'checked')
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    const text = JSON.stringify(calls.rpc)
    for (const k of ['actor', 'decided_by', 'app_user', 'service_role', 'password']) expect(text).not.toContain(k)
  })

  it('ADMINUI-4 a stale version is explained, not retried', async () => {
    const user = userEvent.setup()
    state.rpcError = { code: 'PT409', message: 'changed' }
    render(<RecordAdminTools record={{ table: 'hoses', id: 'r1' }} />)
    await user.click(await screen.findByRole('button', { name: /edit record/i }))
    await user.type(await screen.findByLabelText('Notes'), 'x')
    await user.click(screen.getByRole('button', { name: /save changes/i }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/someone else changed this record/i)
    expect(calls.rpc.filter(([fn]) => fn === 'cng_admin_update_record')).toHaveLength(1)
  })

  it('ADMINUI-5 photo upload refuses a wrong type or an oversize file before sending anything', async () => {
    const user = userEvent.setup({ applyAccept: false })
    render(<RecordAdminTools record={{ table: 'hoses', id: 'r1' }} />)
    const input = (await screen.findByText(/add photo/i)).parentElement!.querySelector('input[type=file]') as HTMLInputElement
    await user.upload(input, new File(['x'], 'a.gif', { type: 'image/gif' }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/JPG, PNG or WebP/)
    const big = new File([new Uint8Array(5 * 1024 * 1024 + 1)], 'b.jpg', { type: 'image/jpeg' })
    await user.upload(input, big)
    await waitFor(() => expect(screen.getByRole('alert').textContent).toMatch(/larger than 5 MB/))
    expect(calls.upload).toHaveLength(0)
  })

  it('ADMINUI-6 a valid photo uploads under its own record path, then is registered', async () => {
    const user = userEvent.setup()
    render(<RecordAdminTools record={{ table: 'hoses', id: 'r1' }} />)
    const input = (await screen.findByText(/add photo/i)).parentElement!.querySelector('input[type=file]') as HTMLInputElement
    await user.upload(input, new File(['x'], 'p.png', { type: 'image/png' }))
    await waitFor(() => expect(calls.rpc.some(([fn]) => fn === 'cng_admin_add_photo')).toBe(true))
    const [path] = calls.upload[0] as [string]
    expect(path).toMatch(/^hoses\/r1\/[0-9a-f-]+\.png$/)
    const add = calls.rpc.find(([fn]) => fn === 'cng_admin_add_photo')![1]
    expect(add).toMatchObject({ p_table: 'hoses', p_id: 'r1', p_storage_path: path, p_content_type: 'image/png' })
  })

  it('ADMINUI-7 blank means NULL; numbers are sent as numbers', () => {
    expect(toValue({ name: 'n', type: 'numeric', enum_values: null, nullable: true }, ' ')).toBeNull()
    expect(toValue({ name: 'n', type: 'numeric', enum_values: null, nullable: true }, '12.5')).toBe(12.5)
  })
})
