import { afterEach, describe, expect, it } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

import { DataToolbar } from '@/components/layout/PageContainer'
import { Breadcrumbs } from '@/components/layout/Breadcrumbs'

const HIDE_REST = 'max-md:[&>*:not(:first-child):not([data-filter-toggle])]:hidden'

function toolbar(filtersActive?: boolean) {
  return render(
    <DataToolbar label="Search and filter hoses" filtersActive={filtersActive} trailing={<button type="button">CSV</button>}>
      <input aria-label="Search hoses" />
      <select aria-label="Region"><option>All</option></select>
    </DataToolbar>,
  )
}

describe('DataToolbar phone layout', () => {
  it('TBAR-1 without filtersActive it never collapses and offers no toggle', () => {
    toolbar()
    expect(screen.queryByRole('button', { name: /filters/i })).toBeNull()
    const panel = screen.getByLabelText('Region').parentElement!
    expect(panel.className).not.toContain(HIDE_REST)
  })

  it('TBAR-2 the toggle opens and closes the filters, and says so to assistive technology', async () => {
    toolbar(false)
    const toggle = screen.getByRole('button', { name: 'Filters' })
    const panel = document.getElementById(toggle.getAttribute('aria-controls')!)!
    expect(panel.contains(screen.getByLabelText('Region'))).toBe(true)
    expect(toggle.getAttribute('aria-expanded')).toBe('false')
    expect(panel.className).toContain(HIDE_REST)
    expect(screen.getByRole('button', { name: 'CSV' }).parentElement!.className).toContain('max-md:hidden')

    await userEvent.click(toggle)
    expect(toggle.getAttribute('aria-expanded')).toBe('true')
    expect(toggle.textContent).toContain('Hide filters')
    expect(panel.className).not.toContain(HIDE_REST)
    expect(screen.getByRole('button', { name: 'CSV' }).parentElement!.className).not.toContain('max-md:hidden')
  })

  it('TBAR-3 the search box is never hidden: only the controls after it collapse', () => {
    toolbar(false)
    const search = screen.getByLabelText('Search hoses')
    expect(search.parentElement!.firstElementChild).toBe(search)
    expect(search.hasAttribute('data-filter-toggle')).toBe(false)
  })

  it('TBAR-4 a closed panel still tells the user the table is narrowed', () => {
    toolbar(true)
    expect(screen.getByRole('button', { name: /filters/i }).textContent).toContain('applied')
  })

  it('TBAR-5 no "applied" marker is shown when nothing is filtered', () => {
    toolbar(false)
    expect(screen.getByRole('button', { name: 'Filters' }).textContent).not.toContain('applied')
  })
})

describe('Breadcrumbs overflow', () => {
  const proto = HTMLElement.prototype
  const original = {
    scrollWidth: Object.getOwnPropertyDescriptor(proto, 'scrollWidth'),
    clientWidth: Object.getOwnPropertyDescriptor(proto, 'clientWidth'),
  }
  afterEach(() => {
    for (const [k, d] of Object.entries(original)) if (d) Object.defineProperty(proto, k, d)
  })

  it('CRUMB-1 an overflowing trail starts scrolled to the current page', () => {
    Object.defineProperty(proto, 'scrollWidth', { configurable: true, get: () => 600 })
    Object.defineProperty(proto, 'clientWidth', { configurable: true, get: () => 200 })
    render(
      <MemoryRouter>
        <Breadcrumbs crumbs={[{ label: 'Asset Management', to: '/manage' }, { label: 'SRV Management' }]} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' }).scrollLeft).toBe(600)
  })

  it('CRUMB-2 a trail that fits is left where it is', () => {
    Object.defineProperty(proto, 'scrollWidth', { configurable: true, get: () => 100 })
    Object.defineProperty(proto, 'clientWidth', { configurable: true, get: () => 200 })
    render(
      <MemoryRouter>
        <Breadcrumbs crumbs={[{ label: 'Dashboard' }]} />
      </MemoryRouter>,
    )
    expect(screen.getByRole('navigation', { name: 'Breadcrumb' }).scrollLeft).toBe(0)
  })
})
