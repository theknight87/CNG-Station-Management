/* eslint-disable react-refresh/only-export-components -- route modules intentionally declare lazy route components */
import { lazy } from 'react'
import { createBrowserRouter, Navigate, type RouteObject } from 'react-router-dom'

import { AppLayout } from '@/components/layout/AppLayout'
import { AuthGate } from '@/features/auth/AuthGate'
import { SignInPage } from '@/features/auth/SignInPage'
import { SignUpPage } from '@/features/auth/SignUpPage'

// Keep the authentication shell eager, then split every authenticated workspace
// by route. A signed-out visit no longer downloads admin, reports, registry,
// and data-import UI before it can display the small sign-in screen.
const CompressorSection = lazy(() => import('@/features/units/sections/CompressorSection').then((m) => ({ default: m.CompressorSection })))
const DetectorSection = lazy(() => import('@/features/units/sections/DetectorSection').then((m) => ({ default: m.DetectorSection })))
const DispenserSection = lazy(() => import('@/features/units/sections/DispenserSection').then((m) => ({ default: m.DispenserSection })))
const HoseSection = lazy(() => import('@/features/units/sections/HoseSection').then((m) => ({ default: m.HoseSection })))
const OverviewSection = lazy(() => import('@/features/units/sections/OverviewSection').then((m) => ({ default: m.OverviewSection })))
const SrvSection = lazy(() => import('@/features/units/sections/SrvSection').then((m) => ({ default: m.SrvSection })))
const VesselSection = lazy(() => import('@/features/units/sections/VesselSection').then((m) => ({ default: m.VesselSection })))
const InstalledSrvSection = lazy(() => import('@/features/relief-valves/sections/InstalledSrvSection').then((m) => ({ default: m.InstalledSrvSection })))
const WarehouseSrvSection = lazy(() => import('@/features/relief-valves/sections/WarehouseSrvSection').then((m) => ({ default: m.WarehouseSrvSection })))
const VesselRegistrySection = lazy(() => import('@/features/vessels/sections/VesselRegistrySection').then((m) => ({ default: m.VesselRegistrySection })))
const AdminAlertSettingsSection = lazy(() => import('@/features/admin/sections/AdminAlertSettingsSection').then((m) => ({ default: m.AdminAlertSettingsSection })))
const AdminAuditLogSection = lazy(() => import('@/features/admin/sections/AdminAuditLogSection').then((m) => ({ default: m.AdminAuditLogSection })))
const AdminDataQualitySection = lazy(() => import('@/features/admin/sections/AdminDataQualitySection').then((m) => ({ default: m.AdminDataQualitySection })))
const AdminStationBatchSection = lazy(() => import('@/features/admin/sections/AdminStationBatchSection').then((m) => ({ default: m.AdminStationBatchSection })))
const AdminUsersSection = lazy(() => import('@/features/admin/sections/AdminUsersSection').then((m) => ({ default: m.AdminUsersSection })))
const ActivityReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.ActivityReportSection })))
const DataQualityReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.DataQualityReportSection })))
const DueReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.DueReportSection })))
const GasDetectorsReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.GasDetectorsReportSection })))
const HosesReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.HosesReportSection })))
const SrvReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.SrvReportSection })))
const VesselsReportSection = lazy(() => import('@/features/reports/sections/ReportSections').then((m) => ({ default: m.VesselsReportSection })))
const AdminPage = lazy(() => import('@/pages/AdminPage').then((m) => ({ default: m.AdminPage })))
const AlertsPage = lazy(() => import('@/pages/AlertsPage').then((m) => ({ default: m.AlertsPage })))
const DashboardPage = lazy(() => import('@/pages/DashboardPage').then((m) => ({ default: m.DashboardPage })))
const GasDetectorsPage = lazy(() => import('@/pages/GasDetectorsPage').then((m) => ({ default: m.GasDetectorsPage })))
const HosesManagementPage = lazy(() => import('@/pages/HosesManagementPage').then((m) => ({ default: m.HosesManagementPage })))
const NotFoundPage = lazy(() => import('@/pages/NotFoundPage').then((m) => ({ default: m.NotFoundPage })))
const RegionDetailPage = lazy(() => import('@/pages/RegionDetailPage').then((m) => ({ default: m.RegionDetailPage })))
const RegionsPage = lazy(() => import('@/pages/RegionsPage').then((m) => ({ default: m.RegionsPage })))
const ReportsPage = lazy(() => import('@/pages/ReportsPage').then((m) => ({ default: m.ReportsPage })))
const SettingsPage = lazy(() => import('@/pages/SettingsPage').then((m) => ({ default: m.SettingsPage })))
const SrvManagementPage = lazy(() => import('@/pages/SrvManagementPage').then((m) => ({ default: m.SrvManagementPage })))
const StationsPage = lazy(() => import('@/pages/StationsPage').then((m) => ({ default: m.StationsPage })))
const StationPage = lazy(() => import('@/pages/StationPage').then((m) => ({ default: m.StationPage })))
const UnitPage = lazy(() => import('@/pages/UnitPage').then((m) => ({ default: m.UnitPage })))
const VesselsManagementPage = lazy(() => import('@/pages/VesselsManagementPage').then((m) => ({ default: m.VesselsManagementPage })))

