import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { TableScroll } from '@/components/data/DataTable'

describe('production hardening', () => {
  it('removes the obsolete Clerk authentication diagnostic', () => {
    const routes = readFileSync(resolve(process.cwd(), 'src/routes.tsx'), 'utf8')

    expect(routes).not.toContain("path: '/auth-test'")
    expect(routes).not.toContain('AuthTestPage')
  })

  it('ships immutable caching and browser security policy for Cloudflare Pages', () => {
    const headers = readFileSync(resolve(process.cwd(), 'public/_headers'), 'utf8')

    expect(headers).toContain('/assets/*')
    expect(headers).toContain('max-age=31536000, immutable')
    expect(headers).toContain('Content-Security-Policy:')
    expect(headers).toContain("frame-ancestors 'none'")
    expect(headers).toContain('X-Content-Type-Options: nosniff')
  })

  it('makes horizontal table overflow explicit to mobile and assistive users', () => {
    render(<TableScroll label="Installed SRVs"><table><tbody><tr><td>SRV</td></tr></tbody></table></TableScroll>)

    expect(screen.getByText('Swipe for more columns →')).toBeTruthy()
    expect(screen.getByRole('region', { name: 'Installed SRVs — horizontally scrollable table' }).getAttribute('tabindex')).toBe('0')
  })
})
