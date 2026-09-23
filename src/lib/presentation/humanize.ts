const assetTypes: Record<string, string> = { installed_relief_valve: 'Installed SRV', warehouse_relief_valve: 'Warehouse SRV', storage_vessel: 'Storage Vessel', recovery_tank: 'Recovery Tank', gas_detector: 'Gas Detector', hose: 'Hose', compressor: 'Compressor', dispenser: 'Dispenser' }
const mappingStatuses: Record<string, string> = { resolved: 'Resolved', needs_station_mapping: 'Needs Station Mapping', needs_unit_mapping: 'Needs Unit Mapping', needs_equipment_mapping: 'Needs Equipment Mapping', conflict: 'Conflict' }
const dueStatuses: Record<string, string> = { overdue: 'Overdue', due_today: 'Due Today', due_7: 'Due Within 7 Days', due_15: 'Due Within 15 Days', due_30: 'Due Within 30 Days', due_60: 'Due Within 60 Days', valid: 'Current', unknown: 'Unknown Due Date' }
const auditActions: Record<string, string> = { user_role_changed: 'User Role Changed', user_activation_changed: 'User Activation Changed', region_access_changed: 'Region Access Changed', alert_rule_changed: 'Alert Rule Changed', mapping_changed: 'Mapping Changed' }
const recordTypes: Record<string, string> = { app_users: 'Users', user_region_access: 'Region Access', alert_rules: 'Alert Rules', notification_channel_policy: 'Channel Policy', installed_relief_valves: 'Installed SRVs', import_mapping_decisions: 'Pre-import Decisions' }
export function humanizeTechnicalValue(value: string | null): string | null { if (!value) return null; return value.replace(/[_:-]+/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()).replace(/\bSrv\b/g, 'SRV').replace(/\bId\b/g, 'ID').replace(/\bNgv\b/g, 'NGV').replace(/\bApi\b/g, 'API') }
function mapped(value: string | null, labels: Record<string, string>): string | null { return value ? labels[value] ?? humanizeTechnicalValue(value) : null }
export const humanizeAssetType = (value: string | null) => mapped(value, assetTypes)
export const humanizeMappingStatus = (value: string | null) => mapped(value, mappingStatuses)
export const humanizeDueStatus = (value: string | null) => mapped(value, dueStatuses)
export const humanizeAuditAction = (value: string | null) => mapped(value, auditActions)
export const humanizeRecordType = (value: string | null) => mapped(value, recordTypes)
export const humanizeAlertSubject = humanizeTechnicalValue
export const humanizeParentKind = humanizeTechnicalValue
