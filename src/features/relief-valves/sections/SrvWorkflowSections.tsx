import { useState } from 'react'

import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { NullValue } from '@/components/data/NullValue'
import { Button } from '@/components/ui/button'
import { EMPTY_SMART_FILTERS, type SrvSmartFilters } from '@/features/relief-valves/useSrvManagement'
import { SmartFilterBar } from '@/features/relief-valves/SrvPieces'
import {
  Code, FormMessage, ListStates, Pressure, SelectableTable, ValveHistory, ValveSize,
} from '@/features/relief-valves/SrvWorkflowPieces'
import {
  useIsAdmin, useWorkflowAction, useWorkflowList,
  type CalibrationRow, type EmergencyRow, type FieldLogRow,
} from '@/features/relief-valves/useSrvWorkflow'

const day = (ts: string | null) => (ts ? <span className="tabular whitespace-nowrap">{ts.slice(0, 10)}</span> : <NullValue />)

function Truncated({ shown, total }: { shown: number; total: number }) {
  return total > shown ? (
    <p className="text-xs text-muted-foreground">
      Showing the newest {shown.toLocaleString()} of {total.toLocaleString()}. Narrow the filters to see the rest.
    </p>
  ) : null
}

function HistoryDialog({ valveId, title, onClose }: { valveId: string | null; title: string; onClose: () => void }) {
  return (
    <RecordDetailsDialog open={valveId !== null} title={title} description="Movements of this valve" onClose={onClose}>
      {valveId ? <ValveHistory valveId={valveId} /> : null}
    </RecordDetailsDialog>
  )
}

// ---------------------------------------------------------------------------------------------- SRV Log

const LOG_STATUS: Record<FieldLogRow['status'], string> = {
  at_station: 'At station — awaiting return',
  location_unconfirmed: 'Location unconfirmed',
  returned: 'Returned to warehouse',
}
const LOG_REASON: Record<FieldLogRow['reason'], string> = {
  replaced_on_issue: 'Replaced by an issued valve',
  reconcile_other_serial: 'Sent to this Station, but the Station records a different valve',
  reconcile_station_not_found: 'Sent to this Station, but no valves are recorded there',
}

export function SrvLogSection() {
  const isAdmin = useIsAdmin()
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const [showReturned, setShowReturned] = useState(false)
  const { state, reload } = useWorkflowList<FieldLogRow>('log', {
    status: showReturned ? undefined : ['at_station', 'location_unconfirmed'], filters,
  })
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const [open, setOpen] = useState<FieldLogRow | null>(null)
  const { run, busy } = useWorkflowAction()
  const rows = state.status === 'ready' ? state.data.rows : []

  async function receive() {
    setError(null); setDone(null)
    const err = await run('cng_srv_log_receive', { p_log_ids: [...selected] })
    if (err) { setError(err); return }
    setDone(`${selected.size} valve(s) received; they are back in the warehouse as available — under calibration.`)
    setSelected(new Set()); reload()
  }

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <p className="text-sm text-muted-foreground">
        Valves that left the warehouse loop and are expected back. Tick the ones that arrived at the warehouse and
        confirm: they return to warehouse stock as available — under calibration.
      </p>
      <SmartFilterBar id="srv-log" value={filters} onChange={setFilters} />
      <div className="flex flex-wrap items-center gap-3">
        <label className="flex items-center gap-2 text-sm">
          <input type="checkbox" checked={showReturned} onChange={(e) => setShowReturned(e.target.checked)} />
          Include valves already returned
        </label>
        {isAdmin ? (
          <Button size="sm" disabled={selected.size === 0 || busy} onClick={() => void receive()}>
            {busy ? 'Saving…' : `Arrived at warehouse (${selected.size})`}
          </Button>
        ) : null}
      </div>
      <FormMessage error={error} done={done} />
      <ListStates state={state} label="the SRV Log" reload={reload} empty={rows.length === 0}>
        <SelectableTable
          label="SRV Log"
          rows={rows}
          selected={selected}
          onSelected={setSelected}
          selectable={(r) => isAdmin && r.status !== 'returned'}
          onOpen={setOpen}
          columns={[
            { key: 'serial', header: 'Serial', render: (r) => <Code value={r.serial_number} /> },
            { key: 'code', header: 'Code', render: (r) => <Code value={r.warehouse_code} /> },
            { key: 'pressure', header: 'Set pressure', align: 'right', render: (r) => <Pressure v={r} /> },
            { key: 'size', header: 'Size', render: (r) => <ValveSize v={r} /> },
            { key: 'station', header: 'Station', render: (r) => (
              <span dir="auto" className="whitespace-nowrap">{r.station_display ?? <NullValue />}
                {r.unit_name ? <span className="ml-1 text-xs text-muted-foreground">/ {r.unit_name}</span> : null}
                {r.region_name ? <span className="ml-1.5 text-xs text-muted-foreground">{r.region_name}</span> : null}
              </span>) },
            { key: 'status', header: 'Status', render: (r) => (
              <span className="whitespace-nowrap">{LOG_STATUS[r.status]}{r.is_emergency ? ' · Emergency' : ''}</span>) },
            { key: 'reason', header: 'Why it is here', render: (r) => <span className="text-xs">{LOG_REASON[r.reason]}</span> },
            { key: 'since', header: 'Since', render: (r) => day(r.reason === 'replaced_on_issue' ? r.logged_at : r.warehouse_issue_date ?? r.logged_at) },
          ]}
        />
        {state.status === 'ready' ? <Truncated shown={rows.length} total={state.data.total} /> : null}
      </ListStates>
      <HistoryDialog valveId={open ? open.installed_valve_id ?? open.warehouse_valve_id : null}
                     title={`SRV ${open?.serial_number ?? ''}`} onClose={() => setOpen(null)} />
    </div>
  )
}

