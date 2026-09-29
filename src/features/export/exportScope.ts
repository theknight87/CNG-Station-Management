import type { SupabaseClient } from '@supabase/supabase-js'

import type { EquipmentTab } from '@/features/units/useUnitWorkspace'

import {
  COMPRESSOR_COLUMNS, DISPENSER_COLUMNS, GAS_DETECTOR_COLUMNS, HOSE_COLUMNS, INSTALLED_SRV_COLUMNS, STATION_COLUMNS,
  UNIT_COLUMNS, VESSEL_COLUMNS,
} from './exportColumns'
import { fetchAllRows, type AnyRow, type ExportColumn, type ExportSheet } from './exportData'

/**
 * Everything recorded under one Region, Station or Unit, as one workbook with a sheet per equipment family.
 *
 * Each family reads the SAME view its registry page reads, narrowed by `region_id` / `station_id` / `unit_id`, under
 * the caller's RLS. Archived records are not exported (the views already exclude them; the two raw tables are
 * filtered here). Gas detectors export devices only: recorded ABSENCE of a detector is evidence, not a device.
 */

export type ScopeKind = 'region' | 'station' | 'unit'
export interface ExportScope { kind: ScopeKind; id: string; name: string }

export type FamilyKey = 'compressors' | 'recovery_tanks' | 'gas_detectors' | 'dispensers' | 'storage_vessels' | 'hoses' | 'installed_srvs'

interface Family {
  key: FamilyKey
  sheet: string
  source: string
  columns: ExportColumn[]
  narrow?: (b: Builder) => Builder
  /** Raw tables carry ids, not names: Region / Station / Unit names are filled in from the hierarchy views. */
  rawTable?: boolean
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Builder = any

/** Physical order (CLAUDE.md §4): Compressor, Recovery Tank, Gas Detectors, Dispensers, Storage Vessels, then Hoses and SRVs. */
export const FAMILIES: Family[] = [
  { key: 'compressors', sheet: 'Compressors', source: 'compressors', columns: COMPRESSOR_COLUMNS, rawTable: true,
    narrow: (b) => b.is('archived_at', null) },
  { key: 'recovery_tanks', sheet: 'Recovery tanks', source: 'v_vessel_management', columns: VESSEL_COLUMNS,
    narrow: (b) => b.eq('asset_type', 'recovery_tank') },
  { key: 'gas_detectors', sheet: 'Gas detectors', source: 'v_gas_detector_management', columns: GAS_DETECTOR_COLUMNS,
    narrow: (b) => b.not('detector_id', 'is', null) },
  { key: 'dispensers', sheet: 'Dispensers', source: 'dispensers', columns: DISPENSER_COLUMNS, rawTable: true,
    narrow: (b) => b.is('archived_at', null) },
  { key: 'storage_vessels', sheet: 'Storage vessels', source: 'v_vessel_management', columns: VESSEL_COLUMNS,
    narrow: (b) => b.eq('asset_type', 'storage_vessel') },
  { key: 'hoses', sheet: 'Hoses', source: 'v_hose_registry', columns: HOSE_COLUMNS },
  { key: 'installed_srvs', sheet: 'Installed SRVs', source: 'v_installed_srv_management', columns: INSTALLED_SRV_COLUMNS },
]

const SCOPE_COLUMN: Record<ScopeKind, string> = { region: 'region_id', station: 'station_id', unit: 'unit_id' }

const collator = new Intl.Collator(['ar', 'en'], { numeric: true, sensitivity: 'base' })
const byHierarchy = (a: AnyRow, b: AnyRow) =>
  collator.compare(a.region_name ?? '', b.region_name ?? '') || collator.compare(a.station_name ?? '', b.station_name ?? '')
  || collator.compare(a.unit_name ?? '', b.unit_name ?? '') || collator.compare(a.serial_number ?? '', b.serial_number ?? '')

async function loadNames(supabase: SupabaseClient, scope: ExportScope) {
  const column = SCOPE_COLUMN[scope.kind]
  const [stations, units] = await Promise.all([
    scope.kind === 'unit'
      ? Promise.resolve({ rows: [] as AnyRow[], truncated: false })
      : fetchAllRows((from, to) => supabase.from('v_station_summary').select('*').eq(column, scope.id).order('station_name').order('station_id').range(from, to)),
    fetchAllRows((from, to) => supabase.from('v_unit_summary').select('*').eq(column, scope.id).order('station_name').order('unit_name').order('unit_id').range(from, to)),
  ])
  return { stations: stations.rows, units: units.rows }
}

/** One family's rows for the scope, with names attached, in hierarchy order. */
export async function loadFamily(supabase: SupabaseClient, family: Family, scope: ExportScope, names?: { stations: AnyRow[]; units: AnyRow[] }): Promise<ExportSheet> {
  const column = SCOPE_COLUMN[scope.kind]
  const { rows, truncated } = await fetchAllRows((from, to) => {
    let b: Builder = supabase.from(family.source).select('*').eq(column, scope.id)
    if (family.narrow) b = family.narrow(b)
    return b.order('id').range(from, to)
  })
  let named = rows
  if (family.rawTable) {
    const lookup = names ?? await loadNames(supabase, scope)
    const unitById = new Map(lookup.units.map((u) => [u.unit_id, u]))
    const stationById = new Map([
      ...lookup.stations.map((s) => [s.station_id, s] as const),
      ...lookup.units.map((u) => [u.station_id, u] as const),
    ])
    named = rows.map((r) => {
      const u = r.unit_id ? unitById.get(r.unit_id) : undefined
      const s = stationById.get(r.station_id)
      return { ...r, unit_name: u?.unit_name ?? null, station_name: s?.station_name ?? null, region_name: s?.region_name ?? null }
    })
  }
  return { name: family.sheet, columns: family.columns, rows: [...named].sort(byHierarchy), truncated }
}

/** The whole workbook for a Region, Station or Unit: an overview sheet, then one sheet per equipment family. */
export async function loadScopeWorkbook(supabase: SupabaseClient, scope: ExportScope): Promise<ExportSheet[]> {
  const names = await loadNames(supabase, scope)
  const families = await Promise.all(FAMILIES.map((f) => loadFamily(supabase, f, scope, names)))
  const overview: ExportSheet[] = []
  if (scope.kind === 'region') overview.push({ name: 'Stations', columns: STATION_COLUMNS, rows: names.stations })
  if (scope.kind !== 'unit') overview.push({ name: 'Units', columns: UNIT_COLUMNS, rows: names.units })
  else overview.push({ name: 'Unit', columns: UNIT_COLUMNS, rows: names.units })
  return [...overview, ...families]
}

export function familyByKey(key: FamilyKey): Family {
  return FAMILIES.find((f) => f.key === key)!
}

/** The Unit tab (route segment / popup tab) each equipment family is shown under. */
export const TAB_FAMILY: Record<EquipmentTab, FamilyKey> = {
  compressor: 'compressors',
  'recovery-tank': 'recovery_tanks',
  'gas-detectors': 'gas_detectors',
  dispensers: 'dispensers',
  storage: 'storage_vessels',
  hoses: 'hoses',
  srvs: 'installed_srvs',
}
