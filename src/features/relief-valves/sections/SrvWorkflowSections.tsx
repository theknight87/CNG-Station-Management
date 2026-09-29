import { useState, type ReactNode } from 'react'
import { ArrowRightLeft, Pencil, Trash2, Undo2, X } from 'lucide-react'

import { SearchBox } from '@/components/data/FilterControls'
import { InfoTip } from '@/components/ui/InfoTip'
import { filterControl, filterLabel } from '@/components/data/filterStyles'
import type { DateOption } from '@/components/data/dateRange'
import { DataToolbar } from '@/components/layout/PageContainer'
import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { ExportButtons } from '@/features/export/ExportButtons'
import { CALIBRATION_COLUMNS, EMERGENCY_COLUMNS, ISSUE_LOG_COLUMNS, ISSUE_STATUS, SRV_LOG_COLUMNS } from '@/features/export/exportColumns'
import { rowsLoader } from '@/features/export/exportData'
import { buildCalibrationForm, formIsoDate, loadOriginStations, orderForForm, type CalibrationFormRow } from '@/features/export/calibrationForm'
import { useSupabaseClient } from '@/lib/supabase/client'
import { cn } from '@/lib/utils'
import { NullValue } from '@/components/data/NullValue'
import { Button } from '@/components/ui/button'
import { EMPTY_SMART_FILTERS, hasSmartFilters, type SrvSmartFilters } from '@/features/relief-valves/useSrvManagement'
import type { Loadable } from '@/features/hierarchy/useHierarchy'
import { ManufacturerChip, RegionChip, SmartFilterBar, ToneChip } from '@/features/relief-valves/SrvPieces'
import { byValues, pressureBar, type ToneName } from '@/features/relief-valves/srvSort'
import {
  Code, CountStrip, FormMessage, ListStates, Pressure, SelectableTable, ValveHistory, ValveSize,
} from '@/features/relief-valves/SrvWorkflowPieces'
import {
  CalibrationEditDialog, LogMoveDialog, RowAction, RowActions,
} from '@/features/relief-valves/SrvAdminActions'
import {
  WORKFLOW_DATES, sizeText, useConfirmedAction, useWorkflowCounts, useIsAdmin, useWorkflowAction, useWorkflowList,
  type CalibrationRow, type ValveFields, type EmergencyRow, type FieldLogRow, type IssueLogRow,
} from '@/features/relief-valves/useSrvWorkflow'

const day = (ts: string | null) => (ts ? <span className="tabular whitespace-nowrap">{ts.slice(0, 10)}</span> : <NullValue />)

function Truncated({ shown, total }: { shown: number; total: number }) {
  return total > shown ? (
    <p className="text-xs text-muted-foreground">
      Showing the newest {shown.toLocaleString()} of {total.toLocaleString()}. Narrow the filters to see the rest.
    </p>
  ) : null
}

function HistoryDialog({ valveId, title, onClose, note, children }: {
  valveId: string | null; title: string; onClose: () => void; note?: string
  /** Details shown above the movements (e.g. an emergency issue's notes). */
  children?: ReactNode
}) {
  return (
    <RecordDetailsDialog open={valveId !== null} title={title} description={note ?? 'Movements of this valve'} onClose={onClose}>
      {children}
      {valveId ? <ValveHistory valveId={valveId} /> : null}
    </RecordDetailsDialog>
  )
}

/**
 * One toolbar per workflow tab, the same shape as the registries' (owner request 2026-09-29): the search box, the
 * dedicated filters, Clear, and the tab's actions on the right.
 */
function WorkflowToolbar({ id, label, placeholder, filters, onFilters, showRegion = true, date, info, filtersBefore, children }: {
  id: string
  label: string
  /** What the tab is, behind an (i). */
  info: { label: string; text: ReactNode }
  /** A tab-specific filter shown first after the search (e.g. the SRV Log movement). */
  filtersBefore?: ReactNode
  placeholder: string
  filters: SrvSmartFilters
  onFilters: (f: SrvSmartFilters) => void
  showRegion?: boolean
  date: DateOption
  children?: ReactNode
}) {
  return (
    <DataToolbar label={label}>
      <InfoTip label={info.label}>{info.text}</InfoTip>
      <SearchBox id={`${id}-search`} label={label} placeholder={placeholder} value={filters.search}
                 onChange={(search) => onFilters({ ...filters, search })} />
      {filtersBefore}
      <SmartFilterBar id={id} value={filters} onChange={onFilters} showRegion={showRegion} date={date} />
      {hasSmartFilters(filters) ? (
        <Button variant="ghost" size="sm" className="h-7" onClick={() => onFilters(EMPTY_SMART_FILTERS)}>
          <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Clear
        </Button>
      ) : null}
      <span className="ml-auto flex flex-wrap items-center gap-2">{children}</span>
    </DataToolbar>
  )
}

