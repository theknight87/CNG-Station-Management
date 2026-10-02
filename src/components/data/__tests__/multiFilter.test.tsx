import { useState } from 'react'
import { describe, expect, it } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { applyMulti, DUE_ALIASES, encodeMulti, hasMulti, matchesMulti, parseMulti } from '@/components/data/multiFilter'

function builder() {
  const calls: [string, ...unknown[]][] = []
  const b = {
    eq(c: string, v: unknown) { calls.push(['eq', c, v]); return b },
    ilike(c: string, v: unknown) { calls.push(['ilike', c, v]); return b },
    in(c: string, v: unknown) { calls.push(['in', c, v]); return b },
    or(e: string) { calls.push(['or', e]); return b },
  }
  return { b, calls }
}

describe('multi-choice filters (owner request 2026-10-02)', () => {
  it('MULTI-1 stores nothing, one value, several, or an exclusion as one string', () => {
    expect(parseMulti('')).toEqual({ values: [], exclude: false })
    expect(parseMulti('all')).toEqual({ values: [], exclude: false })
    expect(parseMulti('overdue')).toEqual({ values: ['overdue'], exclude: false })
    expect(parseMulti('EKC|COI')).toEqual({ values: ['EKC', 'COI'], exclude: false })
    expect(parseMulti('!EKC')).toEqual({ values: ['EKC'], exclude: true })
    expect(encodeMulti({ values: ['EKC'], exclude: true })).toBe('!EKC')
    expect(encodeMulti({ values: [], exclude: true }, 'all')).toBe('all')
    expect(hasMulti('!')).toBe(false)
  })

  it('MULTI-2 the tiles\' legacy "attention" still means overdue up to 30 days, never 60', () => {
    expect(parseMulti('attention', DUE_ALIASES).values).toEqual(['overdue', 'due_today', 'due_7', 'due_15', 'due_30'])
  })

  it('MULTI-3 one value is the plain comparison; several are IN; an exclusion keeps unrecorded rows', () => {
    const { b, calls } = builder()
    applyMulti(b, 'due_status', 'overdue')
    applyMulti(b, 'due_status', 'overdue|due_7')
    applyMulti(b, 'region_id', '!r-east')
    expect(calls).toEqual([
      ['eq', 'due_status', 'overdue'],
      ['in', 'due_status', ['overdue', 'due_7']],
      ['or', 'region_id.is.null,region_id.not.in.("r-east")'],
    ])
  })

  it('MULTI-4 manufacturer compares case-insensitively, including "every manufacturer except EKC"', () => {
    const { b, calls } = builder()
    applyMulti(b, 'manufacturer', 'EKC', { caseInsensitive: true })
    applyMulti(b, 'manufacturer', 'EKC|Tyco Anderson', { caseInsensitive: true })
    applyMulti(b, 'manufacturer', '!EKC', { caseInsensitive: true })
    expect(calls).toEqual([
      ['ilike', 'manufacturer', 'EKC'],
      ['or', 'manufacturer.ilike."EKC",manufacturer.ilike."Tyco Anderson"'],
      ['or', 'manufacturer.is.null,and(manufacturer.not.ilike."EKC")'],
    ])
  })

  it('MULTI-5 the in-browser test agrees with the server one', () => {
    expect(matchesMulti('EKC', '')).toBe(true)
    expect(matchesMulti('EKC', '!EKC')).toBe(false)
    expect(matchesMulti('COI', '!EKC')).toBe(true)
    expect(matchesMulti(null, '!EKC')).toBe(true)
    expect(matchesMulti(null, 'EKC')).toBe(false)
  })
})

function Harness({ initial = '' }: { initial?: string }) {
  const [value, setValue] = useState(initial)
  return (
    <>
      <MultiSelectFilter id="m" label="Manufacturer" value={value} onChange={setValue}
                         options={['COI', 'EKC', 'Mercer'].map((m) => ({ value: m, label: m }))} />
      <output data-testid="value">{value}</output>
    </>
  )
}

describe('MultiSelectFilter', () => {
  it('MULTI-6 ticks several values, in the options\' own order', async () => {
    render(<Harness />)
    expect(screen.getByRole('button', { name: /^manufacturer:/i }).textContent).toContain('All')
    await userEvent.click(screen.getByRole('button', { name: /^manufacturer:/i }))
    const dialog = screen.getByRole('dialog', { name: 'Manufacturer filter' })
    await userEvent.click(within(dialog).getByRole('checkbox', { name: 'Mercer' }))
    await userEvent.click(within(dialog).getByRole('checkbox', { name: 'COI' }))
    expect(screen.getByTestId('value').textContent).toBe('COI|Mercer')
    expect(screen.getByRole('button', { name: /^manufacturer:/i }).textContent).toContain('COI +1')
  })

  it('MULTI-7 "All except" before ticking excludes; switching back keeps the same values', async () => {
    render(<Harness />)
    await userEvent.click(screen.getByRole('button', { name: /^manufacturer:/i }))
    const dialog = screen.getByRole('dialog', { name: 'Manufacturer filter' })
    await userEvent.click(within(dialog).getByRole('button', { name: 'All except' }))
    await userEvent.click(within(dialog).getByRole('checkbox', { name: 'EKC' }))
    expect(screen.getByTestId('value').textContent).toBe('!EKC')
    expect(screen.getByRole('button', { name: /^manufacturer:/i }).textContent).toContain('All except EKC')
    await userEvent.click(within(dialog).getByRole('button', { name: 'Only these' }))
    expect(screen.getByTestId('value').textContent).toBe('EKC')
  })

  it('MULTI-8 clears from the badge, and closes with Escape', async () => {
    render(<Harness initial="!EKC" />)
    await userEvent.click(screen.getByRole('button', { name: 'Clear the Manufacturer filter' }))
    expect(screen.getByTestId('value').textContent).toBe('')
    await userEvent.click(screen.getByRole('button', { name: /^manufacturer:/i }))
    expect(screen.getByRole('dialog')).toBeDefined()
    await userEvent.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
  })
})
