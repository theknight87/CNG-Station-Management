import { Link } from 'react-router-dom'

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
                  <RowHeaderCell>
                    <Link
                      to={`/regions/${region.region_id}`}
                      className="rounded font-medium text-brand-strong underline-offset-4 hover:underline"
                    >
                      {region.region_name}
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
