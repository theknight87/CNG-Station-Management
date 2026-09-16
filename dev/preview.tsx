import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
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
import { BreadcrumbProvider } from '@/components/layout/BreadcrumbProvider'
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
import { RegionDetailView } from '@/features/regions/RegionDetailView'
import { RegionsView } from '@/features/regions/RegionsView'
import { StationOverview } from '@/features/stations/StationOverview'
import { StationsView } from '@/features/stations/StationsView'
import { SrvWorkspace } from '@/features/relief-valves/SrvWorkspace'
import { VesselWorkspace } from '@/features/vessels/VesselWorkspace'
import { GasDetectorsView } from '@/features/gas-detectors/GasDetectorsView'
import { HosesManagementView } from '@/features/hoses/HosesManagementView'
import { AlertsView } from '@/features/alerts/AlertsView'
import { VesselRegistrySection } from '@/features/vessels/sections/VesselRegistrySection'
import { InstalledSrvSection } from '@/features/relief-valves/sections/InstalledSrvSection'
import { WarehouseSrvSection } from '@/features/relief-valves/sections/WarehouseSrvSection'
import { UnitWorkspace } from '@/features/units/UnitWorkspace'
import { CompressorSection } from '@/features/units/sections/CompressorSection'
import { DetectorSection } from '@/features/units/sections/DetectorSection'
import { DispenserSection } from '@/features/units/sections/DispenserSection'
import { HoseSection } from '@/features/units/sections/HoseSection'
import { OverviewSection } from '@/features/units/sections/OverviewSection'
import { SrvSection } from '@/features/units/sections/SrvSection'
import { VesselSection } from '@/features/units/sections/VesselSection'
import type { AppRole } from '@/types/domain'

/**
 * The Prompt 9 hierarchy screens, mounted for their OWN sake.
 *
 * These are the real components with the real data hooks; only the Supabase
 * transport is stubbed (dev/supabaseStub.ts, aliased by
 * vite.preview.config.ts). So search, sorting, filtering, pagination, the
 * empty/filtered-empty/error branches and the Arabic rendering are all
 * genuinely exercised in a browser here, not mocked up.
 */
function HierarchyFixture({ view }: { view: string }) {
  if (view === 'regions') return <RegionsView />
  if (view === 'region') return <RegionDetailView />
  if (view === 'stations') return <StationsView />
  if (view === 'station') return <StationOverview />
  return null
}

const HIERARCHY_VIEWS = ['regions', 'region', 'stations', 'station', 'unit', 'srvs', 'vessels', 'detectors', 'hoses', 'alerts']

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

/**
 * The harness router needs an entry the detail routes can match, so the view
 * being inspected decides it.
 */
function previewEntry(): string {
  const v = new URLSearchParams(window.location.search).get('view')
  if (v === 'region') return '/regions/r-east'
  if (v === 'station') return '/stations/s-0'
  if (v === 'vessels') {
    const tab = new URLSearchParams(window.location.search).get('tab')
    return `/manage/vessels/${tab ?? 'storage'}`
  }
  if (v === 'detectors') return '/manage/gas-detectors'
  if (v === 'hoses') return '/manage/hoses'
  if (v === 'alerts') return '/alerts'
  if (v === 'srvs') {
    const tab = new URLSearchParams(window.location.search).get('tab')
    return `/manage/srvs/${tab ?? 'installed'}`
  }
  if (v === 'unit') {
    const tab = new URLSearchParams(window.location.search).get('tab')
    return tab ? `/units/u-1/${tab}` : '/units/u-1'
  }
  return '/manage/srvs'
}

function Preview() {
  const [role, setRole] = useState<AppRole>('admin')
  const view = new URLSearchParams(window.location.search).get('view')

  const fallbackCrumbs = [
        { label: 'Stations', to: '/stations' },
        { label: 'East', to: '/regions/east' },
        { label: 'الماظة', isEntity: true },
        { label: 'الماظة 1', isEntity: true },
    { label: 'Compressor' },
  ]

  return (
    // Same BreadcrumbProvider the application uses, so a screen that publishes
    // real entity crumbs is verified here rather than approximated.
    <BreadcrumbProvider>
      {(override) => (
    <AppShell
      role={role}
      crumbs={override ?? fallbackCrumbs}
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
      {/* The hierarchy screens bring their own PageContainer, so they are
        * mounted directly rather than nested inside the harness's one. */}
      {view && HIERARCHY_VIEWS.includes(view) ? (
        <Routes>
          <Route path="/regions/:regionId" element={<HierarchyFixture view={view} />} />
          <Route path="/stations/:stationId" element={<HierarchyFixture view={view} />} />
          {/* Same nested shape as the application, so the tab strip, the
            * Outlet and every deep link behave exactly as they do in
            * production rather than through a harness-only approximation. */}
          <Route path="/units/:unitId" element={<UnitWorkspace />}>
            <Route index element={<OverviewSection />} />
            <Route path="compressor" element={<CompressorSection />} />
            <Route path="recovery-tank" element={<VesselSection kind="recovery_tank" />} />
            <Route path="dispensers" element={<DispenserSection />} />
            <Route path="storage" element={<VesselSection kind="storage_vessel" />} />
            <Route path="gas-detectors" element={<DetectorSection />} />
            <Route path="hoses" element={<HoseSection />} />
            <Route path="srvs" element={<SrvSection />} />
          </Route>
          {/* Same nested shape as the application. */}
          <Route path="/manage/srvs" element={<SrvWorkspace />}>
            <Route index element={<InstalledSrvSection />} />
            <Route path="installed" element={<InstalledSrvSection />} />
            <Route path="warehouse" element={<WarehouseSrvSection />} />
          </Route>
          <Route path="/manage/vessels" element={<VesselWorkspace />}>
            <Route index element={<VesselRegistrySection assetType="storage_vessel" />} />
            <Route path="storage" element={<VesselRegistrySection assetType="storage_vessel" />} />
            <Route path="recovery" element={<VesselRegistrySection assetType="recovery_tank" />} />
          </Route>
          <Route path="/manage/gas-detectors" element={<GasDetectorsView />} />
          <Route path="/manage/hoses" element={<HosesManagementView />} />
          <Route path="/alerts" element={<AlertsView />} />
          <Route path="*" element={<HierarchyFixture view={view} />} />
        </Routes>
      ) : (
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
      )}
    </AppShell>
      )}
    </BreadcrumbProvider>
  )
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <MemoryRouter initialEntries={[previewEntry()]}>
      <Preview />
    </MemoryRouter>
  </StrictMode>,
)
