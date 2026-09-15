import { createContext, useContext, useEffect } from 'react'

import type { Crumb } from '@/components/layout/breadcrumbPaths'

/**
 * Lets a screen that OWNS an entity publish the real breadcrumb trail.
 *
 * The shell can derive `Regions › Stations` from the URL, but it cannot know
 * that `/units/3f2a…` is `الماظة › الماظة 1` — only the screen that loaded the
 * Unit knows that. Rather than let the shell guess a label from a URL segment
 * (which would print a UUID, or worse, a fabricated name), the screen hands the
 * trail up once its data is actually loaded.
 *
 * Until then the path-derived fallback stands. Nothing is invented while
 * loading, and a screen that fails to load never publishes a trail at all.
 *
 * The provider lives in its own file so this module exports no component —
 * mixing the two breaks fast refresh.
 */

export interface BreadcrumbState {
  override: Crumb[] | null
  publish: (crumbs: Crumb[] | null) => void
}

export const BreadcrumbContext = createContext<BreadcrumbState>({
  override: null,
  publish: () => {},
})

/**
 * Publishes a trail for as long as the calling screen is mounted, and clears it
 * on unmount so the next route does not inherit the previous screen's entities.
 *
 * `crumbs` is compared by VALUE, not identity: callers build the array inline
 * during render, so depending on the reference would republish on every render
 * and spin the shell.
 */
export function usePublishBreadcrumbs(crumbs: Crumb[] | null) {
  const { publish } = useContext(BreadcrumbContext)
  const key = crumbs ? JSON.stringify(crumbs) : null

  useEffect(() => {
    publish(key ? (JSON.parse(key) as Crumb[]) : null)
    return () => publish(null)
  }, [key, publish])
}
