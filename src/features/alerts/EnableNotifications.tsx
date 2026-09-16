import { Bell, BellOff, Check } from 'lucide-react'

import { Button } from '@/components/ui/button'
import { usePushNotifications } from '@/features/alerts/usePushNotifications'

/**
 * The Web Push opt-in control.
 *
 * DELIBERATELY EXPLICIT. Nothing here runs on page load: the browser is asked
 * for permission only when this button is clicked. A user who never clicks is
 * never subscribed, and a user who declines is told so plainly rather than
 * being asked again.
 *
 * WORDING IS CALM. Push here carries scheduled due dates, not emergencies, so
 * the control says "Enable notifications" and the states read as information.
 * No siren, no red, no urgency the data does not carry.
 *
 * Every state is handled, because a control that silently does nothing when
 * push is unsupported or unconfigured is worse than one that says why.
 */
export function EnableNotifications() {
  const { state, enable } = usePushNotifications()

  // Nothing actionable in these two cases, so say so quietly rather than
  // offering a button that cannot work.
  if (state.status === 'unsupported') {
    return (
      <p className="text-xs text-muted-foreground">
        This browser does not support push notifications. Alerts are always available on this page.
      </p>
    )
  }
  if (state.status === 'unconfigured') {
    return (
      <p className="text-xs text-muted-foreground">
        Push notifications are not configured for this deployment. Alerts are always available on this page.
      </p>
    )
  }

  if (state.status === 'subscribed') {
    return (
      <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <Check className="h-3.5 w-3.5 text-status-ok" aria-hidden="true" />
        Notifications are enabled in this browser.
      </p>
    )
  }

  if (state.status === 'denied') {
    return (
      <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <BellOff className="h-3.5 w-3.5" aria-hidden="true" />
        Notifications are blocked for this site. You can re-enable them in your browser settings.
      </p>
    )
  }

  return (
    <div className="flex flex-wrap items-center gap-2">
      <Button
        variant="outline"
        size="sm"
        className="h-7"
        disabled={state.status === 'working'}
        onClick={() => void enable()}
      >
        <Bell className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
        {state.status === 'working' ? 'Enabling…' : 'Enable notifications'}
      </Button>
      {state.status === 'error' ? (
        <span role="alert" className="text-xs text-status-overdue">
          Could not enable notifications: {state.message}
        </span>
      ) : (
        <span className="text-xs text-muted-foreground">
          Optional. Sends this browser a notice when an alert is raised for you.
        </span>
      )}
    </div>
  )
}
