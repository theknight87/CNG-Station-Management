/**
 * Where each equipment family of a Region / Station / Unit workbook is read from, and the columns that read needs
 * besides the scope column. Plain data with no imports, so scripts/verify-report-contract.mjs can check every name
 * here against the real database (2026-09-29: the Region export ordered v_gas_detector_management by an `id` column
 * that view does not have — its key is detector_id — and failed in production).
 */
export const SCOPE_SOURCES = [
  { key: 'compressors', source: 'compressors', orderBy: 'id', filters: ['archived_at'] },
  { key: 'recovery_tanks', source: 'v_vessel_management', orderBy: 'id', filters: ['asset_type'] },
  { key: 'gas_detectors', source: 'v_gas_detector_management', orderBy: 'detector_id', filters: ['detector_id'] },
  { key: 'dispensers', source: 'dispensers', orderBy: 'id', filters: ['archived_at'] },
  { key: 'storage_vessels', source: 'v_vessel_management', orderBy: 'id', filters: ['asset_type'] },
  { key: 'hoses', source: 'v_hose_registry', orderBy: 'id', filters: [] },
  { key: 'installed_srvs', source: 'v_installed_srv_management', orderBy: 'id', filters: [] },
] as const

/** Every family is narrowed by one of these (Region, Station or Unit workbook). */
export const SCOPE_FILTER_COLUMNS = ['region_id', 'station_id', 'unit_id'] as const

/** The overview sheets read these, ordered by the listed columns. */
export const SCOPE_OVERVIEWS = [
  { source: 'v_station_summary', columns: ['region_id', 'station_id', 'station_name'] },
  { source: 'v_unit_summary', columns: ['region_id', 'station_id', 'unit_id', 'station_name', 'unit_name'] },
] as const
