import { describe, expect, it } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'

/** An opener button plus the dialog, with one focusable action inside. */
function Harness({ title = 'Record' }: { title?: string }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>Open record</button>
      <RecordDetailsDialog
        open={open}
        title={title}
        // A fresh callback every render, as real callers pass: focus must not bounce.
        onClose={() => setOpen(false)}
        actions={<button type="button">Acknowledge</button>}
      >
        <p>Body</p>
      </RecordDetailsDialog>
    </>
  )
}

describe('RecordDetailsDialog focus management', () => {
  it('DIALOG-1 moves focus into the dialog when it opens', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await user.click(screen.getByRole('button', { name: 'Open record' }))
    expect(screen.getByRole('dialog')).toBe(document.activeElement)
  })

  it('DIALOG-2 keeps Tab inside the dialog in both directions', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    await user.click(screen.getByRole('button', { name: 'Open record' }))
    const close = screen.getByRole('button', { name: 'Close details' })
    const ack = screen.getByRole('button', { name: 'Acknowledge' })
    await user.tab()
    expect(document.activeElement).toBe(close)
    await user.tab()
    expect(document.activeElement).toBe(ack)
    await user.tab() // wraps from the last control to the first
    expect(document.activeElement).toBe(close)
    await user.tab({ shift: true }) // and back from the first to the last
    expect(document.activeElement).toBe(ack)
  })

  it('DIALOG-3 Escape closes it and returns focus to the control that opened it', async () => {
    const user = userEvent.setup()
    render(<Harness />)
    const opener = screen.getByRole('button', { name: 'Open record' })
    await user.click(opener)
    // Work inside the dialog first, so focus has genuinely left the opener
    // and returning it is something the dialog must do.
    await user.tab()
    await user.tab()
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Acknowledge' }))
    await user.keyboard('{Escape}')
    expect(screen.queryByRole('dialog')).toBeNull()
    expect(document.activeElement).toBe(opener)
  })

  it('DIALOG-4 never truncates the title, so a long Arabic name stays whole', async () => {
    const user = userEvent.setup()
    const name = 'محطة شبرا الخيمة للغاز الطبيعي المضغوط - الوحدة الثانية'
    render(<Harness title={name} />)
    await user.click(screen.getByRole('button', { name: 'Open record' }))
    const heading = screen.getByRole('heading', { name })
    expect(heading.className).not.toContain('truncate')
    expect(heading.textContent).toBe(name)
  })
})