const developmentOnlyRoutes: RouteObject[] = import.meta.env.DEV
  ? [{
      path: '/auth-test',
      lazy: async () => {
        const { AuthTestPage } = await import('@/features/auth/AuthTestPage')
        return { Component: AuthTestPage }
      },
    }]
  : []

/**
 * Routes mirror the authoritative structure:
 *
 *  - the physical hierarchy, Region -> Station -> Unit -> Equipment (-> SRV)
 *  - the global management modules, which are aggregate views over the same
 *    records and introduce no ownership of their own
 *
 * `/auth-test` is compiled into development only. Production retains the real
 * Clerk sign-in and sign-up routes, but does not expose the diagnostic screen.
 */
export const router = createBrowserRouter([
  { path: '/sign-in/*', element: <SignInPage /> },
  { path: '/sign-up/*', element: <SignUpPage /> },
  ...developmentOnlyRoutes,
  {
    path: '/',
    element: (
      <AuthGate>
        <AppLayout />
      </AuthGate>
    ),
    children: [
      { index: true, element: <Navigate to="/dashboard" replace /> },
      { path: 'dashboard', element: <DashboardPage /> },
      { path: 'regions', element: <RegionsPage /> },
      { path: 'regions/:regionId', element: <RegionDetailPage /> },
      { path: 'stations', element: <StationsPage /> },
      { path: 'stations/:stationId', element: <StationPage /> },
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
      {
        path: 'manage/srvs',
        element: <SrvManagementPage />,
        children: [
          { index: true, element: <Navigate to="/manage/srvs/installed" replace /> },
          { path: 'installed', element: <InstalledSrvSection /> },
          { path: 'warehouse', element: <WarehouseSrvSection /> },
        ],
      },
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
      {
        path: 'reports',
        element: <ReportsPage />,
        children: [
          { index: true, element: <Navigate to="/reports/due" replace /> },
          { path: 'due', element: <DueReportSection /> },
          { path: 'srv', element: <SrvReportSection /> },
          { path: 'vessels', element: <VesselsReportSection /> },
          { path: 'gas-detectors', element: <GasDetectorsReportSection /> },
          { path: 'hoses', element: <HosesReportSection /> },
          { path: 'data-quality', element: <DataQualityReportSection /> },
          { path: 'activity', element: <ActivityReportSection /> },
        ],
      },
      { path: 'settings', element: <SettingsPage /> },
      {
        path: 'admin',
        element: <AdminPage />,
        children: [
          { index: true, element: <Navigate to="/admin/users" replace /> },
          { path: 'users', element: <AdminUsersSection /> },
          { path: 'alert-settings', element: <AdminAlertSettingsSection /> },
          { path: 'data-quality', element: <AdminDataQualitySection /> },
          { path: 'station-batch', element: <AdminStationBatchSection /> },
          { path: 'audit-log', element: <AdminAuditLogSection /> },
        ],
      },
      { path: '*', element: <NotFoundPage /> },
    ],
  },
])
