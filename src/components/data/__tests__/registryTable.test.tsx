import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import type { RegistryPage } from '@/components/data/RegistryTable'

/**
 * Owner report 2026-10-02: pressing a tile felt slow because the table blanked to a loading screen while the
 * next result loaded. It now keeps the last result on screen, dimmed and marked busy.
 */
type Row = { id: string; serial: string }
const columns: RegistryColumn<Row>[] = [{ key: 'serial', header: 'Serial', rowHeader: true, render: (r) => r.serial }]

function table(state: Loadable<RegistryPage<Row>>) {
  return (
    <RegistryTable<Row>
      label="Test rows" state={state} reload={() => {}} columns={columns} rowKey={(r) => r.id} detail={() => null}
      sort="serial" direction="asc" onSort={() => {}} page={0} pageSize={50} onPage={() => {}} onClearFilters={() => {}}
      emptyTitle="Nothing" emptyDescription="Nothing yet" errorTitle="Failed"
    />
  )
}

describe('RegistryTable while the next result loads', () => {
  it('a first load with nothing to show yet is a loading state', () => {
    render(table({ status: 'loading' }))
    expect(screen.queryByRole('table')).toBeNull()
  })

  it('keeps the previous rows on screen, marked busy, instead of blanking', () => {
    const first: Loadable<RegistryPage<Row>> = { status: 'ready', data: { rows: [{ id: '1', serial: 'SN-OLD' }], total: 1, filtered: false } }
    const { rerender, container } = render(table(first))
    expect(screen.getByText('SN-OLD')).toBeDefined()

    rerender(table({ status: 'loading' }))
    expect(screen.getByText('SN-OLD')).toBeDefined()
    expect(container.querySelector('[aria-busy="true"]')).not.toBeNull()
    expect(screen.getByRole('status').textContent).toMatch(/updating test rows/i)

    rerender(table({ status: 'ready', data: { rows: [{ id: '2', serial: 'SN-NEW' }], total: 1, filtered: true } }))
    expect(screen.getByText('SN-NEW')).toBeDefined()
    expect(screen.queryByText('SN-OLD')).toBeNull()
    expect(container.querySelector('[aria-busy="true"]')).toBeNull()
  })

  it('a failure after a result is still stated as a failure, never as the old rows', () => {
    const first: Loadable<RegistryPage<Row>> = { status: 'ready', data: { rows: [{ id: '1', serial: 'SN-OLD' }], total: 1, filtered: false } }
    const { rerender } = render(table(first))
    rerender(table({ status: 'error', message: 'boom' }))
    expect(screen.queryByText('SN-OLD')).toBeNull()
    expect(screen.getByText('Failed')).toBeDefined()
  })
})

describe('RegistryTable deep link (global SRV search, owner request 2026-10-04)', () => {
  it('opens the linked row\'s details once that row is on screen, and only once', () => {
    const ready: Loadable<RegistryPage<Row>> = { status: 'ready', data: { rows: [{ id: '1', serial: 'SN-A' }, { id: '2', serial: 'SN-B' }], total: 2, filtered: true } }
    render(
      <RegistryTable<Row>
        label="Test rows" state={ready} reload={() => {}} columns={columns} rowKey={(r) => r.id}
        detail={(r) => <span>Detail of {r.serial}</span>}
        sort="serial" direction="asc" onSort={() => {}} page={0} pageSize={50} onPage={() => {}} onClearFilters={() => {}}
        emptyTitle="Nothing" emptyDescription="Nothing yet" errorTitle="Failed" openKey="2"
      />,
    )
    expect(screen.getByText('Detail of SN-B')).toBeDefined()
    expect(screen.queryByText('Detail of SN-A')).toBeNull()
  })
})
