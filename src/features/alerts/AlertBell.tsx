import { Bell } from 'lucide-react'
import { Link } from 'react-router-dom'

import { useUnreadAlertCount } from '@/features/alerts/useAlerts'

/**
 * The notification bell.
 *
 * DELIBERATELY A LINK, NOT A DROPDOWN. A popover would be a second, smaller
 * alerts inbox — a different filter set, a different column order, and a second
 * place to keep correct. `/alerts` already answers every question this product
 * asks of an alert, so the bell's whole job is to say "there is something to
 * read" and take you to the one screen that shows it (§11.4: no decorative
 * duplication of a working surface).
 *
 * THE COUNT IS UNREAD, NOT UNACKNOWLEDGED. Those are different facts and this
 * product keeps them apart everywhere: read is "I have seen this", acknowledged
 * is an operational act recorded against the alert with a server-derived actor.
 * A badge counting acknowledgements would quietly invite the reading that
 * clearing the badge discharges the duty.
 *
 * It is scoped by RLS, not by the client: `v_alert_inbox` is security_invoker,
 * so the number can never hint at an alert in a Region the viewer may not read.
 *
 * WHEN THE COUNT IS UNKNOWN, NOTHING IS SHOWN. A failed request leaves the
 * count null and the badge hidden rather than rendering a confident `0`, which
 * would be a fabricated value standing in for missing data (§11.5).
 */
export function AlertBell() {
  const { count } = useUnreadAlertCount()
  const unread = count !== null && count > 0
  const visibleCount = unread ? (count > 99 ? '99+' : String(count)) : null

  return (
    <Link
      to="/alerts"
      className="relative inline-flex h-8 w-8 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-accent hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-strong"
      aria-label={
        unread
          ? `Alerts — ${visibleCount} unread${count > 99 ? `; exact count ${count}` : ''}`
          : 'Alerts'
      }
    >
      <Bell className="h-4 w-4" aria-hidden="true" />
      {unread ? (
        <span
          // Capped for layout, and the exact number stays in the aria-label so
          // a screen-reader user is never told "99+".
          className="absolute -right-0.5 -top-0.5 min-w-[1rem] rounded-full bg-status-overdue px-1 text-[10px] font-medium leading-4 text-white tabular"
          aria-hidden="true"
        >
          {visibleCount}
        </span>
      ) : null}
    </Link>
  )
}