// ---------------------------------------------------------------------------------------------- SRV Log

const LOG_TONE: Record<FieldLogRow['status'], ToneName> = {
  at_station: 'sky', location_unconfirmed: 'orange', returned: 'teal',
}

const sizeOf = (r: Pick<ValveFields, 'size_type' | 'inlet_size' | 'outlet_size'>) => sizeText(r.size_type, r.inlet_size, r.outlet_size) || null
const logSince = (r: FieldLogRow) => (r.reason === 'replaced_on_issue' ? r.logged_at : r.warehouse_issue_date ?? r.logged_at)

const LOG_STATUS: Record<FieldLogRow['status'], string> = {
  at_station: 'At station — awaiting return',
  location_unconfirmed: 'Location unconfirmed',
  returned: 'Returned to warehouse',
}
const LOG_REASON: Record<FieldLogRow['reason'], string> = {
  replaced_on_issue: 'Replaced by an issued valve',
  reconcile_other_serial: 'Sent to this Station, but the Station records a different valve',
  reconcile_station_not_found: 'Sent to this Station, but no valves are recorded there',
  issue_undone: 'Its issue was undone; it is still at the station',
}

/**
 * The SRV Log movements (owner request 2026-09-29):
 *   Issue            valves issued from the warehouse and fitted at a station, with whether the valve each one
 *                    replaced is back yet (finished issues drop off after six months — hidden, never deleted);
 *   Awaiting return  valves out at stations, expected back (the replaced ones, and any sent out by reconciliation);
 *   Return           valves received back at the warehouse.
 */
type LogView = 'issue' | 'open' | FieldLogRow['status']
const LOG_STATUSES = ['at_station', 'location_unconfirmed', 'returned'] as const
const ISSUE_STATUSES = ['awaiting_replaced', 'replaced_returned', 'no_replacement', 'replaced_entry_removed'] as const
const LOG_DOT: Record<FieldLogRow['status'], string> = {
  at_station: 'bg-blue-600', location_unconfirmed: 'bg-orange-500', returned: 'bg-emerald-600',
}
const ISSUE_TONE: Record<IssueLogRow['status'], ToneName | null> = {
  awaiting_replaced: 'sky', replaced_returned: 'teal', no_replacement: null, replaced_entry_removed: 'orange',
}

function CountsFailed() {
  return <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">The counts could not be loaded, so none are shown. The table below is unaffected.</p>
}

const countOf = (counts: Loadable<Record<string, number>>) => (k: string) => (counts.status === 'ready' ? counts.data[k] ?? 0 : null)
const sumOf = (...v: (number | null)[]) => (v.some((x) => x === null) ? null : v.reduce<number>((a, x) => a + (x ?? 0), 0))

/** The SRV Log count strip; follows every filter above the table. */
function LogCounts({ counts, issues, filtered, view, onPick }: {
  counts: Loadable<Record<string, number>>
  issues: Loadable<Record<string, number>>
  filtered: boolean
  view: LogView
  onPick: (v: LogView) => void
}) {
  if (counts.status === 'error' || issues.status === 'error') return <CountsFailed />
  const n = countOf(counts), i = countOf(issues)
  const atStation = n('at_station'), unconfirmed = n('location_unconfirmed'), returned = n('returned')
  return (
    <CountStrip
      label="SRV Log counts"
      active={view}
      onPick={(k) => onPick(k as LogView)}
      note={filtered ? 'Counts follow the filters below.' : null}
      items={[
        { key: 'issue', label: 'Issue', value: sumOf(...ISSUE_STATUSES.map(i)), hint: `${i('awaiting_replaced') ?? '—'} still waiting for the replaced valve` },
        { key: 'open', label: 'Awaiting return', value: sumOf(atStation, unconfirmed), hint: 'still out of the warehouse' },
        { key: 'at_station', label: 'At station', value: atStation, dot: LOG_DOT.at_station },
        { key: 'location_unconfirmed', label: 'Location unconfirmed', value: unconfirmed, dot: LOG_DOT.location_unconfirmed },
        { key: 'returned', label: 'Return', value: returned, dot: LOG_DOT.returned, hint: 'back in the warehouse' },
      ]}
    />
  )
}

/**
 * Undo an issue: the replaced valve goes back to its position and the issued valve leaves the station — the admin
 * says where it is (owner report 2026-09-29: undoing only the replaced half left two valves in one position).
 */
