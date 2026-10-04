import { AddWarehouseSrvsButton } from '@/features/relief-valves/AddWarehouseSrvs'
import { useSrvDeepLink } from '@/features/relief-valves/srvDeepLink'
import { ExportButtons } from '@/features/export/ExportButtons'
import { queryLoader } from '@/features/export/exportData'
import { WAREHOUSE_SRV_COLUMNS } from '@/features/export/exportColumns'
import { buildWarehouseWorkbook, warehouseWorkbookName } from '@/features/export/warehouseSheet'
import { AvailabilityChip, ManufacturerChip, RegionChip, SourceContext } from '@/features/relief-valves/SrvPieces'
import { useCallback, useState } from 'react'
import { Plus, Search, Trash2, Truck, Wrench, X } from 'lucide-react'

import { Identifier } from '@/components/data/TechnicalText'
import { RecordDetailsDialog } from '@/components/data/RecordDetailsDialog'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { DueBadge, PrecisionDate, PressureRange, Serial, Text } from '@/features/units/assetDisplay'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { SmartFilterBar } from '@/features/relief-valves/SrvPieces'
import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import {
  WAREHOUSE_DATE,
  hasSmartFilters,
  AVAILABILITY_LABEL, DEFAULT_WAREHOUSE_QUERY, useWarehouseSrvs, useWarehouseSummary, warehouseRequest,
  type WarehouseQuery, type WarehouseSrvRow, type WarehouseSort,
} from '@/features/relief-valves/useSrvManagement'
import { RemoveValveButton } from '@/features/relief-valves/SrvAdminActions'
import { WarehouseDestinationEditor } from '@/features/relief-valves/WarehouseDestinationEditor'
import { FormMessage, IssuePanel, ValveHistory } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction, workflowError } from '@/features/relief-valves/useSrvWorkflow'
import { useSupabaseClient } from '@/lib/supabase/client'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DUE_ALIASES, DUE_OPTIONS } from '@/components/data/multiFilter'

/**
 * Warehouse relief valves — INVENTORY, not hierarchy.
 *
 * These records have no Station, no Unit and no equipment parent. The table has
 * no hierarchy columns, no Region filter and no mapping status, because none of
 * those things exist for stock. Inventing them to make this screen resemble the
 * installed one would assert a physical position the data does not have.
 *
 * The schema DOES model a destination: `target_region` / `target_station`, with
 * availability states including "sent to station". That is where a valve is
 * being SENT, not where it is fitted, and it is labelled accordingly. It is
 * never rendered as the `Region → Station → Unit` hierarchy.
 *
 * Repair Kits are out of scope and are not inferred from warehouse stock.
 */


/** The store holds only these three (owner ruling); issued stock lives in the installed register and the SRV Log. */
const STOCK_STATUSES = ['available_new', 'available_calibrated', 'available_in_store_uc']

function SendToCalibration({ row, onSent }: { row: WarehouseSrvRow; onSent: () => void }) {
  const isAdmin = useIsAdmin()
  const { run, busy } = useWorkflowAction()
  const [error, setError] = useState<string | null>(null)
  if (!isAdmin || row.availability_status !== 'available_in_store_uc') return null
  return (
    <span className="inline-flex items-center gap-1">
      <button
        type="button"
        disabled={busy}
        title="Send to the calibration company"
        onClick={async (e) => {
          e.stopPropagation()
          setError(null)
          const err = await run('cng_srv_calibration_send', { p_warehouse_valve_ids: [row.id] })
          if (err) setError(err)
          else onSent()
        }}
        className="flex h-6 w-6 shrink-0 items-center justify-center rounded border border-foreground/30 bg-background text-foreground hover:bg-muted disabled:opacity-50"
      >
        <Plus className="h-3.5 w-3.5" aria-hidden="true" />
        <span className="sr-only">Send serial {row.serial_number ?? ''} to Calibration (3rd party)</span>
      </button>
      {error ? <span role="alert" className="text-xs text-destructive">{error}</span> : null}
    </span>
  )
}

