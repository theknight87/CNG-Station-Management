import { useState, type ReactNode } from 'react'
import { ClipboardList, FlaskConical, Gauge, Plus, Siren, Warehouse } from 'lucide-react'
import { Outlet } from 'react-router-dom'

import { SearchBox } from '@/components/data/FilterControls'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DUE_ALIASES, DUE_OPTIONS } from '@/components/data/multiFilter'
import { NullValue } from '@/components/data/NullValue'
import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { Identifier } from '@/components/data/TechnicalText'
import { DataToolbar, PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { SectionTabs, type SectionTab } from '@/components/layout/SectionTabs'
import { Button } from '@/components/ui/button'
import { Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { RegionChip } from '@/components/data/AssetChips'
import { CountStrip, FormMessage, ListStates, SelectableTable, type SelectableColumn } from '@/features/relief-valves/SrvWorkflowPieces'
import { AvailabilityChip } from '@/features/relief-valves/SrvPieces'
import { useConfirmedAction, useIsAdmin } from '@/features/relief-valves/useSrvWorkflow'
import { DueBadge } from '@/features/units/assetDisplay'
import { AddStockDialog, CertifyDialog, IssueDialog, ItemHistory } from './EquipmentDialogs'
import { KINDS, STORE_STATES, type EquipmentKind } from './equipmentKinds'
import {
  EQUIPMENT_LIMIT, useEquipmentCounts, useEquipmentList, useNonce,
  type EmergencyRow, type JobRow, type LogRow, type StockRow,
} from './useEquipmentWorkflow'

/**
 * Hoses and Gas Detectors in five tabs, like the relief valves (owner request 2026-10-02): Installed (the existing
 * registry), Warehouse, Log, the 3rd-party step and Emergency. Every change is an admin-only database function; the
 * admin check here only hides the buttons.
 */
export function EquipmentWorkspace({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const tabs: SectionTab[] = [
    { to: `${spec.base}/installed`, icon: Gauge, label: `Installed ${spec.many}`, hint: 'At the stations' },
    { to: `${spec.base}/warehouse`, icon: Warehouse, label: 'Warehouse', hint: `In the store: ${Object.values(spec.stateLabel).join(', ').toLowerCase()}` },
    { to: `${spec.base}/log`, icon: ClipboardList, label: 'Log', hint: 'Replaced at stations, expected back' },
    { to: `${spec.base}/${spec.jobPath}`, icon: FlaskConical, label: spec.jobTab, hint: 'At the 3rd party' },
    { to: `${spec.base}/emergency`, icon: Siren, label: 'Emergency', hint: 'Emergency issues' },
  ]
  return (
    <PageContainer>
      <PageHeader title={spec.title} description={spec.description} />
      <SectionTabs label={`${spec.title} sections`} tabs={tabs} />
      <Outlet />
    </PageContainer>
  )
}

const day = (ts: string | null) => (ts ? ts.slice(0, 10) : null)
const Serial = ({ v }: { v: string | null }) => (v ? <Identifier value={v} /> : <NullValue />)
const DateCell = ({ v }: { v: string | null }) => (v ? <span className="tabular">{v.slice(0, 10)}</span> : <NullValue />)

/** What the item is: manufacturer and model for a detector; description and working pressure for a hose. */
function What({ kind, r }: { kind: EquipmentKind; r: { manufacturer?: string | null; model?: string | null; description?: string | null; working_pressure_value?: number | null; working_pressure_unit?: string | null } }) {
  if (kind === 'gas_detector') {
    const t = [r.manufacturer, r.model].filter(Boolean).join(' ')
    return t ? <span>{t}</span> : <NullValue />
  }
  return (
    <span>
      {r.description ? <span dir="auto">{r.description}</span> : null}
      {r.working_pressure_value != null ? <span className="tabular">{r.description ? ' · ' : ''}{r.working_pressure_value} {r.working_pressure_unit}</span> : null}
      {!r.description && r.working_pressure_value == null ? <NullValue /> : null}
    </span>
  )
}

function Toolbar({ label, children }: { label: string; children: ReactNode }) {
  return <DataToolbar label={label}>{children}</DataToolbar>
}

function Limit({ total }: { total: number }) {
  return total > EQUIPMENT_LIMIT ? (
    <p className="text-sm text-muted-foreground">Showing the latest {EQUIPMENT_LIMIT.toLocaleString()} of {total.toLocaleString()}. Narrow the search to see the rest.</p>
  ) : null
}

/* ============================================================== Warehouse */
export function EquipmentWarehouseSection({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const isAdmin = useIsAdmin()
  const [nonce, reload] = useNonce()
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('')
  const [due, setDue] = useState('all')
  const state = useEquipmentList<StockRow>('stock', kind, { search, status, due }, nonce)
  const counts = useEquipmentCounts('stock', kind, STORE_STATES, search, nonce)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [adding, setAdding] = useState(false)
  const [issuing, setIssuing] = useState<StockRow | null>(null)
  const [open, setOpen] = useState<StockRow | null>(null)
  const done = () => { setSelected(new Set()); reload() }
  const { act, busy, error, done: message } = useConfirmedAction(done)
  const rows = state.status === 'ready' ? state.data.rows : []
  const underCal = rows.filter((r) => selected.has(r.id) && r.availability_status === 'available_in_store_uc').map((r) => r.id)

  const columns: SelectableColumn<StockRow>[] = [
    { key: 'serial', header: 'Serial', render: (r) => <Serial v={r.serial_number} />, sortValue: (r) => r.serial_number },
    { key: 'state', header: 'Condition', render: (r) => <AvailabilityChip status={r.availability_status} label={spec.stateLabel[r.availability_status]} />, sortValue: (r) => r.availability_status },
    { key: 'what', header: kind === 'hose' ? 'Description' : 'Manufacturer / model', render: (r) => <What kind={kind} r={r} />, wrap: true },
    { key: 'code', header: 'Warehouse code', render: (r) => (r.warehouse_code ? <Identifier value={r.warehouse_code} /> : <NullValue />), sortValue: (r) => r.warehouse_code },
    { key: 'last', header: spec.lastLabel, render: (r) => <DateCell v={r.last_date} />, sortValue: (r) => r.last_date },
    { key: 'next', header: spec.nextLabel, render: (r) => <DateCell v={r.next_date} />, sortValue: (r) => r.next_date },
    { key: 'days', header: 'Days left', align: 'right', render: (r) => (r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()), sortValue: (r) => r.days_left },
    { key: 'due', header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
    ...(isAdmin ? [{
      key: 'issue', header: 'Issue', render: (r: StockRow) => (r.availability_status === 'available_in_store_uc' ? null : (
        <Button size="sm" variant="outline" className="h-7" onClick={(e) => { e.stopPropagation(); setIssuing(r) }}>Issue</Button>
      )),
    }] : []),
  ]

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <CountStrip label={`${spec.title} warehouse counts`} active={status || null}
                  onPick={(k) => setStatus(status === k ? '' : k)}
                  items={STORE_STATES.map((s) => ({ key: s, label: spec.stateLabel[s], value: counts ? counts[s] ?? null : null }))} />
      <Toolbar label={`Search and filter the ${spec.one} warehouse`}>
        <SearchBox id={`${kind}-stock-search`} label={`Search the ${spec.one} warehouse`} value={search} onChange={setSearch}
                   placeholder="Serial, code, manufacturer…" />
        <MultiSelectFilter id={`${kind}-stock-state`} label="Condition" value={status} onChange={setStatus}
                           options={STORE_STATES.map((s) => ({ value: s, label: spec.stateLabel[s] }))} />
        <MultiSelectFilter id={`${kind}-stock-due`} label="Due" value={due} empty="all" aliases={DUE_ALIASES} onChange={setDue} options={DUE_OPTIONS} />
        {isAdmin ? (
          <span className="ml-auto flex flex-wrap gap-2">
            <Button size="sm" className="h-7" variant="outline" disabled={underCal.length === 0 || busy}
                    onClick={() => void act(`${spec.jobVerb}: ${underCal.length} ${spec.many}?`, 'cng_equipment_calibration_send',
                      { p_stock_ids: underCal }, `${underCal.length} sent to the 3rd party.`)}>
              {spec.jobVerb}{underCal.length ? ` (${underCal.length})` : ''}
            </Button>
            <Button size="sm" className="h-7" onClick={() => setAdding(true)}><Plus className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Add {spec.many}</Button>
          </span>
        ) : null}
      </Toolbar>
      <FormMessage error={error} done={message} />
      <ListStates state={state} label={`the ${spec.one} warehouse`} reload={reload} empty={rows.length === 0}>
        <SelectableTable label={`${spec.title} warehouse`} rows={rows} columns={columns} selected={selected} onSelected={setSelected}
                         selection={isAdmin} selectable={(r) => r.availability_status === 'available_in_store_uc'} onOpen={setOpen} />
        <Limit total={state.status === 'ready' ? state.data.total : 0} />
      </ListStates>
      {isAdmin ? <p className="text-xs text-muted-foreground">Tick {spec.stateLabel.available_in_store_uc.toLowerCase()} items to send them to the 3rd party. New and {spec.stateLabel.available_calibrated.toLowerCase()} items can be issued to a station.</p> : null}
      {adding ? <AddStockDialog kind={kind} onClose={() => setAdding(false)} onAdded={reload} /> : null}
      {issuing ? <IssueDialog kind={kind} row={issuing} onClose={() => setIssuing(null)} onDone={reload} /> : null}
      <RecordDetailsDialog open={open !== null} title={`${spec.one[0].toUpperCase()}${spec.one.slice(1)} in the warehouse`} description="Complete details" onClose={() => setOpen(null)}>
        {open ? (
          <>
            <FactGrid>
              <Fact label="Serial"><Serial v={open.serial_number} /></Fact>
              <Fact label="Condition"><AvailabilityChip status={open.availability_status} label={spec.stateLabel[open.availability_status]} /></Fact>
              <Fact label="Warehouse code">{open.warehouse_code ? <Identifier value={open.warehouse_code} /> : <NullValue />}</Fact>
              {kind === 'gas_detector' ? (
                <>
                  <Fact label="Manufacturer">{open.manufacturer ?? <NullValue />}</Fact>
                  <Fact label="Model">{open.model ?? <NullValue />}</Fact>
                </>
              ) : (
                <>
                  <Fact label="Description">{open.description ? <span dir="auto">{open.description}</span> : <NullValue />}</Fact>
                  <Fact label="Working pressure">{open.working_pressure_value != null ? `${open.working_pressure_value} ${open.working_pressure_unit}` : <NullValue />}</Fact>
                  <Fact label="Test pressure">{open.test_pressure_value != null ? `${open.test_pressure_value} ${open.test_pressure_unit}` : <NullValue />}</Fact>
                </>
              )}
              <Fact label={spec.lastLabel}><DateCell v={open.last_date} /></Fact>
              <Fact label={spec.nextLabel}><DateCell v={open.next_date} /></Fact>
              <Fact label="Status"><DueBadge status={open.due_status} /></Fact>
              <Fact label="Notes">{open.notes ? <span dir="auto">{open.notes}</span> : <NullValue />}</Fact>
            </FactGrid>
            <ItemHistory kind={kind} id={open.id} />
          </>
        ) : null}
      </RecordDetailsDialog>
    </div>
  )
}

/* ============================================================== Log */
const LOG_STATUSES = ['at_station', 'returned'] as const
const LOG_LABEL: Record<string, string> = { at_station: 'At station', returned: 'Returned' }

export function EquipmentLogSection({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const isAdmin = useIsAdmin()
  const [nonce, reload] = useNonce()
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('at_station')
  const state = useEquipmentList<LogRow>('log', kind, { search, status }, nonce)
  const counts = useEquipmentCounts('log', kind, LOG_STATUSES, search, nonce)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const { act, busy, error, done } = useConfirmedAction(() => { setSelected(new Set()); reload() })
  const rows = state.status === 'ready' ? state.data.rows : []
  const picked = rows.filter((r) => selected.has(r.id) && r.status === 'at_station').map((r) => r.id)

  const columns: SelectableColumn<LogRow>[] = [
    { key: 'serial', header: 'Serial', render: (r) => <Serial v={r.serial_number} />, sortValue: (r) => r.serial_number },
    { key: 'what', header: kind === 'hose' ? 'Description' : 'Manufacturer / model', render: (r) => <What kind={kind} r={r} />, wrap: true },
    { key: 'station', header: 'Station', render: (r) => <span dir="auto">{r.station_name}</span>, sortValue: (r) => r.station_name, wrap: true },
    { key: 'unit', header: 'Unit', render: (r) => (r.unit_name ? <span dir="auto">{r.unit_name}</span> : <NullValue />), sortValue: (r) => r.unit_name },
    { key: 'region', header: 'Region', render: (r) => <RegionChip name={r.region_name} />, sortValue: (r) => r.region_name },
    { key: 'logged', header: 'Replaced', render: (r) => <DateCell v={r.logged_at} />, sortValue: (r) => r.logged_at },
    { key: 'status', header: 'Status', render: (r) => <span>{LOG_LABEL[r.status]}{r.is_emergency ? ' · emergency' : ''}</span>, sortValue: (r) => r.status },
    { key: 'returned', header: 'Received', render: (r) => <DateCell v={day(r.returned_at)} />, sortValue: (r) => r.returned_at },
  ]

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <CountStrip label={`${spec.title} Log counts`} active={status || null} onPick={(k) => setStatus(status === k ? '' : k)}
                  items={LOG_STATUSES.map((s) => ({ key: s, label: LOG_LABEL[s], value: counts ? counts[s] ?? null : null }))} />
      <Toolbar label={`Search the ${spec.one} Log`}>
        <SearchBox id={`${kind}-log-search`} label={`Search the ${spec.one} Log`} value={search} onChange={setSearch} placeholder="Serial, Station, Unit…" />
        {isAdmin ? (
          <span className="ml-auto">
            <Button size="sm" className="h-7" disabled={picked.length === 0 || busy}
                    onClick={() => void act(`Receive ${picked.length} ${spec.many} back at the warehouse?`, 'cng_equipment_log_receive',
                      { p_log_ids: picked }, `${picked.length} received; now in the store as ${spec.stateLabel.available_in_store_uc.toLowerCase()}.`)}>
              Receive at warehouse{picked.length ? ` (${picked.length})` : ''}
            </Button>
          </span>
        ) : null}
      </Toolbar>
      <FormMessage error={error} done={done} />
      <ListStates state={state} label={`the ${spec.one} Log`} reload={reload} empty={rows.length === 0}>
        <SelectableTable label={`${spec.title} Log`} rows={rows} columns={columns} selected={selected} onSelected={setSelected}
                         selection={isAdmin} selectable={(r) => r.status === 'at_station'} />
        <Limit total={state.status === 'ready' ? state.data.total : 0} />
      </ListStates>
    </div>
  )
}

/* ============================================================== 3rd party */
const JOB_STATUSES = ['sent', 'returned_awaiting_certificate', 'certified'] as const
const JOB_LABEL: Record<string, string> = { sent: 'At the 3rd party', returned_awaiting_certificate: 'Awaiting certificate', certified: 'Certified' }

export function EquipmentJobsSection({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const isAdmin = useIsAdmin()
  const [nonce, reload] = useNonce()
  const [search, setSearch] = useState('')
  const [status, setStatus] = useState('sent|returned_awaiting_certificate')
  const state = useEquipmentList<JobRow>('jobs', kind, { search, status }, nonce)
  const counts = useEquipmentCounts('jobs', kind, JOB_STATUSES, search, nonce)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [certifying, setCertifying] = useState(false)
  const after = () => { setSelected(new Set()); reload() }
  const { act, busy, error, done } = useConfirmedAction(after)
  const rows = state.status === 'ready' ? state.data.rows : []
  const sent = rows.filter((r) => selected.has(r.id) && r.status === 'sent').map((r) => r.id)
  const open = rows.filter((r) => selected.has(r.id) && r.status !== 'certified').map((r) => r.id)

  const columns: SelectableColumn<JobRow>[] = [
    { key: 'serial', header: 'Serial', render: (r) => <Serial v={r.serial_number} />, sortValue: (r) => r.serial_number },
    { key: 'code', header: 'Warehouse code', render: (r) => (r.warehouse_code ? <Identifier value={r.warehouse_code} /> : <NullValue />), sortValue: (r) => r.warehouse_code },
    { key: 'what', header: kind === 'hose' ? 'Description' : 'Manufacturer / model', render: (r) => <What kind={kind} r={r} />, wrap: true },
    { key: 'status', header: 'Status', render: (r) => <span>{JOB_LABEL[r.status]}</span>, sortValue: (r) => r.status },
    { key: 'sent', header: 'Sent', render: (r) => <DateCell v={r.sent_at} />, sortValue: (r) => r.sent_at },
    { key: 'returned', header: 'Returned', render: (r) => <DateCell v={day(r.returned_at)} />, sortValue: (r) => r.returned_at },
    { key: 'cert', header: 'Certificate', render: (r) => (r.certificate_date ? <span className="tabular">{r.certificate_date}{r.certificate_number ? ` · ${r.certificate_number}` : ''}</span> : <NullValue />), sortValue: (r) => r.certificate_date },
    { key: 'next', header: spec.nextLabel, render: (r) => <DateCell v={r.next_date} />, sortValue: (r) => r.next_date },
  ]

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <CountStrip label={`${spec.jobTab} counts`} active={status || null} onPick={(k) => setStatus(status === k ? '' : k)}
                  items={JOB_STATUSES.map((s) => ({ key: s, label: JOB_LABEL[s], value: counts ? counts[s] ?? null : null }))} />
      <Toolbar label={`Search ${spec.jobTab}`}>
        <SearchBox id={`${kind}-jobs-search`} label={`Search ${spec.jobTab}`} value={search} onChange={setSearch} placeholder="Serial, code, certificate…" />
        <MultiSelectFilter id={`${kind}-jobs-status`} label="Status" value={status} onChange={setStatus}
                           options={JOB_STATUSES.map((s) => ({ value: s, label: JOB_LABEL[s] }))} />
        {isAdmin ? (
          <span className="ml-auto flex flex-wrap gap-2">
            <Button size="sm" className="h-7" variant="outline" disabled={sent.length === 0 || busy}
                    onClick={() => void act(`Mark ${sent.length} ${spec.many} returned from the 3rd party?`, 'cng_equipment_calibration_returned',
                      { p_job_ids: sent }, `${sent.length} marked returned; certificate awaited.`)}>
              Mark returned{sent.length ? ` (${sent.length})` : ''}
            </Button>
            <Button size="sm" className="h-7" disabled={open.length === 0 || busy} onClick={() => setCertifying(true)}>
              Certificate received{open.length ? ` (${open.length})` : ''}
            </Button>
          </span>
        ) : null}
      </Toolbar>
      <FormMessage error={error} done={done} />
      <ListStates state={state} label={spec.jobTab} reload={reload} empty={rows.length === 0}>
        <SelectableTable label={spec.jobTab} rows={rows} columns={columns} selected={selected} onSelected={setSelected}
                         selection={isAdmin} selectable={(r) => r.status !== 'certified'} />
        <Limit total={state.status === 'ready' ? state.data.total : 0} />
      </ListStates>
      {certifying ? <CertifyDialog kind={kind} jobIds={open} onClose={() => setCertifying(false)} onDone={after} /> : null}
    </div>
  )
}

/* ============================================================== Emergency */
export function EquipmentEmergencySection({ kind }: { kind: EquipmentKind }) {
  const spec = KINDS[kind]
  const [search, setSearch] = useState('')
  const [nonce, reload] = useNonce()
  const state = useEquipmentList<EmergencyRow>('emergency', kind, { search, status: '' }, nonce)
  const rows = state.status === 'ready' ? state.data.rows : []
  const columns: SelectableColumn<EmergencyRow>[] = [
    { key: 'issued', header: 'Issued', render: (r) => <DateCell v={r.issued_at} />, sortValue: (r) => r.issued_at },
    { key: 'station', header: 'Station', render: (r) => <span dir="auto">{r.station_name}</span>, sortValue: (r) => r.station_name, wrap: true },
    { key: 'unit', header: 'Unit', render: (r) => (r.unit_name ? <span dir="auto">{r.unit_name}</span> : <NullValue />), sortValue: (r) => r.unit_name },
    { key: 'region', header: 'Region', render: (r) => <RegionChip name={r.region_name} />, sortValue: (r) => r.region_name },
    { key: 'serial', header: 'Issued serial', render: (r) => <Serial v={r.issued_serial} />, sortValue: (r) => r.issued_serial },
    { key: 'what', header: kind === 'hose' ? 'Description' : 'Manufacturer / model', render: (r) => <What kind={kind} r={r} />, wrap: true },
    { key: 'replaced', header: 'Replaced serial', render: (r) => <Serial v={r.replaced_serial} />, sortValue: (r) => r.replaced_serial },
    { key: 'rstatus', header: 'Replaced item', render: (r) => (r.replaced_status ? LOG_LABEL[r.replaced_status] : <NullValue />), sortValue: (r) => r.replaced_status },
    { key: 'notes', header: 'Notes', render: (r) => (r.notes ? <span dir="auto">{r.notes}</span> : <NullValue />), wrap: true },
  ]
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <Toolbar label={`Search ${spec.one} emergency issues`}>
        <SearchBox id={`${kind}-em-search`} label={`Search ${spec.one} emergency issues`} value={search} onChange={setSearch} placeholder="Serial, code, Station…" />
      </Toolbar>
      <ListStates state={state} label={`${spec.one} emergency issues`} reload={reload} empty={rows.length === 0}>
        <SelectableTable label={`${spec.title} emergency issues`} rows={rows} columns={columns} selected={new Set()} onSelected={() => {}}
                         selection={false} selectable={() => false} />
        <Limit total={state.status === 'ready' ? state.data.total : 0} />
      </ListStates>
      <p className="text-xs text-muted-foreground">An emergency issue is made from the Warehouse tab (Issue → Emergency).</p>
    </div>
  )
}