function UndoIssueDialog({ target, onClose, onDone }: {
  target: { issueId: string; issued: string | null; replaced: string | null } | null
  onClose: () => void
  onDone: (message: string) => void
}) {
  const [action, setAction] = useState<'to_stock' | 'await_return'>('to_stock')
  const [error, setError] = useState<string | null>(null)
  const { run, busy } = useWorkflowAction()
  async function confirm() {
    if (!target) return
    setError(null)
    const err = await run('cng_srv_issue_undo', { p_issue_id: target.issueId, p_issued_action: action })
    if (err) { setError(err); return }
    onDone(action === 'to_stock'
      ? 'Issue undone: the replaced valve is back in its position and the issued valve is back in warehouse stock.'
      : 'Issue undone: the replaced valve is back in its position; the issued valve is in the SRV Log awaiting return.')
    onClose()
  }
  const issued = target?.issued ? `serial ${target.issued}` : 'the issued valve'
  return (
    <RecordDetailsDialog open={target !== null} title="Undo this replacement"
                         description={target?.replaced ? `Serial ${target.replaced} goes back to its position at the station.` : 'The issue is cancelled.'}
                         onClose={onClose}>
      <fieldset className="flex flex-col gap-2 text-sm">
        <legend className="mb-1 font-medium">Where is {issued} now?</legend>
        <label className={cn('flex items-start gap-2 rounded border p-2', action === 'to_stock' && 'border-brand-strong')}>
          <input type="radio" name="undo-action" className="mt-1" checked={action === 'to_stock'} onChange={() => setAction('to_stock')} />
          <span><span className="font-medium">Back in the warehouse (recommended)</span>
            <span className="block text-xs text-muted-foreground">It was never fitted, or it is already back: stock again as it was, same code.</span></span>
        </label>
        <label className={cn('flex items-start gap-2 rounded border p-2', action === 'await_return' && 'border-brand-strong')}>
          <input type="radio" name="undo-action" className="mt-1" checked={action === 'await_return'} onChange={() => setAction('await_return')} />
          <span><span className="font-medium">Still at the station</span>
            <span className="block text-xs text-muted-foreground">It goes to the SRV Log as awaiting return, and is received like any valve when it arrives.</span></span>
        </label>
      </fieldset>
      <FormMessage error={error} done={null} />
      <div className="mt-2 flex justify-end gap-2">
        <Button size="sm" variant="outline" onClick={onClose}>Cancel</Button>
        <Button size="sm" disabled={busy} onClick={() => void confirm()}>{busy ? 'Undoing…' : 'Undo replacement'}</Button>
      </div>
    </RecordDetailsDialog>
  )
}