/**
 * Bulk actions over the ticked rows of this page (admin only; the database refuses anyone else).
 * "Send to calibration" is one atomic call for the ticked valves that are under calibration; valves in
 * any other state are left alone and said so. "Delete" archives each valve through the same audited
 * function as the single delete, one call per valve, and reports any it could not remove.
 */
/**
 * Issue (صرف) straight from the table, beside a new or calibrated valve (owner request 2026-09-29). A truck, so it is
 * never confused with the + that sends an under-calibration valve to the calibration company. It opens the same
 * IssuePanel the details dialog uses; the database still decides (admin only, version-checked, audited).
 */
function IssueFromTable({ row, onIssued }: { row: WarehouseSrvRow; onIssued: () => void }) {
  const isAdmin = useIsAdmin()
  const [open, setOpen] = useState(false)
  if (!isAdmin || (row.availability_status !== 'available_new' && row.availability_status !== 'available_calibrated')) return null
  return (
    <>
      <button
        type="button"
        title="Issue to a station (صرف)"
        onClick={(e) => { e.stopPropagation(); setOpen(true) }}
        className="flex h-6 w-6 shrink-0 items-center justify-center rounded border border-[var(--brand-strong)] bg-background text-[var(--brand-strong)] hover:bg-muted"
      >
        <Truck className="h-3.5 w-3.5" aria-hidden="true" />
        <span className="sr-only">Issue serial {row.serial_number ?? ''} to a station</span>
      </button>
      {open ? (
        <span onClick={(e) => e.stopPropagation()}>
          <RecordDetailsDialog open title={`Issue SRV ${row.serial_number ?? ''}`.trim()} description="Choose the Station and Unit it goes to."
                               onClose={() => setOpen(false)}>
            <IssuePanel row={row} startOpen onCancel={() => setOpen(false)} onDone={() => { setOpen(false); onIssued() }} />
          </RecordDetailsDialog>
        </span>
      ) : null}
    </>
  )
}

function WarehouseBulkActions({ picked, onClear, onDone }: { picked: WarehouseSrvRow[]; onClear: () => void; onDone: () => void }) {
  const supabase = useSupabaseClient()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState<string | null>(null)
  const uc = picked.filter((r) => r.availability_status === 'available_in_store_uc')
  const skipped = picked.length - uc.length

  async function sendToCalibration() {
    if (!supabase || uc.length === 0) return
    setBusy(true); setError(null); setDone(null)
    try {
      const { error: err } = await supabase.rpc('cng_srv_calibration_send', { p_warehouse_valve_ids: uc.map((r) => r.id) })
      if (err) { setError(workflowError(err)); return }
      setDone(`${uc.length} valve(s) sent to Calibration (3rd party).${skipped ? ` ${skipped} not under calibration were left in the store.` : ''}`)
      onDone()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'The request failed.')
    } finally {
      setBusy(false)
    }
  }

  async function remove() {
    if (!supabase || picked.length === 0) return
    if (!window.confirm(`Remove ${picked.length} relief valve(s) from the warehouse? They are archived (kept in the audit history), not destroyed.`)) return
    setBusy(true); setError(null); setDone(null)
    let removed = 0
    const failed: string[] = []
    for (const r of picked) {
      try {
        const { error: err } = await supabase.rpc('cng_admin_archive_srv', { p_table: 'warehouse_relief_valves', p_id: r.id })
        if (err) failed.push(`${r.serial_number ?? r.warehouse_code ?? 'no serial'}: ${workflowError(err)}`)
        else removed += 1
      } catch (e) {
        failed.push(`${r.serial_number ?? r.warehouse_code ?? 'no serial'}: ${e instanceof Error ? e.message : 'the request failed'}`)
      }
    }
    setBusy(false)
    if (removed > 0) setDone(`${removed} relief valve(s) removed.`)
    if (failed.length > 0) setError(`${failed.length} could not be removed — ${failed.join('; ')}`)
    if (removed > 0) onDone()
  }

  return (
    <section aria-label="Actions on the selected valves" className="flex flex-wrap items-center gap-2 rounded border bg-card px-3 py-2">
      <span className="text-sm font-medium">{picked.length} selected</span>
      <Button size="sm" disabled={busy || uc.length === 0} onClick={() => void sendToCalibration()}
              title={uc.length === 0 ? 'Only valves in the store under calibration (UC) can be sent' : undefined}>
        <Wrench className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />
        Send to calibration ({uc.length})
      </Button>
      <Button size="sm" variant="destructive" disabled={busy || picked.length === 0} onClick={() => void remove()}>
        <Trash2 className="mr-1.5 h-3.5 w-3.5" aria-hidden="true" />
        Delete ({picked.length})
      </Button>
      <Button size="sm" variant="ghost" disabled={busy} onClick={onClear}>Clear selection</Button>
      {skipped > 0 && uc.length > 0 ? (
        <span className="text-xs text-muted-foreground">{skipped} selected are not under calibration and are not sent.</span>
      ) : null}
      <div className="basis-full empty:hidden"><FormMessage error={error} done={done} /></div>
    </section>
  )
}

