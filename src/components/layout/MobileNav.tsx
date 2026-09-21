import { useEffect, useRef } from 'react'
import { X } from 'lucide-react'

import { BrandMark } from '@/components/layout/BrandMark'

import { Button } from '@/components/ui/button'
import type { AppRole } from '@/types/domain'
import { SidebarNav } from './SidebarNav'

/**
 * Mobile / tablet navigation drawer (prompt §8).
 *
 * Built in-house rather than with a dialog library. ui-ux-pro-max recommends
 * shadcn's Sidebar/Sheet; that was rejected for this project (see
 * docs/ui-foundation.md) because it pulls four Radix packages and ships a
 * roomier, pill-shaped default than §11.3's density allows. The accessibility
 * behaviour a drawer owes the user is implemented explicitly here instead:
 *
 *   * focus moves into the drawer on open and returns to the trigger on close
 *   * Tab is trapped inside while open
 *   * Escape closes
 *   * the backdrop closes
 *   * role="dialog" + aria-modal + a real label
 *   * choosing a destination closes it
 *   * background scroll is locked
 */
export function MobileNav({
  open,
  onClose,
  role,
}: {
  open: boolean
  onClose: () => void
  role: AppRole | null
}) {
  const panelRef = useRef<HTMLDivElement>(null)
  const previouslyFocused = useRef<HTMLElement | null>(null)

  useEffect(() => {
    if (!open) return

    previouslyFocused.current = document.activeElement as HTMLElement | null
    const panel = panelRef.current
    panel?.querySelector<HTMLElement>('a, button')?.focus()

    const originalOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') {
        event.preventDefault()
        onClose()
        return
      }
      if (event.key !== 'Tab' || !panel) return

      const focusable = panel.querySelectorAll<HTMLElement>(
        'a[href], button:not([disabled]), input, select, textarea, [tabindex]:not([tabindex="-1"])',
      )
      if (focusable.length === 0) return
      const first = focusable[0]
      const last = focusable[focusable.length - 1]

      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault()
        first.focus()
      }
    }

    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = originalOverflow
      previouslyFocused.current?.focus()
    }
  }, [open, onClose])

  if (!open) return null

  return (
    <div className="fixed inset-0 z-50 lg:hidden">
      <div
        className="absolute inset-0 bg-foreground/40"
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label="Main navigation"
        className="absolute inset-y-0 left-0 flex w-80 max-w-[85vw] flex-col border-r bg-card shadow-lg"
      >
        <div className="flex h-header shrink-0 items-center justify-between border-b border-b-brand-strong/25 px-3">
          <span className="flex min-w-0 items-center gap-2">
            <BrandMark variant="mark" className="h-8 w-auto shrink-0" />
            <span className="truncate text-sm font-semibold tracking-tight">CNG Station Management</span>
          </span>
          <Button variant="ghost" size="icon" onClick={onClose} aria-label="Close navigation">
            <X className="h-4 w-4" aria-hidden="true" />
          </Button>
        </div>
        {/* Same brand keyline as the desktop sidebar, so the drawer reads as
          * the same product rather than a separate mobile skin. */}
        <div className="flex h-0.5 shrink-0" aria-hidden="true">
          <div className="w-2/3 bg-brand" />
          <div className="w-1/3 bg-brand-yellow" />
        </div>
        <div className="flex-1 overflow-y-auto">
          {/* Roomier rows here: this IS a touch-primary surface, so the 44px
              minimum applies, unlike the desktop sidebar. */}
          <div className="[&_a]:py-2.5">
            <SidebarNav role={role} onNavigate={onClose} />
          </div>
        </div>
      </div>
    </div>
  )
}

