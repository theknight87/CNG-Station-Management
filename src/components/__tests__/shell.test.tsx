import { describe, expect, it, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

import { SidebarNav } from '@/components/layout/SidebarNav'
import { MobileNav } from '@/components/layout/MobileNav'
import { Breadcrumbs } from '@/components/layout/Breadcrumbs'
import { EmptyState, NoResultsState, NotImplemented, PermissionDenied } from '@/components/states/AppStates'

function renderAt(ui: React.ReactElement, route = '/dashboard') {
  return render(<MemoryRouter initialEntries={[route]}>{ui}</MemoryRouter>)
}

describe('sidebar navigation', () => {
  it('SHELL-1 labels the nav landmark so a screen reader can skip to it', () => {
    renderAt(<SidebarNav role="admin" />)
    expect(screen.getByRole('navigation', { name: 'Main' })).toBeDefined()
  })

  it('SHELL-2 marks the active route with aria-current, not colour alone', () => {
    renderAt(<SidebarNav role="admin" />, '/manage/srvs')
    const active = screen.getByRole('link', { name: 'SRV Management' })
    expect(active.getAttribute('aria-current')).toBe('page')

    const inactive = screen.getByRole('link', { name: 'Alerts' })
    expect(inactive.getAttribute('aria-current')).toBeNull()
  })

  it('SHELL-3 a prefix route keeps its parent item active', () => {
    // /admin/users must still light up "Admin".
    renderAt(<SidebarNav role="admin" />, '/admin/users')
    expect(screen.getByRole('link', { name: 'Admin' }).getAttribute('aria-current')).toBe('page')
  })

  it('SHELL-4 collapsed icon-only links keep an accessible name', () => {
    renderAt(<SidebarNav role="admin" collapsed />)
    // The visible label is hidden, but the link is still findable by name —
    // an icon-only control without a name is the classic a11y failure.
    expect(screen.getByRole('link', { name: 'Dashboard' })).toBeDefined()
    expect(screen.getByRole('link', { name: 'Gas Detector Management' })).toBeDefined()
  })

  it('SHELL-5 a viewer sees no Admin link', () => {
    renderAt(<SidebarNav role="viewer" />)
    expect(screen.queryByRole('link', { name: 'Admin' })).toBeNull()
    expect(screen.getByRole('link', { name: 'Dashboard' })).toBeDefined()
  })

  it('SHELL-6 an unresolved role renders no navigation at all', () => {
    renderAt(<SidebarNav role={null} />)
    expect(screen.queryAllByRole('link')).toHaveLength(0)
  })
})

describe('mobile navigation drawer', () => {
  it('DRAWER-1 is a labelled modal dialog', () => {
    renderAt(<MobileNav open onClose={() => {}} role="admin" />)
    const dialog = screen.getByRole('dialog', { name: 'Main navigation' })
    expect(dialog.getAttribute('aria-modal')).toBe('true')
  })

  it('DRAWER-2 renders nothing at all when closed', () => {
    renderAt(<MobileNav open={false} onClose={() => {}} role="admin" />)
    expect(screen.queryByRole('dialog')).toBeNull()
  })

  it('DRAWER-3 Escape closes it', async () => {
    const onClose = vi.fn()
    renderAt(<MobileNav open onClose={onClose} role="admin" />)
    await userEvent.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalled()
  })

  it('DRAWER-4 choosing a destination closes it', async () => {
    const onClose = vi.fn()
    renderAt(<MobileNav open onClose={onClose} role="admin" />)
    await userEvent.click(screen.getByRole('link', { name: 'Reports' }))
    expect(onClose).toHaveBeenCalled()
  })

  it('DRAWER-5 the close control has an accessible name', () => {
    renderAt(<MobileNav open onClose={() => {}} role="admin" />)
    expect(screen.getByRole('button', { name: 'Close navigation' })).toBeDefined()
  })

  it('DRAWER-6 moves focus into the drawer on open', () => {
    renderAt(<MobileNav open onClose={() => {}} role="admin" />)
    const dialog = screen.getByRole('dialog')
    expect(dialog.contains(document.activeElement)).toBe(true)
  })
})

describe('breadcrumbs', () => {
  it('CRUMBUI-1 marks the last crumb as the current page', () => {
    renderAt(
      <Breadcrumbs crumbs={[{ label: 'Stations', to: '/stations' }, { label: 'SRV Management' }]} />,
    )
    const nav = screen.getByRole('navigation', { name: 'Breadcrumb' })
    expect(within(nav).getByText('SRV Management').getAttribute('aria-current')).toBe('page')
  })

  it('CRUMBUI-2 renders an Arabic entity crumb with direction handling', () => {
    const { container } = renderAt(
      <Breadcrumbs crumbs={[{ label: 'Stations', to: '/stations' }, { label: 'الماظة 1', isEntity: true }]} />,
    )
    const arabic = container.querySelector('[dir="auto"]')
    expect(arabic?.textContent).toBe('الماظة 1')
  })

  it('CRUMBUI-3 renders nothing for an empty trail rather than an empty bar', () => {
    const { container } = renderAt(<Breadcrumbs crumbs={[]} />)
    expect(container.querySelector('nav')).toBeNull()
  })
})

describe('application states are distinguishable', () => {
  it('STATE-1 empty data and no-filter-results say different things', () => {
    const empty = render(<EmptyState />).container.textContent ?? ''
    const filtered = render(<NoResultsState />).container.textContent ?? ''
    expect(empty).not.toBe(filtered)
    expect(filtered).toMatch(/filters/i)
  })

  it('STATE-2 permission denied is not an empty state', () => {
    const { container } = render(<PermissionDenied what="administration" />)
    expect(container.textContent).toMatch(/do not have access/i)
    expect(container.textContent).not.toMatch(/no records/i)
  })

  it('STATE-3 an unbuilt feature never looks like successful empty data', () => {
    const { container } = render(<NotImplemented feature="Dashboard" phase="planned for Prompt 8" />)
    expect(container.textContent).toMatch(/not built yet/i)
    expect(container.textContent).toMatch(/Prompt 8/)
    // And it invents no figures to fill the space.
    expect(container.textContent).not.toMatch(/\b\d+ (records|assets|stations)\b/i)
  })
})
