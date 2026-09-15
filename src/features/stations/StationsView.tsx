import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { StationsBrowser } from '@/features/hierarchy/StationsBrowser'

/**
 * All Stations the caller is authorized for, across every Region.
 *
 * The browsing, filtering and paging all live in `StationsBrowser`, which the
 * Region detail page reuses with its Region locked.
 */
export function StationsView() {
  return (
    <PageContainer>
      <PageHeader
        title="Stations"
        description="Every Station in the Regions you are authorized for. Search by name, filter by Region or attention state."
      />
      <StationsBrowser />
    </PageContainer>
  )
}
