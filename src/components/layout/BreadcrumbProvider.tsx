import { useMemo, useState, type ReactNode } from 'react'

import { BreadcrumbContext, type BreadcrumbState } from '@/components/layout/breadcrumbContext'
import type { Crumb } from '@/components/layout/breadcrumbPaths'

/** Holds the published trail and hands it to the shell. See breadcrumbContext. */
export function BreadcrumbProvider({ children }: { children: (override: Crumb[] | null) => ReactNode }) {
  const [override, setOverride] = useState<Crumb[] | null>(null)
  const value = useMemo<BreadcrumbState>(() => ({ override, publish: setOverride }), [override])
  return <BreadcrumbContext.Provider value={value}>{children(override)}</BreadcrumbContext.Provider>
}
