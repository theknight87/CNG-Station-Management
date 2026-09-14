import { PagePlaceholder } from '@/components/PagePlaceholder'

export function SrvManagementView() {
  return (
    <PagePlaceholder
      title="SRV Management"
      description="Every Safety Relief Valve across all Regions and Stations, resolved and unresolved."
      plannedFor="Phase 4 — one installed_srv table behind both this page and the Unit SRVs tab."
    >
          <p className="text-sm text-muted-foreground">
          This page will show resolved and unresolved SRVs together. Unresolved records
          (<code>needs_unit_mapping</code>, <code>needs_equipment_mapping</code>,{' '}
          <code>conflict</code>) stay visible here with a <em>Needs Mapping</em> badge; they are
          excluded from a Unit&apos;s SRV tab until their Unit mapping is confirmed, and are never
          auto-assigned to equipment.
        </p>
    </PagePlaceholder>
  )
}
