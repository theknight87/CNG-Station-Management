import { useEffect, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { X } from 'lucide-react'

import { Button } from '@/components/ui/button'

export function RecordDetailsDialog({
  open, title, description, children, actions, onClose,
}: {
  open: boolean
  title: string
  description?: string
  children: ReactNode
  actions?: ReactNode
  onClose: () => void
}) {
  const dialogRef = useRef<HTMLElement>(null)
  // Held in a ref so a parent passing a fresh callback each render does not
  // re-run the effect, which would bounce focus and lose the opener.
  const onCloseRef = useRef(onClose)
  useEffect(() => {
    onCloseRef.current = onClose
  }, [onClose])

  useEffect(() => {
    if (!open) return
    // A modal dialog owns focus: it moves in on open, Tab cycles inside it,
    // and it returns to whatever opened the dialog on close. Without this a
    // keyboard or screen-reader user stays behind the backdrop.
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
    const focusables = () => [...(dialogRef.current?.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    ) ?? [])]
    dialogRef.current?.focus()

    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        onCloseRef.current()
        return
      }
      if (event.key !== 'Tab') return
      const items = focusables()
      if (items.length === 0) {
        event.preventDefault()
        return
      }
      const first = items[0]
      const last = items[items.length - 1]
      const active = document.activeElement
      if (event.shiftKey && (active === first || active === dialogRef.current)) {
        event.preventDefault()
        last.focus()
      } else if (!event.shiftKey && active === last) {
        event.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKey)
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = previous
      if (opener?.isConnected) opener.focus()
    }
  }, [open])

  if (!open) return null
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/45 p-3 sm:p-6" onMouseDown={onClose}>
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="record-dialog-title"
        ref={dialogRef}
        tabIndex={-1}
        className="flex max-h-[88vh] w-full max-w-4xl flex-col overflow-hidden rounded-lg border bg-background shadow-2xl"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="flex items-start justify-between gap-4 border-b px-4 py-3 sm:px-5">
          <div className="min-w-0">
            <h2 id="record-dialog-title" className="break-words text-lg font-semibold tracking-tight">{title}</h2>
            {description ? <p className="mt-0.5 text-sm text-muted-foreground">{description}</p> : null}
          </div>
          <Button type="button" variant="ghost" size="icon" aria-label="Close details" onClick={onClose}>
            <X className="h-4 w-4" aria-hidden="true" />
          </Button>
        </header>
        <div className="overflow-y-auto px-4 py-4 sm:px-5">{children}</div>
        {actions ? <footer className="flex flex-wrap justify-end gap-2 border-t px-4 py-3 sm:px-5">{actions}</footer> : null}
      </section>
    </div>,
    document.body,
  )
}

export function DetailGrid({ children }: { children: ReactNode }) {
  return <dl className="grid overflow-hidden rounded-lg border bg-card sm:grid-cols-2 lg:grid-cols-3">{children}</dl>
}

export function DetailItem({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="min-w-0 border-b p-3 sm:border-r">
      <dt className="text-xs font-bold leading-5 text-muted-foreground">{label}</dt>
      <dd className="mt-1 break-words text-sm leading-5 text-foreground">{children}</dd>
    </div>
  )
}

