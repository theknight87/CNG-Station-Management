import { describe, expect, it } from 'vitest'

import { NAV_SECTIONS, allNavPaths, visibleSections } from '@/components/layout/navigation'
import { crumbsFromPath } from '@/components/layout/breadcrumbPaths'
import type { AppRole } from '@/types/domain'

describe('navigation structure', () => {
  it('NAV-1 carries the information architecture Prompt 7 specifies', () => {
    const headings = NAV_SECTIONS.map((s) => s.heading).filter(Boolean)
    expect(headings).toEqual(['Stations', 'Asset Management', 'System'])

    const paths = allNavPaths()
    for (const expected of [
      '/dashboard',
      '/regions',
      '/stations',
      '/manage/srvs',
      '/manage/vessels',
      '/manage/gas-detectors',
      '/manage/hoses',
      '/alerts',
      '/reports',
      '/admin',
      '/settings',
    ]) {
      expect(paths, `${expected} must be reachable from the sidebar`).toContain(expected)
    }
  })

  it('NAV-2 NEGATIVE: the temporary Prompt-5 auth routes never appear in the sidebar', () => {
    const paths = allNavPaths()
    for (const temporary of ['/sign-in', '/sign-up', '/auth-test']) {
      expect(paths, `${temporary} is temporary and must stay out of navigation`).not.toContain(temporary)
    }
  })

  it('NAV-3 every item carries an SVG icon component, and no label is an emoji', () => {
    for (const section of NAV_SECTIONS) {
      for (const item of section.items) {
        // A renderable component: a function, or the object a forwardRef/memo
        // component is. A string here would mean an emoji or text "icon",
        // which ui-ux-pro-max and CLAUDE.md §11.3 both rule out.
        expect(item.Icon, `${item.label} needs a real icon`).toBeTruthy()
        expect(['function', 'object']).toContain(typeof item.Icon)

        // No pictographic character anywhere in a navigation label.
        expect(item.label, `${item.label} must not contain an emoji`).not.toMatch(
          /\p{Extended_Pictographic}/u,
        )
      }
    }
  })

  it('NAV-4 SRV Management is a management VIEW, not a hierarchy level', () => {
    const assetSection = NAV_SECTIONS.find((s) => s.heading === 'Asset Management')
    expect(assetSection?.items.map((i) => i.to)).toContain('/manage/srvs')

    // It must not be presented as a peer of Regions/Stations in the hierarchy
    // group — SRVs are children of equipment, never a top-level asset.
    const stationsSection = NAV_SECTIONS.find((s) => s.heading === 'Stations')
    expect(stationsSection?.items.map((i) => i.to)).not.toContain('/manage/srvs')
  })
})

describe('authorization-aware navigation', () => {
  const pathsFor = (role: AppRole | null) =>
    visibleSections(role).flatMap((s) => s.items.map((i) => i.to))

  it('AUTHNAV-1 admin sees Admin', () => {
    expect(pathsFor('admin')).toContain('/admin')
  })

  it('AUTHNAV-2 manager, engineer and viewer do NOT see Admin', () => {
    for (const role of ['manager', 'engineer', 'viewer'] as AppRole[]) {
      expect(pathsFor(role), `${role} must not see Admin`).not.toContain('/admin')
    }
  })

  it('AUTHNAV-3 every role still sees the operational screens', () => {
    for (const role of ['admin', 'manager', 'engineer', 'viewer'] as AppRole[]) {
      const paths = pathsFor(role)
      expect(paths).toContain('/dashboard')
      expect(paths).toContain('/manage/srvs')
      expect(paths).toContain('/alerts')
    }
  })

  it('AUTHNAV-4 no role resolves to no navigation at all', () => {
    for (const role of ['admin', 'manager', 'engineer', 'viewer'] as AppRole[]) {
      expect(pathsFor(role).length).toBeGreaterThan(5)
    }
  })

  it('AUTHNAV-5 an unresolved role sees nothing — closed by default', () => {
    expect(visibleSections(null)).toEqual([])
  })

  it('AUTHNAV-6 no section heading is left hanging over an empty list', () => {
    for (const role of ['admin', 'manager', 'engineer', 'viewer'] as AppRole[]) {
      for (const section of visibleSections(role)) {
        expect(section.items.length).toBeGreaterThan(0)
      }
    }
  })
})

describe('breadcrumbs derived from a path', () => {
  it('CRUMB-1 builds a linked trail for a nested route', () => {
    expect(crumbsFromPath('/manage/srvs')).toEqual([
      { label: 'Asset Management', to: undefined },
      { label: 'SRV Management', to: undefined },
    ])
  })

  it('CRUMB-2 marks intermediate crumbs as links and the last as the page', () => {
    const crumbs = crumbsFromPath('/admin/users')
    expect(crumbs[0]).toEqual({ label: 'Admin', to: '/admin' })
    expect(crumbs[crumbs.length - 1].to).toBeUndefined()
  })

  it('CRUMB-3 NEGATIVE: an id segment never becomes a fabricated entity name', () => {
    // The screen that owns the entity supplies the real label. A raw uuid must
    // never be rendered as though it were a station name.
    const crumbs = crumbsFromPath('/stations/31d59e99-70cb-4155-bb91-8f813a70f37b')
    expect(crumbs.map((c) => c.label)).toEqual(['Stations'])
  })

  it('CRUMB-4 handles the root and unknown routes without throwing', () => {
    expect(crumbsFromPath('/')).toEqual([])
    expect(crumbsFromPath('/nothing-here')).toEqual([])
  })
})
