import { Link } from 'react-router-dom'

import { RegionChip } from '@/components/data/AssetChips'
import { regionTone } from '@/components/data/assetColors'
import { cn } from '@/lib/utils'
import { DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll, RowHeaderCell } from '@/components/data/DataTable'
import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState, NotImplemented } from '@/components/states/AppStates'
import { AttentionBadge, Count } from '@/features/hierarchy/HierarchyPieces'
import { useRegions } from '@/features/hierarchy/useHierarchy'

/**
 * Regions overview — the top of the physical hierarchy
 * (Region → Station → Unit → Equipment → SRV).
 *
 * Only Regions the caller is authorized for appear, and that is decided by RLS
 * in PostgreSQL, not here. A Region the caller cannot read produces no row, so
 * its name, its station count and its very existence stay invisible.
 *
 * Counts come from `v_dashboard_region_summary` — the same view the Dashboard
 * reads — so "overdue" cannot mean one thing on the Dashboard and another
 * here.
 */
export function RegionsView() {
  const { state, reload } = useRegions()

  return (
    <PageContainer>
      <PageHeader
        title="Regions"
        description="The canonical Regions you are authorized for, and the Stations within them."
      />

      {state.status === 'loading' ? <LoadingState label="Loading Regions" /> : null}

      {state.status === 'unconfigured' ? (
        <NotImplemented feature="Regions" phase="waiting on database configuration" />
      ) : null}

      {state.status === 'error' ? (
        // Never a zero row. A failed query says so.
        <ErrorState message={state.message} onRetry={reload} />
      ) : null}

      {state.status === 'ready' && state.data.length === 0 ? (
        <EmptyState
          title="No Regions are visible to you"
          description="Region access is granted by an administrator. If you expect to see Regions here, ask one to review your access."
        />
      ) : null}

      {state.status === 'ready' && state.data.length > 0 ? (
        <TableScroll label="Regions">
          <DataTable caption="Regions with their Station, Unit and asset counts">
            <TableHead>
              <TableRow>
                <TableHeader>Region</TableHeader>
                <TableHeader align="right">Stations</TableHeader>
                <TableHeader align="right">Units</TableHeader>
                <TableHeader align="right">Assets</TableHeader>
                <TableHeader align="right">Overdue</TableHeader>
                <TableHeader align="right">Due ≤60d</TableHeader>
                <TableHeader align="right">Unresolved</TableHeader>
                <TableHeader>Attention</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {state.data.map((region) => (
                <TableRow key={region.region_id}>
                  {/* Each Region keeps one colour across the product (owner request 2026-09-29): the edge of its
                    * row and its chip. The name is always written, so colour is never the only signal. */}
                  <RowHeaderCell className={cn('border-l-4', regionTone(region.region_name).stripe)}>
                    <Link
                      to={`/regions/${region.region_id}`}
                      aria-label={region.region_name}
                      className="inline-flex rounded-full underline-offset-4 transition-shadow hover:underline hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
                    >
                      <RegionChip name={region.region_name} size="md" />
                    </Link>
                  </RowHeaderCell>
                  <TableCell align="right" numeric><Count value={region.stations} /></TableCell>
                  <TableCell align="right" numeric><Count value={region.units} /></TableCell>
                  <TableCell align="right" numeric><Count value={region.assets} /></TableCell>
                  <TableCell align="right" numeric><Count value={region.overdue} tone="overdue" /></TableCell>
                  <TableCell align="right" numeric><Count value={region.approaching_due} tone="due" /></TableCell>
                  <TableCell align="right" numeric>
                    <Count value={region.unresolved_mapping} tone="unmapped" />
                  </TableCell>
                  <TableCell>
                    <AttentionBadge overdue={region.overdue} unresolved={region.unresolved_mapping} />
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      ) : null}
    </PageContainer>
  )
}
