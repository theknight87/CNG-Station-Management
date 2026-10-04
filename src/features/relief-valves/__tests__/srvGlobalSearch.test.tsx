import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { srvLink } from '@/features/relief-valves/srvDeepLink'
import { rankHits, searchTerm } from '@/features/relief-valves/srvSearch'

/**
 * One search over every SRV tab (owner request 2026-10-04): a serial shows where the valve is, and picking a result
 * opens its tab filtered to it with its details open.
 */

const state = vi.hoisted(() => ({ asked: [] as string[][], data: {} as Record<string, unknown[]> }))
function query(view: string) {
  const asked: string[] = [view]
  const q: Record<string, unknown> = {}
  for (const m of ['select', 'or', 'in']) q[m] = (...a: unknown[]) => { asked.push(`${m}:${a.map(String).join('|')}`); return q }
  q.limit = async () => { state.asked.push(asked); return { data: state.data[view] ?? [], error: null } }
  return q
}
vi.mock('@/lib/supabase/client', () => ({ useSupabaseClient: () => ({ from: query }) }))

const { SrvGlobalSearch } = await import('@/features/relief-valves/SrvGlobalSearch')

function Where() {
  const l = useLocation()
  return <p data-testid="where">{l.pathname + l.search}</p>
}
function renderSearch() {
  render(
    <MemoryRouter initialEntries={['/manage/srvs/installed']}>
      <SrvGlobalSearch />
      <Routes><Route path="*" element={<Where />} /></Routes>
    </MemoryRouter>,
  )
}

beforeEach(() => {
  state.asked = []
  state.data = {
    v_installed_srv_management: [{ id: 'i-1', serial_number: 'AB-77', warehouse_code: 'sbc 20', unit_name: 'شبرا 1', station_display: 'شبرا', region_name: 'East' }],
    v_srv_warehouse_stock: [{ id: 'w-1', serial_number: 'AB-7', warehouse_code: 'sbc 20', availability_status: 'available_calibrated' }],
    v_srv_field_log: [{ id: 'l-1', serial_number: 'XAB-7', warehouse_code: null, station_display: 'الخمائل', unit_name: null, region_name: 'West' }],
    v_srv_calibration: [{ id: 'c-1', serial_number: 'AB-70', warehouse_code: 'sbu 20' }],
  }
})

describe('global SRV search', () => {
  it('GS-1 a serial is looked up in every tab at once: installed, warehouse, valves awaiting return, at calibration', async () => {
    renderSearch()
    await userEvent.type(screen.getByRole('combobox'), 'AB-7')
    const options = await screen.findAllByRole('option')
    expect(options).toHaveLength(4)
    expect(state.asked.map((a) => a[0]).sort()).toEqual(['v_installed_srv_management', 'v_srv_calibration', 'v_srv_field_log', 'v_srv_warehouse_stock'])
    const log = state.asked.find((a) => a[0] === 'v_srv_field_log')!
    expect(log).toContain('in:status|at_station,location_unconfirmed')
    expect(log).toContain('or:serial_number.ilike.*AB-7*,warehouse_code.ilike.*AB-7*')
    // The exact serial first; where each one is, in words.
    expect(options[0].textContent).toContain('Warehouse')
    expect(options[0].textContent).toContain('CALIBRATED')
    expect(screen.getByText('شبرا 1 · East')).toBeDefined()
    expect(screen.getByText('awaiting return from · الخمائل · West')).toBeDefined()
    expect(screen.getByText('at the calibration company')).toBeDefined()
  })

  it('GS-2 picking a result opens its tab filtered to that serial, with the record to open', async () => {
    renderSearch()
    await userEvent.type(screen.getByRole('combobox'), 'AB-7')
    await userEvent.click((await screen.findAllByRole('option'))[1])
    expect(screen.getByTestId('where').textContent).toBe('/manage/srvs/installed?q=AB-77&open=i-1')
  })

  it('GS-3 Enter goes to the first (exact) match; nothing is asked for a single character', async () => {
    renderSearch()
    await userEvent.type(screen.getByRole('combobox'), 'A')
    await new Promise((r) => setTimeout(r, 400))
    expect(state.asked).toEqual([])
    await userEvent.type(screen.getByRole('combobox'), 'B-7')
    await screen.findAllByRole('option')
    await userEvent.keyboard('{Enter}')
    expect(screen.getByTestId('where').textContent).toBe('/manage/srvs/warehouse?q=AB-7&open=w-1')
  })

  it('GS-4 no match is said in words', async () => {
    state.data = {}
    renderSearch()
    await userEvent.type(screen.getByRole('combobox'), 'ZZ-1')
    expect(await screen.findByText(/no relief valve matches/i)).toBeDefined()
  })

  it('GS-5 helpers: characters a filter cannot carry are dropped; exact matches rank first; links carry q and open', () => {
    expect(searchTerm(' a,b(c)*d% ')).toBe('a b c  d')
    const hits = rankHits([
      { tab: 'log', id: '1', serial: 'X1', code: null, place: null },
      { tab: 'installed', id: '2', serial: 'X10', code: null, place: null },
      { tab: 'calibration', id: '3', serial: 'x1', code: null, place: null },
    ], 'X1')
    expect(hits.map((h) => h.id)).toEqual(['1', '3', '2'])
    expect(srvLink('log', 'شبرا 1', 'id-9')).toBe('/manage/srvs/log?q=%D8%B4%D8%A8%D8%B1%D8%A7+1&open=id-9')
  })
})
