import { screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

/** The ≤30-day group (overdue up to 30 days), as the due filter lists it. */
export const ATTENTION_LABELS = ['Overdue', 'Due today', 'Due ≤7d', 'Due ≤15d', 'Due ≤30d']

/**
 * Picks values in a MultiSelectFilter the way a person does: open it, optionally switch to "All except", tick each
 * option by its label, close it.
 */
export async function pickMulti(label: string, options: string[], opts: { exclude?: boolean } = {}) {
  const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  await userEvent.click(screen.getByRole('button', { name: new RegExp(`^${escaped}:`, 'i') }))
  const dialog = screen.getByRole('dialog', { name: new RegExp(`^${escaped} filter$`, 'i') })
  if (opts.exclude) await userEvent.click(within(dialog).getByRole('button', { name: 'All except' }))
  for (const o of options) await userEvent.click(within(dialog).getByRole('checkbox', { name: o }))
  await userEvent.keyboard('{Escape}')
}
