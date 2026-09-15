import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import { MemoryRouter } from 'react-router-dom'
import { LogOut } from 'lucide-react'

import '../src/index.css'
import { AccountControl } from '@/components/layout/AccountControl'
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

function Preview() {
  const [role, setRole] = useState<AppRole>('admin')

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
