import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { LogOut } from 'lucide-react'

import '../src/index.css'
import { AccountControl } from '@/components/layout/AccountControl'
import {
  DataQualityPanel,
  DueMatrix,
  RegionOverview,
  SummaryStrip,
  WarehousePanel,
} from '@/features/dashboard/DashboardPanels'
import { ATTENTION_STATUSES } from '@/features/dashboard/dueBuckets'
import { dueTotal, mappingTotal } from '@/features/dashboard/useDashboard'
import type { DueRow, MappingRow, RegionRow } from '@/features/dashboard/useDashboard'
import { AppShell } from '@/components/layout/AppShell'
import { DataToolbar, PageContainer, PageHeader, SectionHeader } from '@/components/layout/PageContainer'
import { DateValue } from '@/components/data/DateValue'
import { EntityName, Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import {
  DataTable,
  RowHeaderCell,
  SortableHeader,
  TableBody,
  TableCell,
  TableHead,
  TableRow,
  TableScroll,
} from '@/components/data/DataTable'
import { EmptyState, ErrorState, LoadingState, NoResultsState, PermissionDenied } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import type { AppRole } from '@/types/domain'

/**
 * DEV-ONLY visual verification harness. NOT part of the application build.
 *
 * It exists because this environment's egress policy blocks Clerk, so the
 * authenticated shell cannot be reached in a browser here. Rather than claim
 * visual verification that did not happen, this mounts the REAL shell, the REAL
 * navigation and the REAL primitives with a stubbed account, so what a browser
 * renders is the actual component tree and not a mock-up of it.
 *
 * The sample values below are DISPLAY FIXTURES for layout inspection only. They
 * are never imported by the application, never written anywhere, and exercise
 * precisely the cases that are easy to get wrong: an Arabic name, a mixed
 * Arabic/Latin string, a long identifier, a NULL, and a year-only date.
 */

/**
 * VISUAL FIXTURES — dev harness only.
 *
 * These exist so the populated dashboard can be inspected in a browser while
 * the canonical tables are still empty. They are NOT production data: they are
 * never written to Supabase, never imported by the application, and the
 * production bundle is verified to exclude this file entirely.
 *
 * The real dashboard against the real database shows zeros, and that result is
 * reported separately.
 */
const FIXTURE_REGIONS: RegionRow[] = [
  { region_id: 'f1', region_code: 'east',  region_name: 'East',  sort_order: 1, stations: 42, units: 61, assets: 1180, overdue: 47, approaching_due: 133, unresolved_mapping: 612 },
  { region_id: 'f2', region_code: 'west',  region_name: 'West',  sort_order: 2, stations: 40, units: 58, assets: 964,  overdue: 31, approaching_due: 98,  unresolved_mapping: 444 },
  { region_id: 'f3', region_code: 'canal', region_name: 'Canal', sort_order: 3, stations: 18, units: 0,  assets: 233,  overdue: 9,  approaching_due: 22,  unresolved_mapping: 233 },
  { region_id: 'f4', region_code: 'delta', region_name: 'Delta', sort_order: 4, stations: 75, units: 69, assets: 1402, overdue: 58, approaching_due: 171, unresolved_mapping: 690 },
  { region_id: 'f5', region_code: 'alex',  region_name: 'Alex',  sort_order: 5, stations: 11, units: 0,  assets: 96,   overdue: 2,  approaching_due: 7,   unresolved_mapping: 96 },
  { region_id: 'f6', region_code: 'upper', region_name: 'Upper', sort_order: 6, stations: 24, units: 0,  assets: 318,  overdue: 14, approaching_due: 41,  unresolved_mapping: 318 },
]

const FIXTURE_DUE: DueRow[] = [
  { asset_kind: 'installed_relief_valve', due_status: 'overdue',   total: 118 },
  { asset_kind: 'installed_relief_valve', due_status: 'due_today', total: 3 },
  { asset_kind: 'installed_relief_valve', due_status: 'due_7',     total: 21 },
  { asset_kind: 'installed_relief_valve', due_status: 'due_15',    total: 34 },
  { asset_kind: 'installed_relief_valve', due_status: 'due_30',    total: 66 },
  { asset_kind: 'installed_relief_valve', due_status: 'due_60',    total: 104 },
  { asset_kind: 'installed_relief_valve', due_status: 'valid',     total: 2150 },
  { asset_kind: 'installed_relief_valve', due_status: 'unknown',   total: 166 },
  { asset_kind: 'storage_vessel',  due_status: 'overdue', total: 41 },
  { asset_kind: 'storage_vessel',  due_status: 'due_30',  total: 18 },
  { asset_kind: 'storage_vessel',  due_status: 'valid',   total: 603 },
  { asset_kind: 'storage_vessel',  due_status: 'unknown', total: 9 },
  { asset_kind: 'recovery_tank',   due_status: 'overdue', total: 26 },
  { asset_kind: 'recovery_tank',   due_status: 'valid',   total: 495 },
  { asset_kind: 'recovery_tank',   due_status: 'unknown', total: 7 },
  { asset_kind: 'gas_detector',    due_status: 'overdue', total: 12 },
  { asset_kind: 'gas_detector',    due_status: 'due_60',  total: 15 },
  { asset_kind: 'gas_detector',    due_status: 'valid',   total: 149 },
  { asset_kind: 'gas_detector',    due_status: 'unknown', total: 2 },
  { asset_kind: 'hose',            due_status: 'due_15',  total: 6 },
  { asset_kind: 'hose',            due_status: 'valid',   total: 65 },
]

const FIXTURE_MAPPING: MappingRow[] = [
  { asset_kind: 'installed_relief_valve', mapping_status: 'needs_station_mapping',   total: 1599 },
  { asset_kind: 'installed_relief_valve', mapping_status: 'needs_unit_mapping',      total: 262 },
  { asset_kind: 'installed_relief_valve', mapping_status: 'needs_equipment_mapping', total: 801 },
  { asset_kind: 'storage_vessel',         mapping_status: 'needs_station_mapping',   total: 433 },
  { asset_kind: 'gas_detector',           mapping_status: 'conflict',                total: 3 },
]

function DashboardFixture() {
  return (
    <div className="space-y-4">
      <SummaryStrip
        assets={[
          { asset_kind: 'station', total: 210 },
          { asset_kind: 'unit', total: 188 },
          { asset_kind: 'installed_relief_valve', total: 2662 },
          { asset_kind: 'storage_vessel', total: 671 },
          { asset_kind: 'recovery_tank', total: 528 },
          { asset_kind: 'gas_detector', total: 178 },
          { asset_kind: 'hose', total: 71 },
        ]}
        overdueTotal={dueTotal(FIXTURE_DUE, ['overdue'])}
        attentionTotal={dueTotal(FIXTURE_DUE, ATTENTION_STATUSES)}
        unresolvedTotal={mappingTotal(FIXTURE_MAPPING)}
      />
      <DueMatrix due={FIXTURE_DUE} />
      <RegionOverview regions={FIXTURE_REGIONS} />
      <div className="grid gap-4 xl:grid-cols-2">
        <DataQualityPanel mapping={FIXTURE_MAPPING} />
        <WarehousePanel warehouse={{ total: 2188, overdue: 37, approaching_due: 94 }} />
      </div>
    </div>
  )
}

function Preview() {
  const [role, setRole] = useState<AppRole>('admin')
  const view = new URLSearchParams(window.location.search).get('view')

  return (
    <AppShell
      role={role}
      crumbs={[
        { label: 'Stations', to: '/stations' },
        { label: 'East', to: '/regions/east' },
        { label: 'الماظة', isEntity: true },
        { label: 'الماظة 1', isEntity: true },
        { label: 'Compressor' },
      ]}
      account={
        <AccountControl
          displayName="Eng/Eslam Fares"
          role={role}
          signOut={
            <Button variant="ghost" size="icon" aria-label="Sign out">
              <LogOut className="h-4 w-4" aria-hidden="true" />
            </Button>
          }
        />
      }
    >
      <PageContainer>
        {view === 'dashboard' ? <DashboardFixture /> : null}
        {view === 'dashboard' ? null : <>
        <PageHeader
          title="Shell preview"
          description="Dev-only harness. Renders the real shell and primitives with a stubbed account."
          actions={
            <div className="flex items-center gap-1">
              {(['admin', 'manager', 'engineer', 'viewer'] as AppRole[]).map((r) => (
                <Button
                  key={r}
                  size="sm"
                  variant={role === r ? 'default' : 'outline'}
                  onClick={() => setRole(r)}
                >
                  {r}
                </Button>
              ))}
            </div>
          }
        />

        <SectionHeader title="Technical table" description="Density, sticky header, overflow, mixed direction" />
        <DataToolbar label="Filter relief valves" trailing={<Button size="sm" variant="outline">Clear</Button>}>
          <span className="text-xs text-muted-foreground">Region: East</span>
          <span className="text-xs text-muted-foreground">Status: all</span>
        </DataToolbar>

        <TableScroll label="Relief valves" className="max-h-72">
          <DataTable caption="Sample relief valves, for layout inspection only">
            <TableHead>
              <TableRow>
                <SortableHeader sort="asc" onSort={() => {}}>Station</SortableHeader>
                <SortableHeader onSort={() => {}}>Unit</SortableHeader>
                <SortableHeader>Serial</SortableHeader>
                <SortableHeader>Manufacturer</SortableHeader>
                <SortableHeader align="right">Set pressure</SortableHeader>
                <SortableHeader>Next calibration</SortableHeader>
                <SortableHeader>Mapping</SortableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              <TableRow>
                <RowHeaderCell><EntityName name="الماظة" /></RowHeaderCell>
                <TableCell><EntityName name="الماظة 1" /></TableCell>
                <TableCell><Identifier value="EKC/DXB/MGNC/275/DN-25-VM/309" /></TableCell>
                <TableCell>EKC</TableCell>
                <TableCell align="right" numeric>275–344 BAR</TableCell>
                <TableCell><DateValue date={{ value: '2026-08-08', precision: 'exact_date', raw: '8/8/2026', year: 2026 }} /></TableCell>
                <TableCell><StatusBadge kind="ok" label="Resolved" /></TableCell>
              </TableRow>
              <TableRow selected>
                <RowHeaderCell><EntityName name="طاليــا / أشــمون 2" /></RowHeaderCell>
                <TableCell><NullValue label="unit not confirmed" /></TableCell>
                <TableCell><Identifier value={null} /></TableCell>
                <TableCell>Mercer</TableCell>
                <TableCell align="right" numeric>30 PSI</TableCell>
                <TableCell><DateValue date={{ value: null, precision: 'year_only', raw: '2022', year: 2022 }} /></TableCell>
                <TableCell><StatusBadge kind="unmapped" label="Needs station mapping" /></TableCell>
              </TableRow>
              <TableRow>
                <RowHeaderCell><EntityName name="شبرا 4" /></RowHeaderCell>
                <TableCell><EntityName name="شبرا 4" /></TableCell>
                <TableCell><Identifier value="007123" /></TableCell>
                <TableCell><NullValue /></TableCell>
                <TableCell align="right" numeric>1803.02075</TableCell>
                <TableCell><DateValue date={{ value: null, precision: 'invalid', raw: 'منتهية', year: null, sourceStatusRaw: 'منتهية' }} /></TableCell>
                <TableCell><StatusBadge kind="overdue" /></TableCell>
              </TableRow>
            </TableBody>
          </DataTable>
        </TableScroll>

        <SectionHeader title="Status vocabulary" />
        <div className="flex flex-wrap gap-1.5">
          <StatusBadge kind="ok" />
          <StatusBadge kind="due_soon" />
          <StatusBadge kind="due" />
          <StatusBadge kind="overdue" />
          <StatusBadge kind="unmapped" />
          <StatusBadge kind="conflict" />
          <StatusBadge kind="inactive" />
          <StatusBadge kind="info" />
        </div>

        <SectionHeader title="Application states" />
        <div className="grid gap-3 lg:grid-cols-2">
          <LoadingState />
          <EmptyState description="No relief valves have been imported yet." />
          <NoResultsState onClear={() => {}} />
          <ErrorState message="The database refused the request." onRetry={() => {}} />
          <PermissionDenied what="administration" />
        </div>
        </>}
      </PageContainer>
    </AppShell>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MemoryRouter initialEntries={['/manage/srvs']}>
      <Preview />
    </MemoryRouter>
  </StrictMode>,
)