// ---------------------------------------------------------------------------------------------- Calibration

const CAL_STATUS: Record<CalibrationRow['status'], string> = {
  sent: 'At the calibration company',
  returned_awaiting_certificate: 'Returned — certificate awaited',
  certified: 'Returned with certificate',
}

export function SrvCalibrationSection() {
  const isAdmin = useIsAdmin()
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const [status, setStatus] = useState<'open' | CalibrationRow['status']>('open')
  const { state, reload } = useWorkflowList<CalibrationRow>('calibration', {
    status: status === 'open' ? ['sent', 'returned_awaiting_certificate'] : [status], filters,
  })
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [certDate, setCertDate] = useState('')
  const [certNo, setCertNo] = useState('')
  const [nextDate, setNextDate] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const [open, setOpen] = useState<CalibrationRow | null>(null)
  const { run, busy } = useWorkflowAction()
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
      <p className="text-sm text-muted-foreground">
        Valves sent from the store to the calibration company. With the certificate they return to the warehouse as
        available — calibrated, dated by the certificate. Send a valve here with the + beside it in Warehouse SRVs.
      </p>
      <div className="flex flex-wrap items-end gap-3">
        <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
          Status
          <select className="h-7 rounded border bg-background px-1.5 text-sm text-foreground" value={status}
                  onChange={(e) => { setStatus(e.target.value as typeof status); setSelected(new Set()) }}>
            <option value="open">Not yet certified</option>
            <option value="sent">At the calibration company</option>
            <option value="returned_awaiting_certificate">Returned — certificate awaited</option>
            <option value="certified">Returned with certificate</option>
          </select>
        </label>
        <SmartFilterBar id="srv-cal" value={filters} onChange={setFilters} showRegion={false} showStation={false} />
      </div>
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
          <label className="flex flex-col gap-0.5 text-xs text-muted-foreground">
            Next calibration (optional)
            <input type="date" className="h-8 rounded border bg-background px-2 text-sm" value={nextDate} onChange={(e) => setNextDate(e.target.value)} />
          </label>
          <Button size="sm" disabled={busy || !certDate || picked.some((r) => r.status === 'certified')}
                  onClick={() => void act('cng_srv_calibration_certify', {
                    p_certificate_date: certDate, p_certificate_number: certNo.trim() || null, p_next_calibration_date: nextDate || null,
                  }, `${picked.length} certified; back in the warehouse as available — calibrated.`)}>
            Returned with certificate ({picked.length})
          </Button>
        </section>
      ) : null}
      <FormMessage error={error} done={done} />
      <ListStates state={state} label="calibration" reload={reload} empty={rows.length === 0}>
        <SelectableTable
          label="Calibration (3rd party)"
          rows={rows}
          selected={selected}
          onSelected={setSelected}
          selectable={(r) => isAdmin && r.status !== 'certified'}
          onOpen={setOpen}
          columns={[
            { key: 'code', header: 'Code', render: (r) => <Code value={r.warehouse_code} /> },
            { key: 'serial', header: 'Serial', render: (r) => <Code value={r.serial_number} /> },
            { key: 'pressure', header: 'Set pressure', align: 'right', render: (r) => <Pressure v={r} /> },
            { key: 'size', header: 'Size', render: (r) => <ValveSize v={r} /> },
            { key: 'status', header: 'Status', render: (r) => <span className="whitespace-nowrap">{CAL_STATUS[r.status]}</span> },
            { key: 'sent', header: 'Sent', render: (r) => day(r.sent_at) },
            { key: 'returned', header: 'Returned', render: (r) => day(r.returned_at) },
            { key: 'cert', header: 'Certificate', render: (r) => r.certificate_date
              ? <span className="tabular">{r.certificate_date}{r.certificate_number ? ` · ${r.certificate_number}` : ''}</span> : <NullValue /> },
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
  const [filters, setFilters] = useState<SrvSmartFilters>(EMPTY_SMART_FILTERS)
  const { state, reload } = useWorkflowList<EmergencyRow>('emergency', { filters })
  const [open, setOpen] = useState<EmergencyRow | null>(null)
  const rows = state.status === 'ready' ? state.data.rows : []
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <p className="text-sm text-muted-foreground">
        Every issue marked Emergency. The valve it replaced is also in the SRV Log until it returns to the warehouse.
      </p>
      <SmartFilterBar id="srv-emergency" value={filters} onChange={setFilters} />
      <ListStates state={state} label="emergency issues" reload={reload} empty={rows.length === 0}>
        <SelectableTable
          label="SRV Emergency"
          rows={rows}
          selected={new Set()}
          onSelected={() => {}}
          selectable={() => false}
          onOpen={setOpen}
          columns={[
            { key: 'date', header: 'Issued', render: (r) => day(r.issued_at) },
            { key: 'station', header: 'Station / Unit', render: (r) => (
              <span dir="auto" className="whitespace-nowrap">{r.station_name} / {r.unit_name}
                <span className="ml-1.5 text-xs text-muted-foreground">{r.region_name}</span></span>) },
            { key: 'issued', header: 'Issued valve', render: (r) => <span className="whitespace-nowrap"><Code value={r.issued_serial} /> <Code value={r.issued_code} /></span> },
            { key: 'pressure', header: 'Set pressure', align: 'right', render: (r) => <Pressure v={r} /> },
            { key: 'replaced', header: 'Replaced valve', render: (r) => r.replaced_installed_valve_id
              ? <Code value={r.replaced_serial} /> : <span className="text-muted-foreground">None — added only</span> },
            { key: 'rstatus', header: 'Replaced valve status', render: (r) => r.replaced_status === 'returned'
              ? 'Returned to warehouse' : r.replaced_status === 'at_station' ? 'At station — awaiting return' : <NullValue /> },
            { key: 'notes', header: 'Notes', render: (r) => r.notes ? <span dir="auto">{r.notes}</span> : <NullValue /> },
          ]}
        />
        {state.status === 'ready' ? <Truncated shown={rows.length} total={state.data.total} /> : null}
      </ListStates>
      <HistoryDialog valveId={open?.warehouse_valve_id ?? null} title={`SRV ${open?.issued_serial ?? ''}`} onClose={() => setOpen(null)} />
    </div>
  )
}
