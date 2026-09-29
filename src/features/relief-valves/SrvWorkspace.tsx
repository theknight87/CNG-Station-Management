import { ClipboardList, FlaskConical, Gauge, Siren, Warehouse } from 'lucide-react'
import { Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { SectionTabs, type SectionTab } from '@/components/layout/SectionTabs'

/**
 * Global SRV Management.
 *
 * Two datasets, one workspace, and they are never merged. Installed valves sit
 * in the physical hierarchy `Region → Station → Unit → Equipment`; warehouse
 * stock is inventory with no physical position at all. The sub-navigation makes
 * which one you are looking at unmistakable — by label and by the description
 * under the heading, not by colour.
 *
 * Sections are routes (`/manage/srvs/installed`, `/manage/srvs/warehouse`), so
 * both are deep-linkable and Back works. `/manage/srvs` remains the canonical
 * entry point and lands on Installed.
 */

const SECTIONS: SectionTab[] = [
  { to: '/manage/srvs/installed', icon: Gauge, label: 'Installed SRVs', hint: 'Valves fitted to station equipment' },
  { to: '/manage/srvs/warehouse', icon: Warehouse, label: 'Warehouse SRVs', hint: 'In the store: new, calibrated, under calibration' },
  { to: '/manage/srvs/log', icon: ClipboardList, label: 'SRV Log', hint: 'Out at stations, expected back' },
  { to: '/manage/srvs/calibration', icon: FlaskConical, label: 'Calibration (3rd party)', hint: 'At the calibration company' },
  { to: '/manage/srvs/emergency', icon: Siren, label: 'SRV Emergency', hint: 'Emergency issues' },
]

export function SrvWorkspace() {
  return (
    <PageContainer>
      <PageHeader
        title="SRV Management"
        description="Safety Relief Valves across every Region you are authorized for, and warehouse stock."
      />

      <SectionTabs label="SRV datasets" tabs={SECTIONS} />

      <Outlet />
    </PageContainer>
  )
}
