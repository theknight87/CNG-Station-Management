import { useParams } from 'react-router-dom'

import { usePublishBreadcrumbs } from '@/components/layout/breadcrumbContext'
import { PageContainer, PageHeader, SectionHeader } from '@/components/layout/PageContainer'
import { ErrorState, LoadingState, NotFound, NotImplemented } from '@/components/states/AppStates'
import { Count, Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { StationsBrowser } from '@/features/hierarchy/StationsBrowser'
import { useRegions } from '@/features/hierarchy/useHierarchy'

/**
 * One Region: its totals, and the Stations inside it.
 *
 * A Region the caller is not authorized for is not found here — deliberately
 * indistinguishable from a Region that does not exist. Saying "you are not
 * allowed to see Upper" would confirm that Upper exists and has data, which is
 * the disclosure RLS is there to prevent.
 */
export function RegionDetailView() {
  const { regionId } = useParams<{ regionId: string }>()
  const { state, reload } = useRegions()
  const loaded = state.status === 'ready' ? state.data.find((r) => r.region_id === regionId) : undefined

  usePublishBreadcrumbs(
    loaded ? [{ label: 'Regions', to: '/regions' }, { label: loaded.region_name }] : null,
  )

  if (state.status === 'loading') return <PageContainer><LoadingState label="Loading Region" /></PageContainer>
  if (state.status === 'unconfigured')
    return <PageContainer><NotImplemented feature="Regions" phase="waiting on database configuration" /></PageContainer>
  if (state.status === 'error')
    return <PageContainer><ErrorState message={state.message} onRetry={reload} /></PageContainer>

  const region = state.data.find((r) => r.region_id === regionId)
  if (!region) {
    return (
      <PageContainer>
        <NotFound
          what="Region"
          detail="This Region does not exist, or it is outside the Regions you are authorized for."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader title={region.region_name} description="Region totals and the Stations within it." />

      <section aria-labelledby="region-totals" className="rounded border bg-card p-3">
        <SectionHeader id="region-totals" title="Region totals" />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Stations"><Count value={region.stations} /></Fact>
            <Fact label="Units"><Count value={region.units} /></Fact>
            <Fact label="Assets"><Count value={region.assets} /></Fact>
            <Fact label="Overdue"><Count value={region.overdue} tone="overdue" /></Fact>
            <Fact label="Due ≤60d"><Count value={region.approaching_due} tone="due" /></Fact>
            <Fact label="Unresolved mapping">
              <Count value={region.unresolved_mapping} tone="unmapped" />
            </Fact>
          </FactGrid>
        </div>
      </section>

      <SectionHeader id="region-stations" title="Stations in this Region" />
      <StationsBrowser lockedRegionId={region.region_id} lockedRegionName={region.region_name} />
    </PageContainer>
  )
}
