import { useEffect, type ReactNode } from 'react'
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
  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = previous
    }
  }, [open, onClose])

  if (!open) return null
  return createPortal(
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-950/45 p-3 sm:p-6" onMouseDown={onClose}>
      <section
        role="dialog"
        aria-modal="true"
        aria-labelledby="record-dialog-title"
        className="flex max-h-[88vh] w-full max-w-4xl flex-col overflow-hidden rounded-lg border bg-background shadow-2xl"
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="flex items-start justify-between gap-4 border-b px-4 py-3 sm:px-5">
          <div className="min-w-0">
            <h2 id="record-dialog-title" className="truncate text-lg font-semibold tracking-tight">{title}</h2>
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

