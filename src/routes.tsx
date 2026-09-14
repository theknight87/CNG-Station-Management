import { createBrowserRouter, Navigate } from 'react-router-dom'

import { AppLayout } from '@/components/layout/AppLayout'
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
  {
    path: '/',
    element: <AppLayout />,
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
