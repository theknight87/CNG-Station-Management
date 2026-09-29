import { Container, RotateCcw } from 'lucide-react'
import { Outlet } from 'react-router-dom'

import { PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { SectionTabs, type SectionTab } from '@/components/layout/SectionTabs'

/**
 * Vessels Management.
 *
 * Storage Vessels and Recovery Tanks share a workspace and an inspection
 * vocabulary, but they are separate asset types with separate tables. The
 * sub-navigation says which one you are looking at in words, and each registry
 * shows only the fields its own schema carries — a Recovery Tank is never given
 * a Storage Vessel's relationships to make the two look alike.
 *
 * Sections are routes, so both are deep-linkable and Back works.
 * `/manage/vessels` remains the canonical entry and lands on Storage Vessels.
 */

const SECTIONS: SectionTab[] = [
  { to: '/manage/vessels/storage', icon: Container, label: 'Storage Vessels', hint: 'Pressure storage, may carry relief valves' },
  { to: '/manage/vessels/recovery', icon: RotateCcw, label: 'Recovery Tanks', hint: 'Recovery vessels, no relief-valve relationship' },
]

export function VesselWorkspace() {
  return (
    <PageContainer>
      <PageHeader
        title="Vessels Management"
        description="Storage Vessels and Recovery Tanks across every Region you are authorized for, with their inspection status."
      />

      <SectionTabs label="Vessel types" tabs={SECTIONS} />

      <Outlet />
    </PageContainer>
  )
}
