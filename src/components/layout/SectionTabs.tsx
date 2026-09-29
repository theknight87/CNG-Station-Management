import { useEffect, useRef } from 'react'
import type { LucideIcon } from 'lucide-react'
import { NavLink, useLocation } from 'react-router-dom'

import { cn } from '@/lib/utils'
import { sectionTabClass, sectionTabTrack } from './sectionTabStyles'

/**
 * The sub-navigation of a workspace (SRV, Vessels, Unit, Reports, Admin) — one look everywhere (owner request
 * 2026-09-29: tabs that stand out, are clearly clickable and look consistent).
 *
 * These are ROUTES, so it is a `nav` of links with `aria-current="page"` (set by NavLink), not an ARIA tab widget:
 * every section is deep-linkable and Back works. The active tab is marked by a raised surface, a brand underline,
 * a weight change and aria-current — never by colour alone.
 */
export interface SectionTab {
  to: string
  label: string
  /** One line under the label saying what the section holds. */
  hint?: string
  icon?: LucideIcon
  /** A count badge; omitted (never 0) when not known. */
  count?: number | null
  /** Match the path exactly (an index route). */
  end?: boolean
}

export function SectionTabContent({ tab, active, compact = false }: { tab: Omit<SectionTab, 'to'>; active: boolean; compact?: boolean }) {
  const Icon = tab.icon
  return (
    <>
      {Icon ? (
        <span aria-hidden="true" className={cn(
          'flex shrink-0 items-center justify-center rounded transition-colors',
          compact ? 'h-6 w-6' : 'h-7 w-7',
          active ? 'bg-brand-strong text-brand-strong-fg' : 'bg-muted text-muted-foreground group-hover:text-foreground',
        )}>
          <Icon className={compact ? 'h-3.5 w-3.5' : 'h-4 w-4'} />
        </span>
      ) : null}
      <span className="flex min-w-0 flex-col">
        <span className={cn('flex items-center gap-1.5 text-sm', active ? 'font-semibold' : 'font-medium')}>
          {tab.label}
          {tab.count !== undefined && tab.count !== null ? (
            <span className={cn('tabular rounded px-1.5 text-xs',
              active ? 'bg-brand-strong text-brand-strong-fg' : tab.count === 0 ? 'bg-muted text-muted-foreground' : 'bg-muted font-medium text-foreground')}>
              {tab.count}
            </span>
          ) : null}
        </span>
        {tab.hint ? <span className="text-xs font-normal text-muted-foreground">{tab.hint}</span> : null}
      </span>
    </>
  )
}


export function SectionTabs({ label, tabs, compact = false }: { label: string; tabs: SectionTab[]; compact?: boolean }) {
  const track = useRef<HTMLUListElement>(null)
  const { pathname } = useLocation()
  // On a narrow screen the strip scrolls; bring the current tab into view so the user sees where they are.
  useEffect(() => {
    const el = track.current
    const current = el?.querySelector<HTMLElement>('[aria-current="page"]')
    if (!el || !current || el.scrollWidth <= el.clientWidth) return
    el.scrollTo?.({ left: current.offsetLeft - (el.clientWidth - current.offsetWidth) / 2, behavior: 'smooth' })
  }, [pathname])
  return (
    <nav aria-label={label} className="min-w-0">
      <ul ref={track} className={cn(sectionTabTrack, 'relative')}>
        {tabs.map((tab) => (
          <li key={tab.to} className="flex">
            <NavLink to={tab.to} end={tab.end} className={({ isActive }) => sectionTabClass(isActive, compact)}>
              {({ isActive }) => <SectionTabContent tab={tab} active={isActive} compact={compact} />}
            </NavLink>
          </li>
        ))}
      </ul>
    </nav>
  )
}
