import { useAppUser } from '@/hooks/useAppUser'
import { AdminDataQualityLink, ReportWorkspace } from '../ReportWorkspace'
import { reportSpec } from '../reportSpecs'

/**
 * The routed report sections.
 *
 * Each is the same workspace with a different spec. The two that need more than
 * that say so explicitly rather than by special-casing the workspace.
 */
export function DueReportSection() {
  return <ReportWorkspace spec={reportSpec('due')} />
}

/**
 * SRV: installed and warehouse, as two clearly labelled reports on one page.
 *
 * They are NEVER one list and NEVER one total. A warehouse valve is stock; an
 * installed valve is a safety device on a specific piece of equipment. Adding
 * their counts together would produce a number that means nothing.
 */
export function SrvReportSection() {
  return (
    <div className="space-y-8">
      <ReportWorkspace spec={reportSpec('srv')} />
      <ReportWorkspace spec={reportSpec('srv-warehouse')} />
    </div>
  )
}

export function VesselsReportSection() {
  return <ReportWorkspace spec={reportSpec('vessels')} />
}

export function GasDetectorsReportSection() {
  return <ReportWorkspace spec={reportSpec('gas-detectors')} />
}

export function HosesReportSection() {
  return <ReportWorkspace spec={reportSpec('hoses')} />
}

export function DataQualityReportSection() {
  const appUser = useAppUser()
  const role = appUser.status === 'active' ? appUser.user.role : null
  const isAdmin = role === 'admin'
  const seesStaging = role === 'admin' || role === 'manager'
  return (
    <div className="space-y-3">
      <AdminDataQualityLink isAdmin={isAdmin} />
      <p className="text-xs text-muted-foreground">
        {seesStaging
          ? 'Three layers: canonical assets, staged pre-import rows, and open import issues. A staged row whose source content changed since it was decided is shown as a STALE SOURCE DECISION — it no longer applies and is never counted as confirmed.'
          : 'This report covers canonical assets within your authorized Regions. Staged pre-import rows and raw import issues carry unconfirmed source text with no proven Region, so they remain visible to managers and administrators only — they are not absent, they are out of scope for this account.'}
      </p>
      <ReportWorkspace spec={reportSpec('data-quality')} />
    </div>
  )
}

export function ActivityReportSection() {
  return (
    <div className="space-y-3">
      <p className="text-xs text-muted-foreground">
        Delivery state is the stored delivery record and nothing else: a blank
        column means no delivery was ever attempted, not that one succeeded.
        Opening a report never marks an alert read and never acknowledges one.
      </p>
      <ReportWorkspace spec={reportSpec('activity')} />
    </div>
  )
}
