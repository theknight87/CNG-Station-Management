import { useEffect, useState, type ReactNode } from 'react'
import { Replace } from 'lucide-react'
import { ReplaceValvePanel } from '@/features/relief-valves/ReplaceValvePanel'
import { RowAction, RowActions } from '@/features/relief-valves/SrvAdminActions'
import { useIsAdmin } from '@/features/relief-valves/useSrvWorkflow'
import { ScopeExport, UnitTabExport } from '@/features/export/ScopeExport'

import { MakerChip } from '@/components/data/AssetChips'
import { DetailGrid, DetailItem, RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { NullValue } from '@/components/data/NullValue'
import { Identifier } from '@/components/data/TechnicalText'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import type { UnitSummary } from '@/features/hierarchy/useHierarchy'
import { RecordAdminTools } from '@/features/record-tools/RecordAdminTools'
import { columnLabel, type RecordRef } from '@/features/record-tools/recordTools'
import { DueBadge, PrecisionDate, Pressure, PressureRange, Serial, Text } from '@/features/units/assetDisplay'
import {
  useUnitEquipment,
  type CompressorRow, type DetectorRow, type DispenserRow, type EquipmentTab, type HoseRow, type UnitSrvRow, type VesselRow,
} from '@/features/units/useUnitWorkspace'
import { cn } from '@/lib/utils'
import { SectionTabContent } from '@/components/layout/SectionTabs'
import { sectionTabClass, sectionTabTrack } from '@/components/layout/sectionTabStyles'
import { useSupabaseClient } from '@/lib/supabase/client'
import { AddUnitAssetButton, type AssetKind } from '@/features/units/AddUnitAsset'

/**
 * One Unit in a popup (owner request 2026-09-28): a tab per equipment family, each a compact list; a row opens a
 * second popup with that record's full detail. It reads exactly what the Unit workspace reads (useUnitEquipment,
 * the same views and the same `unit_id` proof), so it can show nothing the workspace would not.
 */

interface Col<T> { header: string; right?: boolean; render: (r: T) => ReactNode }

const daysLeft = (d: number | null) => (d === null ? <NullValue /> : <span className="tabular">{d.toLocaleString()}</span>)

interface TabSpec<T> {
  kind: AssetKind
  dueType: string | null
  tab: EquipmentTab
  label: string
  count: (u: UnitSummary) => number
  key: (r: T) => string
  title: (r: T) => string
  record: (r: T) => RecordRef | null
  columns: Col<T>[]
}

const SRV: TabSpec<UnitSrvRow> = {
  kind: 'srv', dueType: 'installed_relief_valve', tab: 'srvs', label: 'SRVs', count: (u) => u.installed_srvs, key: (r) => r.id,
  title: (r) => `SRV ${r.serial_number ?? ''}`.trim(), record: (r) => ({ table: 'installed_relief_valves', id: r.id }),
  columns: [
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Set pressure', right: true, render: (r) => <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} /> },
    { header: 'Manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { header: 'Last calibration', render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} /> },
    { header: 'Days left', right: true, render: (r) => daysLeft(r.days_left) },
    { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  ],
}

const vessel = (tab: 'storage' | 'recovery-tank', label: string, count: (u: UnitSummary) => number): TabSpec<VesselRow> => ({
  kind: tab === 'storage' ? 'storage_vessel' : 'recovery_tank', dueType: tab === 'storage' ? 'storage_vessel' : 'recovery_tank',
  tab, label, count, key: (r) => r.id, title: (r) => `${label.replace(/s$/, '')} ${r.serial_number ?? ''}`.trim(),
  record: (r) => ({ table: r.asset_type === 'storage_vessel' ? 'storage_vessels' : 'recovery_tanks', id: r.id }),
  columns: [
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { header: 'Last inspection', render: (r) => <PrecisionDate display={r.last_inspection_display} precision={r.last_inspection_precision} /> },
    { header: 'Days left', right: true, render: (r) => daysLeft(r.days_left) },
    { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  ],
})

const DETECTOR: TabSpec<DetectorRow> = {
  kind: 'gas_detector', dueType: 'gas_detector', tab: 'gas-detectors', label: 'Gas detectors', count: (u) => u.gas_detectors,
  key: (r) => r.detector_id ?? `${r.station_id}-${r.area_type_raw}`, title: (r) => `Gas detector ${r.serial_number ?? ''}`.trim(),
  record: (r) => (r.detector_id ? { table: 'gas_detectors', id: r.detector_id } : null),
  columns: [
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Area', render: (r) => <Text value={r.area_type ?? r.area_type_raw} /> },
    { header: 'Last calibration', render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} /> },
    { header: 'Days left', right: true, render: (r) => daysLeft(r.days_left) },
    { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  ],
}

const DISPENSER: TabSpec<DispenserRow> = {
  kind: 'dispenser', dueType: null, tab: 'dispensers', label: 'Dispensers', count: (u) => u.dispensers, key: (r) => r.id,
  title: (r) => `Dispenser ${r.dispenser_name ?? r.serial_number ?? ''}`.trim(), record: (r) => ({ table: 'dispensers', id: r.id }),
  columns: [
    { header: 'Dispenser', render: (r) => <Text value={r.dispenser_name} /> },
    { header: 'Manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { header: 'Model', render: (r) => <Text value={r.model} /> },
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Hoses', right: true, render: (r) => (r.number_of_hoses === null ? <NullValue /> : <span className="tabular">{r.number_of_hoses}</span>) },
  ],
}

const HOSE: TabSpec<HoseRow> = {
  kind: 'hose', dueType: 'hose', tab: 'hoses', label: 'Hoses', count: (u) => u.hoses, key: (r) => r.id,
  title: (r) => `Hose ${r.serial_number ?? ''}`.trim(), record: (r) => ({ table: 'hoses', id: r.id }),
  columns: [
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Description', render: (r) => <Text value={r.description} /> },
    { header: 'Working pressure', right: true, render: (r) => <Pressure value={r.working_pressure_value} unit={r.working_pressure_unit} raw={r.working_pressure_raw} /> },
    { header: 'Last test', render: (r) => <PrecisionDate display={r.last_test_display} precision={r.last_test_precision} /> },
    { header: 'Days left', right: true, render: (r) => daysLeft(r.days_left) },
    { header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  ],
}

const COMPRESSOR: TabSpec<CompressorRow> = {
  kind: 'compressor', dueType: null, tab: 'compressor', label: 'Compressor', count: (u) => u.compressors, key: (r) => r.id,
  title: (r) => `Compressor ${r.model ?? r.serial_number ?? ''}`.trim(), record: (r) => ({ table: 'compressors', id: r.id }),
  columns: [
    { header: 'Manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { header: 'Model', render: (r) => <Text value={r.model} /> },
    { header: 'Serial', render: (r) => <Serial value={r.serial_number} status={r.serial_status} /> },
    { header: 'Job number', render: (r) => (r.job_number ? <Identifier value={r.job_number} /> : <NullValue />) },
    { header: 'Running hours', right: true, render: (r) => (r.total_running_hours === null ? <NullValue /> : <span className="tabular">{r.total_running_hours.toLocaleString()}</span>) },
  ],
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const TABS: TabSpec<any>[] = [
  SRV, vessel('storage', 'Storage vessels', (u) => u.storage_vessels), vessel('recovery-tank', 'Recovery tanks', (u) => u.recovery_tanks),
  DETECTOR, DISPENSER, HOSE, COMPRESSOR,
]

/** Identity and bookkeeping columns the detail popup does not list (they are ids, not facts about the equipment). */
const HIDDEN = /(^id$|_id$|^normalized_name$|^needs_mapping$|^asset_type$)/

function Detail({ row }: { row: Record<string, unknown> }) {
  const entries = Object.entries(row).filter(([k]) => !HIDDEN.test(k))
  return (
    <DetailGrid>
      {entries.map(([k, v]) => (
        <DetailItem key={k} label={columnLabel(k)}>
          {v === null || v === undefined || v === '' ? <NullValue />
            : typeof v === 'boolean' ? (v ? 'Yes' : 'No')
            : <span dir="auto">{String(v)}</span>}
        </DetailItem>
      ))}
    </DetailGrid>
  )
}

function TabList<T>({ spec, unitId, onOpen, action }: {
  spec: TabSpec<T>; unitId: string; onOpen: (r: T) => void
  /** A control at the end of each row (the SRV tab's Replace); clicking it never opens the row. */
  action?: { header: string; render: (r: T) => ReactNode }
}) {
  const { state, reload } = useUnitEquipment<T>(spec.tab, unitId)
  if (state.status === 'loading') return <LoadingState label={`Loading ${spec.label}`} />
  if (state.status === 'unconfigured') return <EmptyState title="Not configured" description="The database is not configured." />
  if (state.status === 'error') return <ErrorState message={state.message} onRetry={reload} />
  if (state.data.length === 0) {
    return <EmptyState title={`No ${spec.label.toLowerCase()} recorded for this Unit`} description="Nothing is recorded here; that is not an error." />
  }
  return (
    <div className="overflow-x-auto rounded border">
      <table className="table-fit w-full text-sm" aria-label={spec.label}>
        <thead className="bg-muted/50 text-xs uppercase tracking-wide text-muted-foreground">
          <tr>
            {spec.columns.map((c) => (
              <th key={c.header} className={cn('whitespace-nowrap px-2 py-1.5 text-left font-semibold', c.right && 'text-right')}>{c.header}</th>
            ))}
            {action ? <th className="whitespace-nowrap px-2 py-1.5 font-semibold">{action.header}</th> : null}
          </tr>
        </thead>
        <tbody>
          {state.data.map((r) => (
            <tr key={spec.key(r)} tabIndex={0} className="cursor-pointer border-t hover:bg-muted/40 focus-visible:bg-muted/40"
                onClick={() => onOpen(r)} onKeyDown={(e) => { if (e.key === 'Enter') onOpen(r) }}>
              {spec.columns.map((c) => (
                <td key={c.header} className={cn('whitespace-nowrap px-2 py-1 align-middle', c.right && 'text-right tabular')}>{c.render(r)}</td>
              ))}
              {action ? <td className="whitespace-nowrap px-2 py-1 align-middle">{action.render(r)}</td> : null}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/** Overdue and due-within-30-days per equipment family, from the same view the reports read (suggestion 4). */
function useUnitDue(unitId: string | undefined, stationId: string | undefined, nonce: number) {
  const supabase = useSupabaseClient()
  const [counts, setCounts] = useState<Record<string, { overdue: number; due: number }> | null>(null)
  useEffect(() => {
    let cancelled = false
    void (async () => {
      if (!supabase || !unitId) return
      // Ruling 6y: the Station's storage (no Unit, resolved) is counted under each of its Units.
      const base = supabase.from('v_report_due_compliance').select('asset_type, due_status')
      const { data, error } = await (stationId
        ? base.or(`unit_id.eq.${unitId},and(unit_id.is.null,station_id.eq.${stationId},mapping_status.eq.resolved)`)
        : base.eq('unit_id', unitId))
      if (cancelled || error || !data) return
      const out: Record<string, { overdue: number; due: number }> = {}
      for (const r of data as { asset_type: string; due_status: string }[]) {
        const c = (out[r.asset_type] ??= { overdue: 0, due: 0 })
        if (r.due_status === 'overdue') c.overdue += 1
        else if (DUE_SOON.includes(r.due_status)) c.due += 1
      }
      setCounts(out)
    })()
    return () => { cancelled = true }
  }, [supabase, unitId, stationId, nonce])
  return counts
}
const DUE_SOON = ['due_today', 'due_7', 'due_15', 'due_30']

function DueStrip({ counts }: { counts: Record<string, { overdue: number; due: number }> | null }) {
  if (!counts) return null
  return (
    <ul aria-label="Due summary" className="flex flex-wrap gap-2">
      {TABS.filter((t) => t.dueType).map((t) => {
        const c = counts[t.dueType as string] ?? { overdue: 0, due: 0 }
        const tone = c.overdue ? 'border-[var(--status-overdue,#dc2626)] bg-red-50 text-red-900 dark:bg-red-950 dark:text-red-100'
          : c.due ? 'border-amber-500 bg-amber-50 text-amber-900 dark:bg-amber-950 dark:text-amber-100'
          : 'border-emerald-500 bg-emerald-50 text-emerald-900 dark:bg-emerald-950 dark:text-emerald-100'
        return (
          <li key={t.tab} className={cn('rounded border-l-4 border px-2 py-1 text-xs', tone)}>
            <span className="font-semibold">{t.label}</span>{' '}
            {c.overdue || c.due
              ? <span className="tabular">{c.overdue} overdue · {c.due} due ≤30d</span>
              : <span>nothing due</span>}
          </li>
        )
      })}
    </ul>
  )
}

export function UnitPopup({ unit, onClose }: { unit: UnitSummary | null; onClose: () => void }) {
  const [tab, setTab] = useState<EquipmentTab>('srvs')
  const [item, setItem] = useState<{ spec: TabSpec<unknown>; row: unknown } | null>(null)
  const [nonce, setNonce] = useState(0)
  const [replacing, setReplacing] = useState<UnitSrvRow | null>(null)
  const isAdmin = useIsAdmin()
  const counts = useUnitDue(unit?.unit_id, unit?.station_id, nonce)
  const spec = TABS.find((t) => t.tab === tab) ?? TABS[0]
  const record = item ? item.spec.record(item.row) : null
  return (
    <>
      <RecordDetailsDialog open={unit !== null} size="wide" title={unit?.unit_name ?? ''}
                           description={unit ? `${unit.station_name} · ${unit.region_name} Region${unit.job_number ? ` · Job ${unit.job_number}` : ''}` : undefined}
                           onClose={() => { setItem(null); setTab('srvs'); onClose() }}>
        {unit ? (
          <div className="flex min-w-0 flex-col gap-3">
            <DueStrip counts={counts} />
            <div role="tablist" aria-label="Equipment" className={sectionTabTrack}>
              {TABS.map((t) => (
                <button key={t.tab} type="button" role="tab" aria-selected={t.tab === tab}
                        className={sectionTabClass(t.tab === tab, true)}
                        onClick={() => setTab(t.tab)}>
                  <SectionTabContent tab={{ label: t.label, count: t.count(unit) }} active={t.tab === tab} compact />
                </button>
              ))}
            </div>
            <div role="tabpanel" aria-label={spec.label} className="flex flex-col gap-2">
              <div className="flex flex-wrap items-center justify-end gap-2">
                <UnitTabExport tab={spec.tab} unitId={unit.unit_id} unitName={unit.unit_name} />
                <ScopeExport scope={{ kind: 'unit', id: unit.unit_id, name: unit.unit_name }} />
                <AddUnitAssetButton kind={spec.kind} unitId={unit.unit_id} unitName={unit.unit_name} onAdded={() => setNonce((n) => n + 1)} />
              </div>
              <TabList key={`${spec.tab}-${nonce}`} spec={spec} unitId={unit.unit_id} onOpen={(row) => setItem({ spec, row })}
                       action={spec.kind === 'srv' && isAdmin ? {
                         // Replace straight from the list (owner request 2026-10-03), without opening the valve first.
                         header: 'Replace',
                         render: (r: UnitSrvRow) => (
                           <RowActions>
                             <RowAction label={`Replace ${r.serial_number ? `valve ${r.serial_number}` : 'this valve'}`} icon={Replace}
                                        onClick={() => setReplacing(r)} />
                           </RowActions>
                         ),
                       } : undefined} />
            </div>
          </div>
        ) : null}
      </RecordDetailsDialog>
      <RecordDetailsDialog open={replacing !== null} size="wide"
                           title={replacing ? `Replace SRV ${replacing.serial_number ?? ''}`.trim() : ''}
                           description={unit ? `${unit.unit_name} · ${unit.station_name}` : undefined} onClose={() => setReplacing(null)}>
        {replacing ? (
          <ReplaceValvePanel valve={replacing} startOpen onCancel={() => setReplacing(null)}
                             onDone={() => { setReplacing(null); setNonce((n) => n + 1) }} />
        ) : null}
      </RecordDetailsDialog>
      <RecordDetailsDialog open={item !== null} title={item ? item.spec.title(item.row) : ''}
                           description={unit ? `${unit.unit_name} · ${unit.station_name}` : undefined} onClose={() => setItem(null)}>
        {item ? (
          <div className="flex flex-col gap-3">
            <Detail row={item.row as Record<string, unknown>} />
            {item.spec.kind === 'srv' ? (
              <ReplaceValvePanel valve={item.row as UnitSrvRow} onDone={() => { setItem(null); setNonce((n) => n + 1) }} />
            ) : null}
            {record ? <RecordAdminTools record={record} /> : null}
          </div>
        ) : null}
      </RecordDetailsDialog>
    </>
  )
}