export function SrvLogSection() {
  const isAdmin = useIsAdmin()
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const [view, setView] = useState<LogView>('open')
  const showIssues = view === 'issue'
  const { state, reload, version } = useWorkflowList<FieldLogRow>('log', {
    status: view === 'open' ? ['at_station', 'location_unconfirmed'] : [view], filters, skip: showIssues,
  })
  const issueList = useWorkflowList<IssueLogRow>('issues', { filters, skip: !showIssues })
  const counts = useWorkflowCounts('log', LOG_STATUSES, filters, version + issueList.version)
  const issueCounts = useWorkflowCounts('issues', ISSUE_STATUSES, filters, version + issueList.version)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const [open, setOpen] = useState<FieldLogRow | null>(null)
  const [openIssue, setOpenIssue] = useState<IssueLogRow | null>(null)
  const [moving, setMoving] = useState<string | null>(null)
  const [undo, setUndo] = useState<{ issueId: string; issued: string | null; replaced: string | null } | null>(null)
  const { run, busy } = useWorkflowAction()
  const admin = useConfirmedAction(reload)
  const rows = state.status === 'ready' ? state.data.rows : []
  const issues = issueList.state.status === 'ready' ? issueList.state.data.rows : []
  const reloadAll = () => { reload(); issueList.reload() }
  const pick = (v: LogView) => { setView(v); setSelected(new Set()) }

  async function receive() {
    setError(null); setDone(null)
    const err = await run('cng_srv_log_receive', { p_log_ids: [...selected] })
    if (err) { setError(err); return }
    setDone(`${selected.size} valve(s) received; they are back in the warehouse as available — under calibration.`)
    setSelected(new Set()); reloadAll()
  }

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <LogCounts counts={counts} issues={issueCounts} filtered={hasSmartFilters(filters)} view={view} onPick={pick} />
      <WorkflowToolbar id="srv-log" label="Search and filter the SRV Log"
                       info={{ label: 'About the SRV Log', text: 'Issue: valves fitted at stations from the warehouse, and whether the valve each one replaced is back (finished ones drop off after six months). Awaiting return: valves out at stations, expected back — tick the ones that arrived and confirm. Return: valves received back.' }}
                       placeholder="Serial, code, station…"
                       filters={filters} onFilters={(f) => { setFilters(f); setSelected(new Set()) }}
                       date={showIssues ? WORKFLOW_DATES.issues : WORKFLOW_DATES.log}
                       filtersBefore={
                         // Three movements (owner request 2026-09-29), in step with the counts above; a finer view
                         // picked there (at station / location unconfirmed) shows as Awaiting return here.
                         <label className={filterLabel} htmlFor="srv-log-movement">
                           Movement
                           <select id="srv-log-movement" className={filterControl}
                                   value={view === 'at_station' || view === 'location_unconfirmed' ? 'open' : view}
                                   onChange={(e) => pick(e.target.value as LogView)}>
                             <option value="issue">Issue</option>
                             <option value="open">Awaiting return</option>
                             <option value="returned">Return</option>
                           </select>
                         </label>
                       }>
        {isAdmin && !showIssues ? (
          <Button size="sm" className="h-7" disabled={selected.size === 0 || busy} onClick={() => void receive()}>
            {busy ? 'Saving…' : `Arrived at warehouse (${selected.size})`}
          </Button>
        ) : null}
        {showIssues
          ? <ExportButtons name="srv-issues" load={rowsLoader('SRV Issues', ISSUE_LOG_COLUMNS, issues, issueList.state.status === 'ready' && issueList.state.data.total > issues.length)} />
          : <ExportButtons name="srv-log" load={rowsLoader('SRV Log', SRV_LOG_COLUMNS, rows, state.status === 'ready' && state.data.total > rows.length)} />}
      </WorkflowToolbar>
      <FormMessage error={error ?? admin.error} done={done ?? admin.done} />
      <LogMoveDialog logId={moving} onClose={() => setMoving(null)} onDone={reload} />
      <UndoIssueDialog target={undo} onClose={() => setUndo(null)} onDone={(m) => { setError(null); setDone(m); reloadAll() }} />

      {showIssues ? (
        <ListStates state={issueList.state} label="issues" reload={issueList.reload} empty={issues.length === 0}>
          <SelectableTable
            label="SRV Issues"
            rows={issues}
            selected={new Set()}
            onSelected={() => {}}
            selectable={() => false}
            selection={false}
            onOpen={setOpenIssue}
            defaultOrder={(a, b) => b.issued_at.localeCompare(a.issued_at)}
            columns={[
              { key: 'date', header: 'Issued', sortValue: (r) => r.issued_at, render: (r) => day(r.issued_at) },
              { key: 'region', header: 'Region', sortValue: (r) => r.region_name, render: (r) => <RegionChip name={r.region_name} /> },
              { key: 'station', header: 'Station', wrap: true, sortValue: (r) => r.station_name, render: (r) => (
                <span className="flex flex-col items-start">
                  <span dir="auto">{r.station_name}</span>
                  <span dir="auto" className="text-xs text-muted-foreground">{r.unit_name}</span>
                </span>) },
              { key: 'issued', header: 'Issued valve', sortValue: (r) => r.issued_serial, render: (r) => (
                <span className="flex flex-col items-start"><Code value={r.issued_serial} /><span className="text-xs"><Code value={r.issued_code} /></span></span>) },
              { key: 'pressure', header: 'Set pressure', align: 'right', sortValue: pressureBar, render: (r) => <Pressure v={r} /> },
              { key: 'manufacturer', header: 'Manufacturer', sortValue: (r) => r.manufacturer, render: (r) => <ManufacturerChip value={r.manufacturer} /> },
              { key: 'size', header: 'Size', sortValue: sizeOf, render: (r) => <ValveSize v={r} /> },
              { key: 'replaced', header: 'Replaced valve', sortValue: (r) => ISSUE_STATUS[r.status], render: (r) => (
                <span className="flex flex-col items-start gap-0.5">
                  {r.replaced_installed_valve_id ? <Code value={r.replaced_serial} /> : null}
                  {ISSUE_TONE[r.status]
                    ? <ToneChip tone={ISSUE_TONE[r.status]!}>{r.status === 'replaced_returned' && r.replaced_returned_at
                        ? `Returned ${r.replaced_returned_at.slice(0, 10)}` : ISSUE_STATUS[r.status]}</ToneChip>
                    : <span className="text-muted-foreground">{ISSUE_STATUS[r.status]}</span>}
                  {r.is_emergency ? <ToneChip tone="orange">Emergency</ToneChip> : null}
                </span>) },
              ...(isAdmin ? [{ key: 'actions', header: 'Actions', render: (r: IssueLogRow) => (
                <RowActions>
                  {r.status !== 'replaced_returned' ? (
                    <RowAction label="Undo replacement" icon={Undo2}
                      onClick={() => setUndo({ issueId: r.id, issued: r.issued_serial, replaced: r.replaced_serial })} />
                  ) : <span aria-hidden="true" className="w-7 shrink-0" />}
                </RowActions>) }] : []),
            ]}
          />
          {issueList.state.status === 'ready' ? <Truncated shown={issues.length} total={issueList.state.data.total} /> : null}
        </ListStates>
      ) : (
        <ListStates state={state} label="the SRV Log" reload={reload} empty={rows.length === 0}>
          <SelectableTable
            label="SRV Log"
            rows={rows}
            selected={selected}
            onSelected={setSelected}
            selectable={(r) => isAdmin && r.status !== 'returned'}
            onOpen={setOpen}
            defaultOrder={byValues<FieldLogRow>((r) => r.region_name, (r) => r.station_display, pressureBar)}
            columns={[
              { key: 'serial', header: 'Serial', sortValue: (r) => r.serial_number, render: (r) => <Code value={r.serial_number} /> },
              { key: 'code', header: 'Code', sortValue: (r) => r.warehouse_code, render: (r) => <Code value={r.warehouse_code} /> },
              { key: 'pressure', header: 'Set pressure', align: 'right', sortValue: pressureBar, render: (r) => <Pressure v={r} /> },
              { key: 'manufacturer', header: 'Manufacturer', sortValue: (r) => r.manufacturer, render: (r) => <ManufacturerChip value={r.manufacturer} /> },
              { key: 'size', header: 'Size', sortValue: sizeOf, render: (r) => <ValveSize v={r} /> },
              { key: 'region', header: 'Region', sortValue: (r) => r.region_name, render: (r) => <RegionChip name={r.region_name} /> },
              { key: 'station', header: 'Station', wrap: true, sortValue: (r) => r.station_display, render: (r) => (
                // Unit on its own line: a mixed Arabic "Station / Unit" on one line reorders under bidi.
                <span className="flex flex-col items-start">
                  <span dir="auto">{r.station_display ?? <NullValue />}</span>
                  {r.unit_name ? <span dir="auto" className="text-xs text-muted-foreground">{r.unit_name}</span> : null}
                </span>) },
              { key: 'status', header: 'Status', sortValue: (r) => LOG_STATUS[r.status], render: (r) => (
                <span className="flex flex-col items-start gap-0.5">
                  <ToneChip tone={LOG_TONE[r.status]}>{LOG_STATUS[r.status]}</ToneChip>
                  {r.is_emergency ? <ToneChip tone={LOG_TONE[r.status]}>Emergency</ToneChip> : null}
                </span>) },
              { key: 'since', header: 'Since', sortValue: logSince, render: (r) => day(logSince(r)) },
              ...(isAdmin ? [{ key: 'actions', header: 'Actions', render: (r: FieldLogRow) => (
                <RowActions>
                  {/* A replaced valve goes back to its position only by undoing its issue, so the issued valve does
                    * not stay installed beside it (owner report 2026-09-29). */}
                  {r.reason === 'replaced_on_issue' && r.issue_id && !r.issue_cancelled && r.status !== 'returned' ? (
                    <RowAction label="Back to its station (undo the replacement)" icon={Undo2}
                      onClick={() => setUndo({ issueId: r.issue_id!, issued: null, replaced: r.serial_number })} />
                  ) : <span aria-hidden="true" className="w-7 shrink-0" />}
                  <RowAction label="Move" icon={ArrowRightLeft} disabled={admin.busy} onClick={() => setMoving(r.id)} />
                  <RowAction label="Delete" icon={Trash2} danger disabled={admin.busy}
                    onClick={() => void admin.act('Remove this entry from the SRV Log? It is archived (kept in the audit history).',
                      'cng_srv_log_archive', { p_log_id: r.id }, 'Entry removed from the SRV Log.')} />
                </RowActions>) }] : []),
            ]}
          />
          {state.status === 'ready' ? <Truncated shown={rows.length} total={state.data.total} /> : null}
        </ListStates>
      )}
      <HistoryDialog valveId={open ? open.installed_valve_id ?? open.warehouse_valve_id : null}
                     title={`SRV ${open?.serial_number ?? ''}`} onClose={() => setOpen(null)}
                     note={open ? `Why it is in the SRV Log: ${LOG_REASON[open.reason]}` : undefined} />
      <HistoryDialog valveId={openIssue?.warehouse_valve_id ?? null} title={`SRV ${openIssue?.issued_serial ?? ''}`}
                     onClose={() => setOpenIssue(null)}
                     note={openIssue ? `Issued to ${openIssue.station_name} / ${openIssue.unit_name} — ${ISSUE_STATUS[openIssue.status]}` : undefined} />
    </div>
  )
}

