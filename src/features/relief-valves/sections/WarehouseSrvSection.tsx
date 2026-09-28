import { AvailabilityChip, ManufacturerChip, RegionChip } from '@/features/relief-valves/SrvPieces'
import { useCallback, useState } from 'react'
import { Plus, Search, X } from 'lucide-react'

import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { DueBadge, PrecisionDate, PressureRange, Serial, Text } from '@/features/units/assetDisplay'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { SmartFilterBar } from '@/features/relief-valves/SrvPieces'
import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import {
  hasSmartFilters,
  DEFAULT_WAREHOUSE_QUERY, useWarehouseSrvs,
  type WarehouseQuery, type WarehouseSrvRow, type WarehouseSort,
} from '@/features/relief-valves/useSrvManagement'
import { RemoveValveButton } from '@/features/relief-valves/SrvAdminActions'
import { IssuePanel, ValveHistory } from '@/features/relief-valves/SrvWorkflowPieces'
import { useIsAdmin, useWorkflowAction } from '@/features/relief-valves/useSrvWorkflow'

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

const AVAILABILITY_LABEL: Record<string, string> = {
  available_new: 'Available — new',
  available_calibrated: 'Available — calibrated',
  available_in_store_uc: 'Available — in store (UC)',
  sent_to_station_received: 'Sent to station — received',
  sent_to_station_not_received: 'Sent to station — not received',
}

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
        className="flex h-5 w-5 items-center justify-center rounded border text-muted-foreground hover:bg-muted hover:text-foreground"
      >
        <Plus className="h-3.5 w-3.5" aria-hidden="true" />
        <span className="sr-only">Send serial {row.serial_number ?? ''} to Calibration (3rd party)</span>
      </button>
      {error ? <span role="alert" className="text-xs text-destructive">{error}</span> : null}
    </span>
  )
}

function columns(reload: () => void): RegistryColumn<WarehouseSrvRow>[] { return [
  {
    key: 'pressure', header: 'Set pressure', align: 'right', sort: 'pressure',
    render: (r) => (
      <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
    ),
  },
  {
    key: 'availability', header: 'Availability', sort: 'availability',
    render: (r) => <AvailabilityChip status={r.availability_status} label={r.availability_status ? AVAILABILITY_LABEL[r.availability_status] ?? null : null} />,
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
    key: 'days_left', header: 'Days left', align: 'right', numeric: true, sort: 'next_due',
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
  {
    key: 'calibrate', header: 'Calibrate',
    render: (r) => <SendToCalibration row={r} onSent={reload} />,
  },
  {
    // A DESTINATION, labelled as one. Never a hierarchy position.
    key: 'target', header: 'Destination', sort: 'target',
    render: (r) =>
      r.is_unassigned_stock ? (
        <span className="whitespace-nowrap text-muted-foreground">Unassigned stock</span>
      ) : (
        <span className="whitespace-nowrap">
          {r.target_station_name ?? <NullValue />}
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
  const [query, setQuery] = useState<WarehouseQuery>(DEFAULT_WAREHOUSE_QUERY)
  const { state, reload } = useWarehouseSrvs(query)

  const update = useCallback((patch: Partial<WarehouseQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as WarehouseSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => setQuery(DEFAULT_WAREHOUSE_QUERY), [])
  const hasFilters = Boolean(query.search.trim()) || query.availability !== null || query.due !== 'all' || hasSmartFilters(query.filters)

  const rows = state.status === 'ready' ? state.data.rows : []
  const total = state.status === 'ready' ? state.data.total : null
  const missingSerial = rows.filter((r) => !r.serial_number).length
  const overdue = rows.filter((r) => r.due_status === 'overdue').length

  return (
    <div className="flex min-w-0 flex-col gap-3">
      {state.status === 'ready' ? (
        <section aria-labelledby="wh-summary" className="rounded border bg-card px-3 py-2">
          <h2 id="wh-summary" className="sr-only">
            Warehouse inventory summary
          </h2>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3">
            <Metric label="Matching" value={(total ?? 0).toLocaleString()} hint="visible to you" />
            <Metric label="Overdue calibration" value={overdue} tone="overdue" hint="this page" />
            {/* A real data-quality fact, not an invented stock concept. The
              * schema models no quantity, so no stock level is reported. */}
            <Metric label="No serial recorded" value={missingSerial} hint="this page" />
          </div>
        </section>
      ) : null}

      <DataToolbar label="Search and filter warehouse relief valves">
        <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="sr-only">Search warehouse relief valves</span>
          <input
            id="warehouse-srv-search" name="warehouse-srv-search" type="search"
            value={query.search}
            onChange={(e) => update({ search: e.target.value })}
            placeholder="Serial, part number, warehouse…"
            dir="auto"
            className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
          />
        </label>

        {/* No Region filter: warehouse stock has no Region. */}
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Availability</span>
          <select
            id="warehouse-srv-availability" name="warehouse-srv-availability" value={query.availability ?? ''}
            onChange={(e) => update({ availability: e.target.value || null })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="">All</option>
            {Object.entries(AVAILABILITY_LABEL).filter(([value]) => STOCK_STATUSES.includes(value)).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Due</span>
          <select
            id="warehouse-srv-due" name="warehouse-srv-due" value={query.due}
            onChange={(e) => update({ due: e.target.value as WarehouseQuery['due'] })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All</option>
            <option value="overdue">Overdue</option>
            <option value="attention">Due ≤60d (incl. overdue)</option>
            <option value="unknown">No exact date</option>
          </select>
        </label>

        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
      </DataToolbar>
      <SmartFilterBar id="warehouse-srv" stationLabel="Destination Station" regionLabel="Destination Region" value={query.filters} onChange={(filters) => update({ filters })} />

      <RegistryTable

        record={(r) => ({ table: 'warehouse_relief_valves', id: r.id })}
        label="Warehouse relief valves"
        state={state}
        reload={reload}
        columns={columns(reload)}
        extra={(r, done) => (
          <>
            <IssuePanel row={r} onDone={done} />
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
        onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
        onClearFilters={clearFilters}
        emptyTitle="No relief valves in the store"
        emptyDescription="Valves in the store (new, calibrated or under calibration) appear here. Issued valves are in Installed SRVs and the SRV Log."
        errorTitle="Could not load warehouse relief valves"
        detail={(r) => (
          <>
            <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
            <Fact label="Serial (source)">
              {r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}
            </Fact>
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
              ) : (
                <Text value={r.target_station_name} />
              )}
            </Fact>
            <Fact label="Destination Region"><Text value={r.target_region_name} /></Fact>
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
            <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
            <Fact label="Notes"><Text value={r.notes} /></Fact>
          </>
        )}
        footnote="Warehouse stock has no Station, Unit or equipment parent. A destination records where a valve is being sent, not where it is fitted."
      />
    </div>
  )
}
