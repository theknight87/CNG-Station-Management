import { useContext, useState } from 'react'
import { UNSAFE_LocationContext } from 'react-router-dom'

/**
 * Deep links from the global SRV search (owner request 2026-10-04): `?q=<serial>` fills the tab's own search and
 * `&open=<id>` opens that record's details once its row is on screen. The workspace remounts the tab whenever the
 * link changes, so a tab reads the link only when it starts.
 */

export type SrvTab = 'installed' | 'warehouse' | 'log' | 'calibration'

export function srvLink(tab: SrvTab, q: string, open: string): string {
  return `/manage/srvs/${tab}?${new URLSearchParams({ q, open }).toString()}`
}

/** The link's `q` and `open`; outside a router (a tab rendered on its own) there is no link. */
export function useSrvDeepLink(): { q: string; open: string | null } {
  const location = useContext(UNSAFE_LocationContext)?.location
  const params = new URLSearchParams(location?.search ?? '')
  return { q: params.get('q') ?? '', open: params.get('open') }
}

/** Open the linked row (once) when it appears among `rows`. */
export function useOpenLinked<T extends { id: string }>(rows: T[], open: (row: T) => void) {
  const { open: want } = useSrvDeepLink()
  const [done, setDone] = useState<string | null>(null)
  if (want && want !== done) {
    const hit = rows.find((r) => r.id === want)
    if (hit) { setDone(want); open(hit) }
  }
}
