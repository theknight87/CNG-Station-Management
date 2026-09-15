import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { DueBadge, PrecisionDate, Serial } from '@/features/units/assetDisplay'
import { useRelatedSrvs } from '@/features/vessels/useVesselManagement'

/**
 * Relief valves whose equipment parent IS this storage vessel.
 *
 * ONLY A PROVEN RELATIONSHIP. These come from the confirmed foreign key, never
 * from source text: a valve whose `Location` says "Storage" has no
 * `storage_vessel_id` and does not appear here. "Storage" is a parent-KIND
 * hint — it says the parent is *a* storage vessel, not *which* one.
 *
 * Rendered only when a row is expanded, so this is one query for one vessel,
 * never one per table row.
 */
export function RelatedSrvs({ vesselId }: { vesselId: string }) {
  const { state } = useRelatedSrvs(vesselId)

  return (
    <div className="col-span-full mt-1 border-t pt-2.5">
      <h3 className="mb-1.5 text-xs uppercase tracking-wide text-muted-foreground">
        Relief valves on this vessel
      </h3>

      {state.status === 'loading' ? (
        <p className="text-sm text-muted-foreground">Loading relief valves…</p>
      ) : null}

      {/* A failure says so. It never renders as "no valves", which would read
        * as a safety-relevant fact that has not actually been established. */}
      {state.status === 'error' ? (
        <p className="text-sm text-status-overdue">
          Relief valves for this vessel could not be loaded, so none are listed.
        </p>
      ) : null}

      {state.status === 'ready' && state.data.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          No relief valve has this vessel confirmed as its equipment parent. Valves whose source only says
          &ldquo;Storage&rdquo; are not counted here — that text names a kind of parent, not this vessel.
        </p>
      ) : null}

      {state.status === 'ready' && state.data.length > 0 ? (
        <ul className="flex flex-col gap-1">
          {state.data.map((srv) => (
            <li key={srv.id} className="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-sm">
              <Serial value={srv.serial_number} status={srv.serial_status} />
              {srv.part_number ? (
                <span className="text-xs text-muted-foreground">
                  P/N <Identifier value={srv.part_number} />
                </span>
              ) : null}
              {srv.tag_number ? (
                <span className="text-xs text-muted-foreground">
                  Tag <Identifier value={srv.tag_number} />
                </span>
              ) : null}
              <span className="text-xs text-muted-foreground">
                Next calibration{' '}
                {srv.next_calibration_display ? (
                  <PrecisionDate
                    display={srv.next_calibration_display}
                    precision={srv.next_calibration_precision}
                  />
                ) : (
                  <NullValue />
                )}
              </span>
              <DueBadge status={srv.due_status} />
            </li>
          ))}
        </ul>
      ) : null}
    </div>
  )
}
