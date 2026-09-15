import { createBrowserRouter, Navigate } from 'react-router-dom'

import { AppLayout } from '@/components/layout/AppLayout'
import { AuthGate, AuthTestPage, SignInPage, SignUpPage } from '@/features/auth'
import { CompressorSection } from '@/features/units/sections/CompressorSection'
import { DetectorSection } from '@/features/units/sections/DetectorSection'
import { DispenserSection } from '@/features/units/sections/DispenserSection'
import { HoseSection } from '@/features/units/sections/HoseSection'
import { OverviewSection } from '@/features/units/sections/OverviewSection'
import { SrvSection } from '@/features/units/sections/SrvSection'
import { VesselSection } from '@/features/units/sections/VesselSection'
import { InstalledSrvSection } from '@/features/relief-valves/sections/InstalledSrvSection'
import { WarehouseSrvSection } from '@/features/relief-valves/sections/WarehouseSrvSection'
import { VesselRegistrySection } from '@/features/vessels/sections/VesselRegistrySection'
import { AdminPage } from '@/pages/AdminPage'
import { AlertsPage } from '@/pages/AlertsPage'
import { DashboardPage } from '@/pages/DashboardPage'
import { GasDetectorsPage } from '@/pages/GasDetectorsPage'
import { HosesManagementPage } from '@/pages/HosesManagementPage'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { RegionDetailPage } from '@/pages/RegionDetailPage'
import { RegionsPage } from '@/pages/RegionsPage'
import { ReportsPage } from '@/pages/ReportsPage'
import { SettingsPage } from '@/pages/SettingsPage'
import { SrvManagementPage } from '@/pages/SrvManagementPage'
import { StationsPage } from '@/pages/StationsPage'
import { StationPage } from '@/pages/StationPage'
import { UnitPage } from '@/pages/UnitPage'
import { VesselsManagementPage } from '@/pages/VesselsManagementPage'

/**
 * Routes mirror the authoritative structure:
 *
 *  - the physical hierarchy, Region -> Station -> Unit -> Equipment (-> SRV)
 *  - the global management modules, which are aggregate views over the same
 *    records and introduce no ownership of their own
 *
 * The Unit SRVs tab and /manage/srvs read the same source records; they differ
 * only by filter.
 */
export const router = createBrowserRouter([
  // ===================================================================
  // TEMPORARY — Prompt 5 authentication test routes. REMOVE BEFORE PRODUCTION.
  // Kept deliberately for acceptance testing; removal checklist in
  // docs/authentication.md §11.
  // ===================================================================
  // They sit OUTSIDE AuthGate:
  // sign-in must be reachable while signed out, and the test page must be
  // reachable while the account is still inactive — which is exactly the state
  // a first sign-in produces. Neither grants anything; the database decides.
  { path: '/sign-in/*', element: <SignInPage /> },
  { path: '/sign-up/*', element: <SignUpPage /> },
  { path: '/auth-test', element: <AuthTestPage /> },

  {
    path: '/',
    element: (
      <AuthGate>
        <AppLayout />
      </AuthGate>
    ),
    children: [
      // `/` is not a page of its own: the shell's home IS the dashboard, and a
      // named route keeps breadcrumbs and active navigation honest.
      { index: true, element: <Navigate to="/dashboard" replace /> },
      { path: 'dashboard', element: <DashboardPage /> },

      // Physical hierarchy
      { path: 'regions', element: <RegionsPage /> },
      { path: 'regions/:regionId', element: <RegionDetailPage /> },
      { path: 'stations', element: <StationsPage /> },
      { path: 'stations/:stationId', element: <StationPage /> },
      // The Unit workspace. Sections are NESTED ROUTES, not local tab state, so
      // every one is deep-linkable and the Back button works. The pre-existing
      // child paths are preserved exactly, so links minted before Prompt 10
      // still resolve - `/units/:unitId/srvs` now opens the workspace with the
      // SRVs section selected rather than the global SRV module.
      {
        path: 'units/:unitId',
        element: <UnitPage />,
        children: [
          { index: true, element: <OverviewSection /> },
          { path: 'compressor', element: <CompressorSection /> },
          { path: 'recovery-tank', element: <VesselSection kind="recovery_tank" /> },
          { path: 'dispensers', element: <DispenserSection /> },
          { path: 'storage', element: <VesselSection kind="storage_vessel" /> },
          { path: 'gas-detectors', element: <DetectorSection /> },
          { path: 'hoses', element: <HoseSection /> },
          { path: 'srvs', element: <SrvSection /> },
        ],
      },

      // Global management modules (aggregate views)
      // Global SRV Management. `/manage/srvs` stays the canonical entry point
      // and lands on Installed; both datasets are deep-linkable sub-routes.
      // `/units/:unitId/srvs` is untouched and keeps its narrower Unit rule.
      {
        path: 'manage/srvs',
        element: <SrvManagementPage />,
        children: [
          { index: true, element: <Navigate to="/manage/srvs/installed" replace /> },
          { path: 'installed', element: <InstalledSrvSection /> },
          { path: 'warehouse', element: <WarehouseSrvSection /> },
        ],
      },
      // Vessels Management. `/manage/vessels` stays the canonical entry and
      // lands on Storage Vessels; both asset types are deep-linkable routes.
      // The Prompt-10 Unit tabs are untouched and keep their Unit scoping.
      {
        path: 'manage/vessels',
        element: <VesselsManagementPage />,
        children: [
          { index: true, element: <Navigate to="/manage/vessels/storage" replace /> },
          { path: 'storage', element: <VesselRegistrySection assetType="storage_vessel" /> },
          { path: 'recovery', element: <VesselRegistrySection assetType="recovery_tank" /> },
        ],
      },
      { path: 'manage/gas-detectors', element: <GasDetectorsPage /> },
      { path: 'manage/hoses', element: <HosesManagementPage /> },

      { path: 'alerts', element: <AlertsPage /> },
      { path: 'reports', element: <ReportsPage /> },
      { path: 'settings', element: <SettingsPage /> },

      // Admin. The landing route is a page, not a redirect: an engineer or
      // viewer who reaches it must see the permission state, and a redirect
      // would bounce them somewhere that says nothing.
      { path: 'admin', element: <AdminPage /> },
      { path: 'admin/users', element: <AdminPage /> },
      { path: 'admin/data-quality', element: <AdminPage /> },
      { path: 'admin/import', element: <AdminPage /> },

      { path: '*', element: <NotFoundPage /> },
    ],
  },
])
