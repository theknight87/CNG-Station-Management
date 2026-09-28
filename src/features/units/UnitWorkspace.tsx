import { Outlet, useParams } from 'react-router-dom'

import { EntityName, Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { usePublishBreadcrumbs } from '@/components/layout/breadcrumbContext'
import { PageContainer } from '@/components/layout/PageContainer'
import { ErrorState, LoadingState, NotFound, NotImplemented } from '@/components/states/AppStates'
import { AttentionBadge, EntityLink } from '@/features/hierarchy/HierarchyPieces'
import { useUnit } from '@/features/hierarchy/useHierarchy'
import { UnitTabs } from '@/features/units/UnitTabs'

/**
 * The Unit workspace: a compact technical header, routed sub-navigation, and
 * whichever section the URL names.
 *
 * The header carries ONLY fields the `units` table actually holds. Manufacturer
 * and model are deliberately absent: they live on the equipment records, and
 * copying a compressor's manufacturer onto its Unit would attach a fact to the
 * wrong entity. Job Number IS genuinely Unit-level, so it appears here.
 *
 * A Unit the caller cannot read is reported as not found, indistinguishably
 * from one that does not exist — the loader returns null for both, and the
 * screen never learns which. Nothing is fetched and then hidden.
 */
export function UnitWorkspace() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnit(unitId)
  const unitRow = state.status === 'ready' ? state.data : null

  // Real entity labels, published only once the Unit has actually loaded.
  // A UUID from the URL is never shown as a name, and nothing is guessed while
  // the query is in flight.
  usePublishBreadcrumbs(
    unitRow
      ? [
          { label: 'Regions', to: '/regions' },
          { label: unitRow.region_name, to: `/regions/${unitRow.region_id}` },
          { label: unitRow.station_name, to: `/stations/${unitRow.station_id}`, isEntity: true },
          { label: unitRow.unit_name, isEntity: true },
        ]
      : null,
  )

  if (state.status === 'loading') return <PageContainer><LoadingState label="Loading Unit" /></PageContainer>
  if (state.status === 'unconfigured')
    return <PageContainer><NotImplemented feature="Unit detail" phase="waiting on database configuration" /></PageContainer>
  if (state.status === 'error')
    return <PageContainer><ErrorState message={state.message} onRetry={reload} /></PageContainer>

  const unit = state.data
  if (!unit) {
    return (
      <PageContainer>
        <NotFound
          what="Unit"
          detail="This Unit does not exist, or it is outside the Regions you are authorized for."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      {/* Compact identity strip. One line of hierarchy, one line of identity -
        * an engineer needs to know where they are without losing a screen of
        * table to a header (§11.4: no oversized banners). */}
      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-1.5">
        <div className="min-w-0">
          <h1 className="truncate text-base font-semibold tracking-tight">
            <EntityName name={unit.unit_name} />
          </h1>
          <p className="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-0.5 text-sm text-muted-foreground">
            <EntityLink to={`/stations/${unit.station_id}`}>
              <EntityName name={unit.station_name} />
            </EntityLink>
            <span aria-hidden="true">·</span>
            <span>{unit.region_name} Region</span>
            <span aria-hidden="true">·</span>
            <span className="inline-flex items-center gap-1">
              Job number{' '}
              {unit.job_number ? <Identifier value={unit.job_number} /> : <NullValue />}
            </span>
          </p>
        </div>
        <AttentionBadge overdue={unit.overdue} unresolved={0} />
      </div>

      <UnitTabs unitId={unit.unit_id} summary={state} />

      {/* Each section owns its own loading, empty and error states. */}
      <Outlet context={unit} />
    </PageContainer>
  )
}
