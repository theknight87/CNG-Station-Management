import { createBrowserRouter, Navigate } from 'react-router-dom'

import { AppLayout } from '@/components/layout/AppLayout'
import { AuthGate, AuthTestPage, SignInPage, SignUpPage } from '@/features/auth'
import { AdminPage } from '@/pages/AdminPage'
import { AlertsPage } from '@/pages/AlertsPage'
import { CompressorsPage } from '@/pages/CompressorsPage'
import { DashboardPage } from '@/pages/DashboardPage'
import { DispensersPage } from '@/pages/DispensersPage'
import { GasDetectorsPage } from '@/pages/GasDetectorsPage'
import { HosesManagementPage } from '@/pages/HosesManagementPage'
import { NotFoundPage } from '@/pages/NotFoundPage'
import { RecoveryTanksPage } from '@/pages/RecoveryTanksPage'
import { RegionsPage } from '@/pages/RegionsPage'
import { ReportsPage } from '@/pages/ReportsPage'
import { SrvManagementPage } from '@/pages/SrvManagementPage'
import { StationPage } from '@/pages/StationPage'
import { StoragePage } from '@/pages/StoragePage'
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
      { index: true, element: <DashboardPage /> },

      // Physical hierarchy
      { path: 'regions', element: <RegionsPage /> },
      { path: 'stations/:stationId', element: <StationPage /> },
      {
        path: 'units/:unitId',
        children: [
          { index: true, element: <UnitPage /> },
          { path: 'compressor', element: <CompressorsPage /> },
          { path: 'recovery-tank', element: <RecoveryTanksPage /> },
          { path: 'dispensers', element: <DispensersPage /> },
          { path: 'storage', element: <StoragePage /> },
          { path: 'gas-detectors', element: <GasDetectorsPage /> },
          { path: 'srvs', element: <SrvManagementPage /> },
        ],
      },

      // Global management modules (aggregate views)
      { path: 'manage/srvs', element: <SrvManagementPage /> },
      { path: 'manage/vessels', element: <VesselsManagementPage /> },
      { path: 'manage/gas-detectors', element: <GasDetectorsPage /> },
      { path: 'manage/hoses', element: <HosesManagementPage /> },

      { path: 'alerts', element: <AlertsPage /> },
      { path: 'reports', element: <ReportsPage /> },

      // Admin
      { path: 'admin', element: <Navigate to="/admin/users" replace /> },
      { path: 'admin/users', element: <AdminPage /> },
      { path: 'admin/data-quality', element: <AdminPage /> },
      { path: 'admin/import', element: <AdminPage /> },

      { path: '*', element: <NotFoundPage /> },
    ],
  },
])
