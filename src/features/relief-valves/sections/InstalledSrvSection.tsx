import { useCallback, useState } from 'react'
import { Search, X } from 'lucide-react'

import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { useRegions } from '@/features/hierarchy/useHierarchy'
import { DueBadge, PrecisionDate, PressureRange, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import { SmartFilterBar, HierarchyCell, MappingBadge, Metric, ParentCell, SourceContext } from '@/features/relief-valves/SrvPieces'
import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import {
  hasSmartFilters,
  DEFAULT_INSTALLED_QUERY, useInstalledSrvs, useInstalledSummary,
  type InstalledQuery, type InstalledSrvRow, type InstalledSort,
} from '@/features/relief-valves/useSrvManagement'

/**
 * Installed SRVs, company-wide.
 *
 * Unlike the Unit SRV tab, this view may show EVERY mapping state the caller is
 * authorized to read — including records whose Station is not yet confirmed.
 * That widening is safe because it is the DATABASE that decides: the RLS policy
 * on `installed_relief_valves` routes station-mapped rows through
 * `cng_can_read_region()` and unmapped rows through
 * `cng_can_access_unmapped_srv()`, which is admin/manager only. An unconfirmed
 * station name is evidence, never permission (CLAUDE.md §10).
 *
 * The Unit tab's narrower rule is untouched: it reads `v_unit_srvs`, a
 * different view with its own predicate.
 *
 * NOTHING HERE MAPS ANYTHING. Search is retrieval; a filter narrows rows. No
 * record is advanced through the lifecycle, and no parent is inferred. Mapping
 * mutation is deferred — see docs/srv-management.md.
 */

const COLUMNS: RegistryColumn<InstalledSrvRow>[] = [
  {
    key: 'pressure', header: 'Set pressure', align: 'right',
    render: (r) => (
      <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
    ),
  },
  { key: 'due', header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
  { key: 'manufacturer', header: 'Manufacturer', render: (r) => <Text value={r.manufacturer} /> },
  { key: 'size', header: 'Size', render: (r) => <ValveSize type={r.size_type} inlet={r.inlet_size} outlet={r.outlet_size} /> },
  {
    key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
    render: (r) => <Serial value={r.serial_number} status={r.serial_status} />,
  },
  {
    // Its own column, never folded into Serial. SS-4R3A is owner-confirmed as
    // a Part Number, so it lands here and the serial stays absent.
    key: 'part_number', header: 'Part number',
    render: (r) => (r.part_number ? <Identifier value={r.part_number} /> : <NullValue />),
  },
  {
    key: 'last_calibration', header: 'Last calibration',
    render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />,
  },
  { key: 'warehouse', header: 'Warehouse code', render: (r) => <WarehouseCode row={r} /> },
  { key: 'station', header: 'Station', sort: 'station', render: (r) => <HierarchyCell row={r} /> },
  {
    key: 'unit', header: 'Unit', sort: 'unit',
    render: (r) =>
      r.unit_name ? (
        <span className="whitespace-nowrap">{r.unit_name}</span>
      ) : (
        <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
      ),
  },
  { key: 'parent', header: 'Equipment parent', render: (r) => <ParentCell row={r} /> },
  { key: 'mapping', header: 'Mapping', sort: 'mapping', render: (r) => <MappingBadge status={r.mapping_status} /> },
  {
    key: 'next_due', header: 'Next calibration', sort: 'next_due',
    render: (r) => (
      <>
        <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
        {!r.next_calibration_display ? <SourceStatus value={r.source_status_raw} /> : null}
      </>
    ),
  },
  {
    key: 'days_left', header: 'Days left', align: 'right', numeric: true,
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
]

/** A recorded code, or the code of the single warehouse record with the same serial, labelled as such. */
function WarehouseCode({ row }: { row: InstalledSrvRow }) {
  if (!row.warehouse_code) return <NullValue />
  return (
    <span className="inline-flex items-center gap-1 whitespace-nowrap">
      <Identifier value={row.warehouse_code} />
      {row.warehouse_code_source === 'serial_match' ? (
        <span className="text-[0.7rem] text-muted-foreground" title="Found by matching the serial to exactly one warehouse record">by serial</span>
      ) : null}
    </span>
  )
}

function ValveSize({ type, inlet, outlet }: { type: string | null; inlet: string | null; outlet: string | null }) {
  const prefix = type?.toLowerCase() === 'male' ? 'M' : type?.toLowerCase() === 'female' ? 'F' : type
  const value = [prefix, inlet].filter(Boolean).join(' ') + (outlet ? ` X ${outlet}` : '')
  return value.trim() ? <span className="whitespace-nowrap font-technical">{value}</span> : <NullValue />
}

export function InstalledSrvSection() {
  const [query, setQuery] = useState<InstalledQuery>(DEFAULT_INSTALLED_QUERY)
  const { state, reload } = useInstalledSrvs(query)
  const { state: summary } = useInstalledSummary()
  const regions = useRegions()

  // Any change to the result set returns to page 1; staying on page 5 of a
  // newly-filtered list shows an empty table that reads like "no results".
  const update = useCallback((patch: Partial<InstalledQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as InstalledSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => setQuery(DEFAULT_INSTALLED_QUERY), [])
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.mapping !== 'all' ||
    query.due !== 'all' || query.parentKind !== 'all' || hasSmartFilters(query.filters)

  const total = state.status === 'ready' ? state.data.total : null

  return (
    <div className="flex min-w-0 flex-col gap-3">
      {/* Compact operational strip, not a dashboard. Counted over the whole
        * authorized dataset, so it does not change as filters narrow the
        * table - and a failed count is stated, never rendered as 0. */}
      {summary.status === 'error' ? (
        <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
          The attention summary could not be loaded, so no counts are shown. The table below is unaffected.
        </p>
      ) : null}
      {summary.status === 'ready' ? (
        <section aria-labelledby="srv-attention" className="rounded border bg-card px-3 py-2">
          <h2 id="srv-attention" className="sr-only">
            Attention and mapping summary
          </h2>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4 lg:grid-cols-7">
            <Metric label="Installed" value={summary.data.total.toLocaleString()} hint="visible to you" />
            <Metric label="Overdue" value={summary.data.overdue.toLocaleString()} tone="overdue" />
            {/* Stated explicitly: this bucket INCLUDES overdue. */}
            <Metric
              label="Due ≤60d"
              value={summary.data.attention.toLocaleString()}
              tone="due"
              hint="includes overdue"
            />
            <Metric
              label="Needs station"
              value={summary.data.needs_station_mapping.toLocaleString()}
              tone="unmapped"
            />
            <Metric label="Needs unit" value={summary.data.needs_unit_mapping.toLocaleString()} tone="unmapped" />
            <Metric
              label="Needs equipment"
              value={summary.data.needs_equipment_mapping.toLocaleString()}
              tone="unmapped"
            />
            {/* Conflict is its own metric: evidence that disagrees is a
              * different problem from evidence that is missing. */}
            <Metric label="Conflict" value={summary.data.conflict.toLocaleString()} />
          </div>
          {total !== null && total !== summary.data.total ? (
            <p className="mt-1.5 text-xs text-muted-foreground">
              Counts cover all installed valves visible to you. The table below shows{' '}
              <span className="tabular">{total.toLocaleString()}</span> matching the current filters.
            </p>
          ) : null}
        </section>
      ) : null}

      <DataToolbar label="Search and filter installed relief valves">
        <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="sr-only">Search installed relief valves</span>
          <input
            id="installed-srv-search" name="installed-srv-search" type="search"
            value={query.search}
            onChange={(e) => update({ search: e.target.value })}
            placeholder="Serial, part number, station…"
            dir="auto"
            className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
          />
        </label>

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Region</span>
          <select
            id="installed-srv-region" name="installed-srv-region" value={query.regionId ?? ''}
            onChange={(e) => update({ regionId: e.target.value || null })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="">All Regions</option>
            {regions.state.status === 'ready'
              ? regions.state.data.map((r) => (
                  <option key={r.region_id} value={r.region_id}>
                    {r.region_name}
                  </option>
                ))
              : null}
          </select>
        </label>

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Mapping</span>
          <select
            id="installed-srv-mapping" name="installed-srv-mapping" value={query.mapping}
            onChange={(e) => update({ mapping: e.target.value as InstalledQuery['mapping'] })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All states</option>
            <option value="resolved">Resolved</option>
            <option value="needs_equipment_mapping">Needs equipment mapping</option>
            <option value="needs_unit_mapping">Needs unit mapping</option>
            <option value="needs_station_mapping">Needs station mapping</option>
            <option value="conflict">Conflict</option>
          </select>
        </label>

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Due</span>
          <select
            id="installed-srv-due" name="installed-srv-due" value={query.due}
            onChange={(e) => update({ due: e.target.value as InstalledQuery['due'] })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">All</option>
            <option value="overdue">Overdue</option>
            <option value="attention">Due ≤60d (incl. overdue)</option>
            <option value="unknown">No exact date</option>
          </select>
        </label>

        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <span>Parent</span>
          <select
            id="installed-srv-parent" name="installed-srv-parent" value={query.parentKind}
            onChange={(e) => update({ parentKind: e.target.value as InstalledQuery['parentKind'] })}
            className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
          >
            <option value="all">Any</option>
            <option value="compressor">Compressor</option>
            <option value="storage_vessel">Storage Vessel</option>
            <option value="dispenser">Dispenser</option>
          </select>
        </label>

        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
      </DataToolbar>
      <SmartFilterBar id="installed-srv" stationLabel="Station" value={query.filters} onChange={(filters) => update({ filters })} />

      <RegistryTable

        record={(r) => ({ table: 'installed_relief_valves', id: r.id })}
        label="Installed relief valves"
        state={state}
        reload={reload}
        columns={COLUMNS}
        rowKey={(r) => r.id}
        sort={query.sort}
        direction={query.direction}
        onSort={onSort}
        page={query.page}
        pageSize={query.pageSize}
        onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
        onClearFilters={clearFilters}
        emptyTitle="No installed relief valves recorded yet"
        emptyDescription="Installed valves appear here once the source workbooks have been imported. Nothing has been imported yet."
        errorTitle="Could not load installed relief valves"
        detail={(r) => (
          <>
            <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
            <Fact label="Serial (source)">
              {r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}
            </Fact>
            <Fact label="Part number">{r.part_number ? <Identifier value={r.part_number} /> : <NullValue />}</Fact>
            <Fact label="Warehouse code"><WarehouseCode row={r} /></Fact>
            <Fact label="Tag number">{r.tag_number ? <Identifier value={r.tag_number} /> : <NullValue />}</Fact>
            <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
            <Fact label="Size type"><Text value={r.size_type} /></Fact>
            <Fact label="Inlet size">{r.inlet_size ? <Identifier value={r.inlet_size} /> : <NullValue />}</Fact>
            <Fact label="Outlet size">{r.outlet_size ? <Identifier value={r.outlet_size} /> : <NullValue />}</Fact>
            <Fact label="Set pressure">
              <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
            </Fact>
            <Fact label="Mapping"><MappingBadge status={r.mapping_status} /></Fact>
            <Fact label="Region">
              {r.mapping_status === 'needs_station_mapping' ? (
                <span className="text-muted-foreground">Not confirmed</span>
              ) : (
                <Text value={r.region_name} />
              )}
            </Fact>
            <Fact label="Station">
              {r.mapping_status === 'needs_station_mapping' ? (
                <span className="text-muted-foreground">Not confirmed</span>
              ) : (
                <Text value={r.station_name} />
              )}
            </Fact>
            {/* The raw source station name is kept for traceability and shown
              * as SOURCE TEXT. It is never treated as a canonical station and
              * never as an authorization boundary. */}
            <Fact label="Station name (source text)">
              <SourceContext value={r.source_station_name_raw} note="unconfirmed source text" />
            </Fact>
            <Fact label="Unit"><Text value={r.unit_name} /></Fact>
            <Fact label="Equipment parent"><ParentCell row={r} /></Fact>
            <Fact label="Expected parent (source hint)">
              {r.expected_parent_kind ? (
                <span>
                  {r.expected_parent_kind === 'compressor' ? 'Compressor' : r.expected_parent_kind === 'storage_vessel' ? 'Storage Vessel' : 'Dispenser'}
                  <span className="ml-1 text-xs text-muted-foreground">which one is unknown</span>
                </span>
              ) : (
                <NullValue />
              )}
            </Fact>
            <Fact label="Location (source text)">
              <SourceContext value={r.location_raw} note="source context, not an identity" />
            </Fact>
            <Fact label="Last calibration">
              <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />
            </Fact>
            <Fact label="Next calibration">
              <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
            </Fact>
            <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
            <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
            <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
            <Fact label="Source file"><Text value={r.source_file} /></Fact>
            <Fact label="Source sheet"><Text value={r.source_sheet} /></Fact>
            <Fact label="Source row">{r.source_row === null ? <NullValue /> : r.source_row}</Fact>
            <Fact label="Notes"><Text value={r.notes} /></Fact>
          </>
        )}
        footnote="Mapping is not changed from this screen. Resolving a record is an explicit, audited decision and is deferred — see docs/srv-management.md."
      />
    </div>
  )
}
