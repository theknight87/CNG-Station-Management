import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { ErrorState, LoadingState, PermissionDenied } from '@/components/states/AppStates'
import { useAppUser } from '@/hooks/useAppUser'
import {
  DataQualityPanel,
  DueMatrix,
  RegionOverview,
  SummaryStrip,
  WarehousePanel,
} from './DashboardPanels'
import { ATTENTION_STATUSES } from './dueBuckets'
import { dueTotal, mappingTotal, useDashboard, type DashboardData } from './useDashboard'

/**
 * The operational dashboard.
 *
 * It answers, in one screen: what is late, what is coming, where the work is
 * concentrated, and what is still unresolved. Every figure comes from the live
 * database under the caller's RLS scope — there are no sample counts, no
 * seeded rows and no hard-coded totals anywhere in this feature.
 *
 * With the canonical tables still empty before Prompt 21, the honest result is
 * a screen of zeros with an explanation. That is correct, and it is stated
 * plainly rather than dressed up.
 */
export function DashboardView() {
  const appUser = useAppUser()
  const { state, reload } = useDashboard()

  if (appUser.status === 'loading') {
    return (
      <PageContainer>
        <PageHeader title="Dashboard" />
        <LoadingState label="Resolving your access" />
      </PageContainer>
    )
  }

  // An inactive or unprovisioned account must not see a dashboard of zeros and
  // conclude the system is empty. It is not empty — they cannot read it.
  if (appUser.status !== 'active') {
    return (
      <PageContainer>
        <PageHeader title="Dashboard" />
        <PermissionDenied
          what="operational data"
          detail="Your account is not active yet, so no records are readable. An administrator activates accounts and grants Region access."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader
        title="Dashboard"
        description="Inspection, calibration and asset status across the Regions you are authorized for."
      />

      {state.status === 'loading' ? <LoadingState label="Loading operational summary" /> : null}

      {state.status === 'unconfigured' ? (
        <ErrorState
          title="The application is not configured"
          message="Supabase connection details are missing, so no data can be read. This is a deployment problem, not an empty database."
        />
      ) : null}

      {/* A failed query is NEVER rendered as zero. This is the difference
          between "nothing is overdue" and "we do not know". */}
      {state.status === 'error' ? (
        <ErrorState
          title="Could not load the operational summary"
          message={`The database did not return these figures, so none are shown. This is not a report of zero. (${state.message})`}
          onRetry={reload}
        />
      ) : null}

      {state.status === 'ready' ? <DashboardBody data={state.data} /> : null}
    </PageContainer>
  )
}

function DashboardBody({ data }: { data: DashboardData }) {
  const overdue = dueTotal(data.due, ['overdue'])
  const attention = dueTotal(data.due, ATTENTION_STATUSES)
  const unresolved = mappingTotal(data.mapping)

  const totalAssets = data.assets.reduce((sum, a) => sum + a.total, 0)

  return (
    <div className="space-y-4">
      <SummaryStrip
        assets={data.assets}
        attentionTotal={attention}
        overdueTotal={overdue}
        unresolvedTotal={unresolved}
      />

      {/* The empty database is stated, not disguised. Zero is a real answer
          here — the import is Prompt 21 — and saying so is more useful than a
          screen of zeros with no explanation. */}
      {totalAssets === 0 && data.warehouse.total === 0 ? (
        <p className="rounded border border-dashed bg-muted/30 px-3 py-4 text-sm text-muted-foreground">
          <span className="font-medium text-foreground">No operational records exist yet.</span>{' '}
          These figures are real and currently zero: the source workbooks have not been imported.
          The queries succeeded — this is an empty database, not a failure.
        </p>
      ) : null}

      <DueMatrix due={data.due} />
      <RegionOverview regions={data.regions} />

      <div className="grid gap-4 xl:grid-cols-2">
        <DataQualityPanel mapping={data.mapping} />
        <WarehousePanel warehouse={data.warehouse} />
      </div>
    </div>
  )
}