// ---------------------------------------------------------------------------------------------- Calibration

const CAL_TONE: Record<CalibrationRow['status'], ToneName> = {
  sent: 'violet', returned_awaiting_certificate: 'orange', certified: 'teal',
}

const CAL_STATUS: Record<CalibrationRow['status'], string> = {
  sent: 'At the calibration company',
  returned_awaiting_certificate: 'Returned — certificate awaited',
  certified: 'Returned with certificate',
}

type CalView = 'open' | 'all' | CalibrationRow['status']
const CAL_STATUSES = ['sent', 'returned_awaiting_certificate', 'certified'] as const
const CAL_DOT: Record<CalibrationRow['status'], string> = {
  sent: 'bg-purple-600', returned_awaiting_certificate: 'bg-orange-500', certified: 'bg-emerald-600',
}

/** The Calibration count strip: open work first, then each status. Follows every filter above the table. */
function CalibrationCounts({ counts, filtered, status, onPick }: {
  counts: Loadable<Record<string, number>>
  filtered: boolean
  status: CalView
  onPick: (s: CalView) => void
}) {
  if (counts.status === 'error') return <CountsFailed />
  const n = countOf(counts)
  const sent = n('sent'), awaiting = n('returned_awaiting_certificate'), certified = n('certified')
  return (
    <CountStrip
      label="Calibration counts"
      active={status}
      onPick={(k) => onPick(k as CalView)}
      note={filtered ? 'Counts follow the filters below.' : null}
      items={[
        { key: 'open', label: 'Not yet certified', value: sumOf(sent, awaiting), hint: 'at the company or awaiting certificate' },
        { key: 'sent', label: 'At the company', value: sent, dot: CAL_DOT.sent },
        { key: 'returned_awaiting_certificate', label: 'Certificate awaited', value: awaiting, dot: CAL_DOT.returned_awaiting_certificate },
        { key: 'certified', label: 'Certified', value: certified, dot: CAL_DOT.certified, hint: 'back in the warehouse' },
        { key: 'all', label: 'All entries', value: sumOf(sent, awaiting, certified) },
      ]}
    />
  )
}

