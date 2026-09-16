import { useCallback } from 'react'

import { Button } from '@/components/ui/button'
import {
  THRESHOLD_CHOICES, useNotificationPreferences,
  type NotificationChannel,
} from '@/features/alerts/useNotificationPreferences'

/**
 * Per-user notification preferences.
 *
 * NOBODY IS SUBSCRIBED UNTIL THEY SAY SO. The delivery engine only enqueues for
 * users who hold an enabled preference row, so an account with nothing set here
 * receives nothing. This screen is the only thing that changes that, which is
 * why it states the position plainly rather than presenting two switches and
 * leaving the user to infer the default.
 *
 * REGION IS ABSENT BY DESIGN, and that absence is explained on screen rather
 * than left as a missing feature: which Regions reach you is your authorization,
 * not your preference.
 *
 * Saving is per row and immediate. A single "Save" for the whole page would
 * invite the reading that an unsaved toggle is already in force — on a control
 * that decides whether you are told about an overdue safety valve, that is the
 * wrong ambiguity to introduce.
 */
const CHANNELS: { key: NotificationChannel; label: string; note: string }[] = [
  {
    key: 'email',
    label: 'Email',
    note: 'Sent to the address on your account.',
  },
  {
    key: 'web_push',
    label: 'Browser notifications',
    note: 'Also requires enabling notifications in each browser, on the Alerts page.',
  },
]

export function NotificationPreferences() {
  const { prefs, error, saving, save } = useNotificationPreferences()

  const onToggle = useCallback(
    (channel: NotificationChannel) => {
      if (!prefs) return
      void save(channel, {
        isEnabled: !prefs[channel].isEnabled,
        minThreshold: prefs[channel].minThreshold,
      })
    },
    [prefs, save],
  )

  const onThreshold = useCallback(
    (channel: NotificationChannel, value: string) => {
      if (!prefs) return
      void save(channel, { isEnabled: prefs[channel].isEnabled, minThreshold: value })
    },
    [prefs, save],
  )

  if (error) {
    return (
      <p role="alert" className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
        Could not load your notification preferences: {error}
      </p>
    )
  }

  if (!prefs) {
    return <p className="text-sm text-muted-foreground">Loading your notification preferences…</p>
  }

  return (
    <section className="flex min-w-0 flex-col gap-3">
      <div className="rounded border bg-card">
        <table className="w-full text-sm">
          <thead>
            <tr className="border-b text-left text-xs uppercase tracking-wide text-muted-foreground">
              <th scope="col" className="px-3 py-2 font-medium">Channel</th>
              <th scope="col" className="px-3 py-2 font-medium">Send me</th>
              <th scope="col" className="px-3 py-2 font-medium">Status</th>
            </tr>
          </thead>
          <tbody>
            {CHANNELS.map(({ key, label, note }) => (
              <tr key={key} className="border-b last:border-0 align-top">
                <th scope="row" className="px-3 py-2 text-left font-medium">
                  {label}
                  <span className="block text-xs font-normal text-muted-foreground">{note}</span>
                </th>
                <td className="px-3 py-2">
                  <label className="sr-only" htmlFor={`threshold-${key}`}>
                    Minimum urgency for {label}
                  </label>
                  <select
                    id={`threshold-${key}`}
                    className="h-7 rounded border bg-background px-2 text-sm"
                    value={prefs[key].minThreshold}
                    disabled={!prefs[key].isEnabled || saving}
                    onChange={(e) => onThreshold(key, e.target.value)}
                  >
                    {THRESHOLD_CHOICES.map((c) => (
                      <option key={c.value} value={c.value}>{c.label}</option>
                    ))}
                  </select>
                </td>
                <td className="px-3 py-2">
                  <Button
                    variant="outline"
                    size="sm"
                    className="h-7"
                    disabled={saving}
                    aria-pressed={prefs[key].isEnabled}
                    onClick={() => onToggle(key)}
                  >
                    {prefs[key].isEnabled ? 'On — turn off' : 'Off — turn on'}
                  </Button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-muted-foreground">
        With a channel off, nothing is sent on it. Which Regions you are notified about is set by
        your access, not here — notifications never reach beyond the Regions you are authorized
        to see.
      </p>
    </section>
  )
}