function columns(reload: () => void): RegistryColumn<WarehouseSrvRow>[] { return [
  {
    key: 'pressure', header: 'Set pressure', align: 'center', numeric: true, sort: 'pressure',
    render: (r) => (
      <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
    ),
  },
  {
    key: 'availability', header: 'Availability', sort: 'availability',
    // The + to send a valve to the calibration company sits beside its "UNDER CALIBRATION" chip, so it is
    // reachable straight from the table on every screen size.
    render: (r) => (
      <span className="inline-flex items-center gap-1.5">
        <AvailabilityChip status={r.availability_status} label={r.availability_status ? AVAILABILITY_LABEL[r.availability_status] ?? null : null} />
        <SendToCalibration row={r} onSent={reload} />
        <IssueFromTable row={r} onIssued={reload} />
      </span>
    ),
  },
  { key: 'manufacturer', header: 'Manufacturer', sort: 'manufacturer', render: (r) => <ManufacturerChip value={r.manufacturer} /> },
  { key: 'size', header: 'Size', sort: 'size', render: (r) => <ValveSize type={r.size_type} inlet={r.inlet_size} outlet={r.outlet_size} /> },
  {
    key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
    render: (r) => <Serial value={r.serial_number} status={r.serial_status} />,
  },
  {
    key: 'warehouse_code', header: 'Warehouse code', sort: 'warehouse_code',
    render: (r) => (r.warehouse_code ? <Identifier value={r.warehouse_code} /> : <NullValue />),
  },
  {
    key: 'last_calibration', header: 'Last calibration', sort: 'last_calibration',
    render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />,
  },
  {
    key: 'days_left', header: 'Days left', align: 'center', numeric: true, sort: 'next_due',
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
  {
    // A DESTINATION, labelled as one. Never a hierarchy position.
    key: 'target', header: 'Destination', sort: 'target',
    render: (r) =>
      r.is_unassigned_stock ? (
        <span className="whitespace-nowrap text-muted-foreground">Unassigned stock</span>
      ) : (
        <span className="whitespace-nowrap">
          {r.target_unit_name ?? r.target_station_name ?? <SourceContext value={r.target_station_raw} note="as in sheet — not linked" />}
          {r.target_region_name ? (
            <span className="ml-1.5 text-xs"><RegionChip name={r.target_region_name} /></span>
          ) : null}
        </span>
      ),
  },
]}

function ValveSize({ type, inlet, outlet }: { type: string | null; inlet: string | null; outlet: string | null }) {
  const prefix = type?.toLowerCase() === 'male' ? 'M' : type?.toLowerCase() === 'female' ? 'F' : type
  const value = [prefix, inlet].filter(Boolean).join(' ') + (outlet ? ` X ${outlet}` : '')
  return value.trim() ? <span className="whitespace-nowrap font-technical">{value}</span> : <NullValue />
}

export function WarehouseSrvSection() {
  const link = useSrvDeepLink()
  const [query, setQuery] = useState<WarehouseQuery>(() => ({ ...DEFAULT_WAREHOUSE_QUERY, search: link.q }))
  const { state, reload } = useWarehouseSrvs(query)
  const supabase = useSupabaseClient()
  const isAdmin = useIsAdmin()
  // Ticks belong to the rows on screen: any change of filter, sort or page clears them, so a bulk
  // action can never reach a valve the user can no longer see.
  const [selected, setSelected] = useState<Set<string>>(new Set())

  const update = useCallback((patch: Partial<WarehouseQuery>) => {
    setSelected(new Set())
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setSelected(new Set())
    setQuery((prev) => ({
      ...prev,
      sort: key as WarehouseSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => { setSelected(new Set()); setQuery(DEFAULT_WAREHOUSE_QUERY) }, [])
  const reloadClear = useCallback(() => { setSelected(new Set()); reload() }, [reload])
  const hasFilters = Boolean(query.search.trim()) || query.availability !== null || query.due !== 'all' || hasSmartFilters(query.filters)

  const rows = state.status === 'ready' ? state.data.rows : []
  const summary = useWarehouseSummary(query, state)
  // Owner request 2026-10-02: the tiles are quick filters. One bucket at a time; pressing the active one clears it.
  const pick = (availability: string | null, due: WarehouseQuery['due']) => {
    const same = query.availability === availability && query.due === due
    update(same ? { availability: null, due: 'all' } : { availability, due })
  }
  const isPicked = (availability: string | null, due: WarehouseQuery['due']) => query.availability === availability && query.due === due
  const picked = rows.filter((r) => selected.has(r.id))

  return (
    <div className="flex min-w-0 flex-col gap-3">
      {summary.status === 'error' ? (
        <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
          The stock summary could not be loaded, so no counts are shown. The table below is unaffected.
        </p>
      ) : null}
      {summary.status === 'ready' ? (
        <section aria-labelledby="wh-summary" className="rounded border bg-card px-3 py-2">
          <h2 id="wh-summary" className="sr-only">
            Warehouse stock summary
          </h2>
          {/* Whole-stock counts (not this page). Each tile filters the table to exactly what it counts. */}
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-5">
            <Metric label="In store" value={summary.data.total.toLocaleString()} hint="visible to you"
              onSelect={() => pick(null, 'all')} active={isPicked(null, 'all')} />
            <Metric label={AVAILABILITY_LABEL.available_calibrated} value={summary.data.calibrated.toLocaleString()}
              onSelect={() => pick('available_calibrated', 'all')} active={isPicked('available_calibrated', 'all')} />
            <Metric label={AVAILABILITY_LABEL.available_in_store_uc} value={summary.data.under_calibration.toLocaleString()}
              onSelect={() => pick('available_in_store_uc', 'all')} active={isPicked('available_in_store_uc', 'all')} />
            <Metric label={AVAILABILITY_LABEL.available_new} value={summary.data.new.toLocaleString()}
              onSelect={() => pick('available_new', 'all')} active={isPicked('available_new', 'all')} />
            <Metric label="Overdue calibration" value={summary.data.overdue.toLocaleString()} tone="overdue"
              onSelect={() => pick(null, 'overdue')} active={isPicked(null, 'overdue')} />
          </div>
        </section>
      ) : null}

      <DataToolbar label="Search and filter warehouse relief valves" filtersActive={hasFilters}>
        <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="sr-only">Search warehouse relief valves</span>
          <input
            id="warehouse-srv-search" name="warehouse-srv-search" type="search"
            value={query.search}
            onChange={(e) => update({ search: e.target.value })}
            placeholder="Serial, code, part number, destination…"
            dir="auto"
            className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
          />
        </label>

        {/* No Region filter: warehouse stock has no Region. */}
        <MultiSelectFilter id="warehouse-srv-availability" label="Availability" value={query.availability}
                           onChange={(v) => update({ availability: v || null })}
                           options={STOCK_STATUSES.map((value) => ({ value, label: AVAILABILITY_LABEL[value] }))} />

        <MultiSelectFilter id="warehouse-srv-due" label="Due" value={query.due} empty="all" aliases={DUE_ALIASES}
                           onChange={(due) => update({ due })} options={DUE_OPTIONS} />

        <SmartFilterBar id="warehouse-srv" regionLabel="Destination Region" value={query.filters} onChange={(filters) => update({ filters })} date={WAREHOUSE_DATE} />
        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
        <span className="ml-auto flex flex-wrap items-center gap-2">
          <ExportButtons name="warehouse-srvs" load={queryLoader(supabase, 'Warehouse SRVs', WAREHOUSE_SRV_COLUMNS, (c) => warehouseRequest(c, query))}
            excel={async (sheets) => ({ blob: await buildWarehouseWorkbook(sheets[0].rows as WarehouseSrvRow[]), fileName: warehouseWorkbookName() })} />
          <AddWarehouseSrvsButton onAdded={reload} />
        </span>
      </DataToolbar>
      {isAdmin && picked.length > 0 ? (
        <WarehouseBulkActions picked={picked} onClear={() => setSelected(new Set())} onDone={reloadClear} />
      ) : null}

      <RegistryTable
        openKey={link.open}

        record={(r) => ({ table: 'warehouse_relief_valves', id: r.id })}
        label="Warehouse relief valves"
        state={state}
        reload={reload}
        columns={columns(reloadClear)}
        selection={isAdmin ? { selected, onChange: setSelected } : undefined}
        extra={(r, done) => (
          <>
            <IssuePanel row={r} onDone={done} />
            <WarehouseDestinationEditor row={r} onDone={done} />
            <ValveHistory valveId={r.id} />
            <RemoveValveButton table="warehouse_relief_valves" id={r.id} onDone={done} />
          </>
        )}
        rowKey={(r) => r.id}
        sort={query.sort}
        direction={query.direction}
        onSort={onSort}
        page={query.page}
        pageSize={query.pageSize}
        onPage={(p) => { setSelected(new Set()); setQuery((prev) => ({ ...prev, page: p })) }}
        onClearFilters={clearFilters}
        emptyTitle="No relief valves in the store"
        emptyDescription="Valves in the store (new, calibrated or under calibration) appear here. Issued valves are in Installed SRVs and the SRV Log."
        errorTitle="Could not load warehouse relief valves"
        detail={(r) => (
          <>
            <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
            <Fact label="Part number">{r.part_number ? <Identifier value={r.part_number} /> : <NullValue />}</Fact>
            <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
            <Fact label="Size type"><Text value={r.size_type} /></Fact>
            <Fact label="Inlet size">{r.inlet_size ? <Identifier value={r.inlet_size} /> : <NullValue />}</Fact>
            <Fact label="Outlet size">{r.outlet_size ? <Identifier value={r.outlet_size} /> : <NullValue />}</Fact>
            <Fact label="Set pressure">
              <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
            </Fact>
            <Fact label="Availability">
              {r.availability_status ? AVAILABILITY_LABEL[r.availability_status] ?? r.availability_status : <NullValue />}
            </Fact>
            <Fact label="Warehouse code">{r.warehouse_code ? <Identifier value={r.warehouse_code} /> : <NullValue />}</Fact>
            <Fact label="Destination Station">
              {r.is_unassigned_stock ? (
                <span className="text-muted-foreground">Unassigned stock</span>
              ) : r.target_station_name ? (
                <Text value={r.target_station_name} />
              ) : (
                <SourceContext value={r.target_station_raw} note="as in sheet — not linked to a Station" />
              )}
            </Fact>
            <Fact label="Destination Unit"><Text value={r.target_unit_name} /></Fact>
            <Fact label="Destination Region"><RegionChip name={r.target_region_name} /></Fact>
            <Fact label="Issued from warehouse">
              {r.warehouse_issue_date ? <span className="tabular">{r.warehouse_issue_date}</span> : <NullValue />}
            </Fact>
            <Fact label="Calibration location"><Text value={r.calibration_location} /></Fact>
            <Fact label="Last calibration">
              <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />
            </Fact>
            <Fact label="Next calibration">
              <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
            </Fact>
            <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
            <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
            <Fact label="Notes"><Text value={r.notes} /></Fact>
          </>
        )}
      />
    </div>
  )
}