export function SrvCalibrationSection() {
  const isAdmin = useIsAdmin()
  const supabase = useSupabaseClient()
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const [status, setStatus] = useState<CalView>('open')
  const { state, reload, version } = useWorkflowList<CalibrationRow>('calibration', {
    status: status === 'all' ? undefined : status === 'open' ? ['sent', 'returned_awaiting_certificate'] : [status], filters,
  })
  const counts = useWorkflowCounts('calibration', CAL_STATUSES, filters, version)
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [certDate, setCertDate] = useState('')
  const [certNo, setCertNo] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const [open, setOpen] = useState<CalibrationRow | null>(null)
  const [editing, setEditing] = useState<CalibrationRow | null>(null)
  const { run, busy } = useWorkflowAction()
  const admin = useConfirmedAction(reload)
  const rows = state.status === 'ready' ? state.data.rows : []
  const picked = rows.filter((r) => selected.has(r.id))

  async function act(fn: string, args: Record<string, unknown>, message: string) {
    setError(null); setDone(null)
    const err = await run(fn, { p_job_ids: [...selected], ...args })
    if (err) { setError(err); return }
    setDone(message); setSelected(new Set()); reload()
  }

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <CalibrationCounts counts={counts} filtered={hasSmartFilters(filters)} status={status}
                         onPick={(s) => { setStatus(s); setSelected(new Set()) }} />
      {/* The status shown is chosen with the counts above, so no second status control repeats it. */}
      <WorkflowToolbar id="srv-cal" label="Search and filter calibration"
                       info={{ label: 'About Calibration (3rd party)', text: 'Valves at the calibration company. Send one with the + in Warehouse SRVs. With the certificate it returns to stock as calibrated, due again one year after the certificate date.' }} placeholder="Serial, code, part number, certificate…"
                       filters={filters} onFilters={(f) => { setFilters(f); setSelected(new Set()) }} showRegion={false}
                       date={WORKFLOW_DATES.calibration}>
        {/* Excel is the owner's request form; ticked rows only when any are ticked, otherwise the whole list shown. */}
        <ExportButtons name="srv-calibration" label={picked.length ? `Export ${picked.length} selected` : undefined}
            load={rowsLoader('Calibration (3rd party)', CALIBRATION_COLUMNS, picked.length ? picked : rows,
                             !picked.length && state.status === 'ready' && state.data.total > rows.length)}
            excel={async (sheets) => {
              if (!supabase) throw new Error('the database is not configured')
              const list = orderForForm(sheets[0].rows as CalibrationRow[])
              const origin = await loadOriginStations(supabase, list.map((r) => r.warehouse_valve_id))
              const formRows: CalibrationFormRow[] = list.map((r) => ({ ...r, origin_station: origin.get(r.warehouse_valve_id) ?? null }))
              const date = formIsoDate(list)
              return { blob: await buildCalibrationForm(formRows, date), fileName: `cng-calibration-request-${date}.xlsx` }
            }} />
      </WorkflowToolbar>
      {isAdmin && picked.length > 0 ? (
        <section aria-label="Calibration actions" className="flex flex-wrap items-end gap-2 rounded border bg-card px-3 py-2">
          <Button size="sm" variant="outline" disabled={busy || picked.some((r) => r.status !== 'sent')}
                  onClick={() => void act('cng_srv_calibration_returned', {}, `${picked.length} marked returned; certificate awaited.`)}>
            Returned — certificate awaited ({picked.length})
          </Button>
          <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
            Certificate date
            <input type="date" className="h-8 rounded border bg-background px-2 text-sm" value={certDate} onChange={(e) => setCertDate(e.target.value)} />
          </label>
          <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
            Certificate no. (optional)
            <input className="h-8 w-32 rounded border bg-background px-2 text-sm" value={certNo} onChange={(e) => setCertNo(e.target.value)} />
          </label>
          <p className="self-center text-xs text-muted-foreground">Next calibration: one year after the certificate date.</p>
          <Button size="sm" disabled={busy || !certDate || picked.some((r) => r.status === 'certified')}
                  onClick={() => void act('cng_srv_calibration_certify', {
                    p_certificate_date: certDate, p_certificate_number: certNo.trim() || null, p_next_calibration_date: null,
                  }, `${picked.length} certified; back in the warehouse as available — calibrated.`)}>
            Returned with certificate ({picked.length})
          </Button>
        </section>
      ) : null}
      <FormMessage error={error ?? admin.error} done={done ?? admin.done} />
      <CalibrationEditDialog job={editing} onClose={() => setEditing(null)} onDone={reload} />
      <ListStates state={state} label="calibration" reload={reload} empty={rows.length === 0}>
        <SelectableTable
          label="Calibration (3rd party)"
          rows={rows}
          selected={selected}
          onSelected={setSelected}
          selectable={(r) => isAdmin && r.status !== 'certified'}
          onOpen={setOpen}
          defaultOrder={byValues<CalibrationRow>(pressureBar)}
          columns={[
            { key: 'code', header: 'Code', sortValue: (r) => r.warehouse_code, render: (r) => <Code value={r.warehouse_code} /> },
            { key: 'serial', header: 'Serial', sortValue: (r) => r.serial_number, render: (r) => <Code value={r.serial_number} /> },
            { key: 'pressure', header: 'Set pressure', align: 'right', sortValue: pressureBar, render: (r) => <Pressure v={r} /> },
            { key: 'manufacturer', header: 'Manufacturer', sortValue: (r) => r.manufacturer, render: (r) => <ManufacturerChip value={r.manufacturer} /> },
            { key: 'size', header: 'Size', sortValue: sizeOf, render: (r) => <ValveSize v={r} /> },
            { key: 'status', header: 'Status', sortValue: (r) => CAL_STATUS[r.status], render: (r) => <ToneChip tone={CAL_TONE[r.status]}>{CAL_STATUS[r.status]}</ToneChip> },
            { key: 'sent', header: 'Sent', sortValue: (r) => r.sent_at, render: (r) => day(r.sent_at) },
            { key: 'returned', header: 'Returned', sortValue: (r) => r.returned_at, render: (r) => day(r.returned_at) },
            { key: 'cert', header: 'Certificate', sortValue: (r) => r.certificate_date, render: (r) => r.certificate_date
              ? <span className="tabular">{r.certificate_date}{r.certificate_number ? ` · ${r.certificate_number}` : ''}</span> : <NullValue /> },
            ...(isAdmin ? [{ key: 'actions', header: 'Actions', render: (r: CalibrationRow) => (
              <RowActions>
                <RowAction label="Edit" icon={Pencil} disabled={admin.busy} onClick={() => setEditing(r)} />
                <RowAction label="Delete" icon={Trash2} danger disabled={admin.busy}
                  onClick={() => void admin.act('Remove this calibration entry? The valve returns to warehouse stock; the entry is archived.',
                    'cng_srv_calibration_archive', { p_job_id: r.id }, 'Calibration entry removed; the valve is back in warehouse stock.')} />
              </RowActions>) }] : []),
          ]}
        />
        {state.status === 'ready' ? <Truncated shown={rows.length} total={state.data.total} /> : null}
      </ListStates>
      <HistoryDialog valveId={open?.warehouse_valve_id ?? null} title={`SRV ${open?.serial_number ?? ''}`} onClose={() => setOpen(null)} />
    </div>
  )
}

