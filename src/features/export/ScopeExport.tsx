import { useSupabaseClient } from '@/lib/supabase/client'
import type { EquipmentTab } from '@/features/units/useUnitWorkspace'
import { ExportButtons } from './ExportButtons'
import { TAB_FAMILY, familyByKey, loadFamily, loadScopeWorkbook, type ExportScope } from './exportScope'

const SCOPE_LABEL = { region: 'Export Region', station: 'Export Station', unit: 'Export Unit' } as const

/** Everything under a Region, Station or Unit as one Excel workbook (a sheet per equipment family). */
export function ScopeExport({ scope, className }: { scope: ExportScope; className?: string }) {
  const supabase = useSupabaseClient()
  return (
    <ExportButtons
      className={className}
      label={SCOPE_LABEL[scope.kind]}
      name={`${scope.kind}-${scope.name}`}
      csv={false}
      load={async () => {
        if (!supabase) throw new Error('the database is not configured')
        return loadScopeWorkbook(supabase, scope)
      }}
    />
  )
}


/** One equipment family of one Unit (the open tab), to Excel or CSV. */
export function UnitTabExport({ tab, unitId, unitName, className }: { tab: EquipmentTab; unitId: string; unitName: string; className?: string }) {
  const supabase = useSupabaseClient()
  const family = familyByKey(TAB_FAMILY[tab])
  return (
    <ExportButtons
      className={className}
      label={`Export ${family.sheet.toLowerCase()}`}
      name={`${unitName}-${family.key.replace(/_/g, '-')}`}
      load={async () => {
        if (!supabase) throw new Error('the database is not configured')
        return [await loadFamily(supabase, family, { kind: 'unit', id: unitId, name: unitName })]
      }}
    />
  )
}
