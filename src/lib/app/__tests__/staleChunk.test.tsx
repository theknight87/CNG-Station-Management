import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { createMemoryRouter, RouterProvider } from 'react-router-dom'

import { RouteError } from '@/components/states/RouteError'
import { isStaleChunkError, reloadForNewVersion } from '@/lib/app/staleChunk'

/**
 * Owner report 2026-10-02: "Failed to fetch dynamically imported module …/AdminPage-….js" on several pages.
 * A tab opened before a deployment asks for files the new version no longer has; it must load the new
 * version (once), and never show the router's developer screen.
 */
const reload = vi.fn()

beforeEach(() => {
  window.sessionStorage.clear()
  reload.mockReset()
  Object.defineProperty(window, 'location', { configurable: true, value: { ...window.location, reload } })
})
afterEach(() => window.sessionStorage.clear())

describe('stale deployment detection', () => {
  it('recognises the browsers’ failed-dynamic-import messages', () => {
    expect(isStaleChunkError(new TypeError('Failed to fetch dynamically imported module: https://x/assets/AdminPage-BwGlbkm5.js'))).toBe(true)
    expect(isStaleChunkError(new TypeError('error loading dynamically imported module'))).toBe(true)
    expect(isStaleChunkError(new TypeError('Importing a module script failed.'))).toBe(true)
    expect(isStaleChunkError(new Error('Unable to preload CSS for /assets/x.css'))).toBe(true)
    expect(isStaleChunkError(new Error('column v_x.y does not exist'))).toBe(false)
    expect(isStaleChunkError(null)).toBe(false)
  })

  it('reloads once, and not again within the loop-guard window', () => {
    expect(reloadForNewVersion(1_000_000)).toBe(true)
    expect(reload).toHaveBeenCalledTimes(1)
    expect(reloadForNewVersion(1_010_000)).toBe(false)
    expect(reload).toHaveBeenCalledTimes(1)
    // Long after, a later deployment may reload again.
    expect(reloadForNewVersion(1_100_000)).toBe(true)
    expect(reload).toHaveBeenCalledTimes(2)
  })
})

function renderFailing(error: unknown) {
  const router = createMemoryRouter([
    { path: '/', errorElement: <RouteError />, loader: () => { throw error }, element: <p>never</p> },
    { path: '/dashboard', element: <p>dashboard</p> },
  ])
  render(<RouterProvider router={router} />)
}

describe('the route error page', () => {
  it('a stale tab says a new version is loading and reloads itself', async () => {
    renderFailing(new TypeError('Failed to fetch dynamically imported module: https://x/assets/AdminPage-BwGlbkm5.js'))
    expect(await screen.findByText(/a new version of the application is available/i)).toBeDefined()
    expect(reload).toHaveBeenCalledTimes(1)
    expect(screen.queryByText(/hey developer/i)).toBeNull()
  })

  it('any other failure is stated with Reload and a way back, and does not reload by itself', async () => {
    renderFailing(new Error('boom'))
    expect(await screen.findByText(/this page could not be displayed/i)).toBeDefined()
    expect(screen.getByRole('button', { name: 'Reload' })).toBeDefined()
    expect(screen.getByRole('link', { name: /go to the dashboard/i })).toBeDefined()
    expect(reload).not.toHaveBeenCalled()
  })
})