// ---------------------------------------------------------------------------------------------- Emergency

export function SrvEmergencySection() {
  const isAdmin = useIsAdmin()
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const { state, reload } = useWorkflowList<EmergencyRow>('emergency', { filters })
  const [open, setOpen] = useState<EmergencyRow | null>(null)
  const admin = useConfirmedAction(reload)
  async function editNotes(r: EmergencyRow) {
    const notes = window.prompt('Notes for this emergency issue', r.notes ?? '')
    if (notes === null) return
    admin.setError(null); admin.setDone(null)
    const err = await admin.run('cng_srv_emergency_edit', { p_issue_id: r.id, p_notes: notes })
    if (err) admin.setError(err); else { admin.setDone('Notes saved.'); reload() }
  }
  const rows = state.status === 'ready' ? state.data.rows : []
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <WorkflowToolbar id="srv-emergency" label="Search and filter emergency issues"
                       info={{ label: 'About SRV Emergency', text: 'Every issue marked Emergency. The valve it replaced also stays in the SRV Log until it is back at the warehouse.' }} placeholder="Serial, code, station…"
                       filters={filters} onFilters={setFilters} date={WORKFLOW_DATES.emergency}>
        <ExportButtons name="srv-emergency" load={rowsLoader('SRV Emergency', EMERGENCY_COLUMNS, rows, state.status === 'ready' && state.data.total > rows.length)} />
      </WorkflowToolbar>
      <FormMessage error={admin.error} done={admin.done} />
      <ListStates state={state} label="emergency issues" reload={reload} empty={rows.length === 0}>
        <SelectableTable
          label="SRV Emergency"
          rows={rows}
          selected={new Set()}
          onSelected={() => {}}
          selectable={() => false}
          selection={false}
          onOpen={setOpen}
          defaultOrder={byValues<EmergencyRow>((r) => r.region_name, (r) => r.station_name, pressureBar)}
          columns={[
            { key: 'date', header: 'Issued', sortValue: (r) => r.issued_at, render: (r) => day(r.issued_at) },
            { key: 'region', header: 'Region', sortValue: (r) => r.region_name, render: (r) => <RegionChip name={r.region_name} /> },
            { key: 'station', header: 'Station / Unit', wrap: true, sortValue: (r) => r.station_name, render: (r) => (
              <span dir="auto">{r.station_name} / {r.unit_name}</span>) },
            { key: 'issued', header: 'Issued valve', sortValue: (r) => r.issued_serial, render: (r) => (
              <span className="flex flex-col items-start"><Code value={r.issued_serial} /><span className="text-xs"><Code value={r.issued_code} /></span></span>) },
            { key: 'pressure', header: 'Set pressure', align: 'right', sortValue: pressureBar, render: (r) => <Pressure v={r} /> },
            { key: 'manufacturer', header: 'Manufacturer', sortValue: (r) => r.manufacturer, render: (r) => <ManufacturerChip value={r.manufacturer} /> },
            { key: 'size', header: 'Size', sortValue: sizeOf, render: (r) => <ValveSize v={r} /> },
            // Replaced valve and where it is now, stacked in one column; the notes are in the details (owner request
            // 2026-09-29), so the table fits the page.
            { key: 'replaced', header: 'Replaced valve', sortValue: (r) => r.replaced_serial, render: (r) => r.replaced_installed_valve_id ? (
              <span className="flex flex-col items-start gap-0.5">
                <Code value={r.replaced_serial} />
                {r.replaced_status === 'returned' ? <ToneChip tone="teal">Returned to warehouse</ToneChip>
                  : r.replaced_status === 'at_station' ? <ToneChip tone="sky">At station — awaiting return</ToneChip> : null}
              </span>) : <span className="text-muted-foreground">None — added only</span> },
            ...(isAdmin ? [{ key: 'actions', header: 'Actions', render: (r: EmergencyRow) => (
              <RowActions>
                <RowAction label="Edit" icon={Pencil} disabled={admin.busy} onClick={() => void editNotes(r)} />
                <RowAction label="Delete" icon={Trash2} danger disabled={admin.busy}
                  onClick={() => void admin.act('Remove this issue from the Emergency list? The issue itself and its valves are not changed.',
                    'cng_srv_emergency_remove', { p_issue_id: r.id }, 'Removed from the Emergency list.')} />
              </RowActions>) }] : []),
          ]}
        />
        {state.status === 'ready' ? <Truncated shown={rows.length} total={state.data.total} /> : null}
      </ListStates>
      <HistoryDialog valveId={open?.warehouse_valve_id ?? null} title={`SRV ${open?.issued_serial ?? ''}`} onClose={() => setOpen(null)}
                     note="Emergency issue and the movements of the issued valve">
        {open ? (
          <section aria-label="Emergency issue" className="mb-3 rounded border bg-muted/30 px-3 py-2 text-sm">
            <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1">
              <dt className="text-muted-foreground">Issued</dt><dd>{day(open.issued_at)}</dd>
              <dt className="text-muted-foreground">Station / Unit</dt><dd dir="auto">{open.station_name} / {open.unit_name}</dd>
              <dt className="text-muted-foreground">Replaced valve</dt>
              <dd>{open.replaced_installed_valve_id ? <><Code value={open.replaced_serial} /> <Code value={open.replaced_code} /></> : 'None — added only'}</dd>
              <dt className="text-muted-foreground">Notes</dt>
              <dd dir="auto" className="whitespace-pre-wrap break-words">{open.notes ? open.notes : <NullValue />}</dd>
            </dl>
            {isAdmin ? (
              <Button size="sm" variant="outline" className="mt-2 h-7" disabled={admin.busy} onClick={() => void editNotes(open)}>
                <Pencil className="mr-1 h-3.5 w-3.5" aria-hidden="true" />Edit notes
              </Button>
            ) : null}
          </section>
        ) : null}
      </HistoryDialog>
    </div>
  )
}
