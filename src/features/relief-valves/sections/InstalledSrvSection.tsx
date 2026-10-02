import { useCallback, useState } from 'react'
import { ReplaceValvePanel } from '@/features/relief-valves/ReplaceValvePanel'
import { ExportButtons } from '@/features/export/ExportButtons'
import { queryLoader } from '@/features/export/exportData'
import { INSTALLED_SRV_COLUMNS } from '@/features/export/exportColumns'
import { useSupabaseClient } from '@/lib/supabase/client'
import { Search, X } from 'lucide-react'

import { Identifier } from '@/components/data/TechnicalText'
import { RemoveValveButton } from '@/features/relief-valves/SrvAdminActions'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { useRegions } from '@/features/hierarchy/useHierarchy'
import { DueBadge, PrecisionDate, PressureRange, Serial, Text } from '@/features/units/assetDisplay'
import { ValveHistory } from '@/features/relief-valves/SrvWorkflowPieces'
import { ManufacturerChip, RegionChip, SmartFilterBar, Metric, ParentCell } from '@/features/relief-valves/SrvPieces'
import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DUE_ALIASES, DUE_OPTIONS } from '@/components/data/multiFilter'
import {
  INSTALLED_DATE,
  hasSmartFilters,
  DEFAULT_INSTALLED_QUERY, useInstalledSrvs, useInstalledSummary,
  type InstalledQuery, type InstalledSrvRow, type InstalledSort,
  installedRequest,
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

const PARENT_OPTIONS = [
  { value: 'compressor', label: 'Compressor' },
  { value: 'storage_vessel', label: 'Storage Vessel' },
  { value: 'dispenser', label: 'Dispenser' },
]

const COLUMNS: RegistryColumn<InstalledSrvRow>[] = [
  {
    key: 'region', header: 'Region', sort: 'region',
    render: (r) => (r.mapping_status === 'needs_station_mapping'
      ? <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
      : <RegionChip name={r.region_name} />),
  },
  {
    // Owner layout 2026-09-28: no Station column — the Unit names the site. A valve whose Unit is not yet
    // confirmed shows its Station, labelled so, rather than an empty cell.
    key: 'unit', header: 'Unit', sort: 'unit',
    render: (r) =>
      r.unit_name ? (
        <span dir="auto" className="whitespace-nowrap">{r.unit_name}</span>
      ) : r.station_name ? (
        <span className="whitespace-nowrap">
          <span dir="auto">{r.station_name}</span>
          <span className="cell-note ml-1.5 text-xs text-muted-foreground">station level</span>
        </span>
      ) : (
        <span className="whitespace-nowrap text-muted-foreground">Not confirmed</span>
      ),
  },
  {
    key: 'pressure', header: 'Set pressure', align: 'right', sort: 'pressure',
    render: (r) => (
      <PressureRange min={r.pressure_min} max={r.pressure_max} unit={r.pressure_unit} raw={r.set_pressure_raw} />
    ),
  },
  { key: 'manufacturer', header: 'Manufacturer', sort: 'manufacturer', render: (r) => <ManufacturerChip value={r.manufacturer} /> },
  {
    key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
    render: (r) => <Serial value={r.serial_number} status={r.serial_status} />,
  },
  { key: 'size', header: 'Size', sort: 'size', render: (r) => <ValveSize type={r.size_type} inlet={r.inlet_size} outlet={r.outlet_size} /> },
  {
    key: 'last_calibration', header: 'Last calibration', sort: 'last_calibration',
    render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />,
  },
  {
    key: 'days_left', header: 'Days left', align: 'right', numeric: true, sort: 'next_due',
    render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
  },
  { key: 'due', header: 'Status', sort: 'due', render: (r) => <DueBadge status={r.due_status} /> },
]

/** Details panel only. A recorded code, or the code of the single warehouse record with the same serial, labelled as such. */
function WarehouseCode({ row }: { row: InstalledSrvRow }) {
  if (!row.warehouse_code) return <NullValue />
  // Owner rule: an installed valve carries the code it LEFT the warehouse with — new (mb 9) or calibrated (mbc 9).
  // An under-calibration code (mbu 9) cannot belong to a valve on a station, so a serial match to one is not shown.
  if (/^[a-z]{2}u\s*\d/i.test(row.warehouse_code.trim())) {
    return <span className="text-xs text-muted-foreground">Not shown — the serial matches a warehouse record under calibration ({row.warehouse_code})</span>
  }
  return (
    <span className="inline-flex items-center gap-1 whitespace-nowrap">
      <Identifier value={row.warehouse_code} />
      {row.warehouse_code_source === 'serial_match' ? (
        <span className="cell-note text-[0.7rem] text-muted-foreground" title="Found by matching the serial to exactly one warehouse record">by serial</span>
      ) : null}
    </span>
  )
}

function ValveSize({ type, inlet, outlet }: { type: string | null; inlet: string | null; outlet: string | null }) {
  const t = type?.toLowerCase()
  const prefix = t === 'male' ? 'M' : t === 'female' ? 'F' : t === 'flange' ? 'Flange' : type
  const value = [prefix, inlet].filter(Boolean).join(' ') + (outlet ? ` X ${outlet}` : '')
  return value.trim() ? <span className="whitespace-nowrap font-technical">{value}</span> : <NullValue />
}

export function InstalledSrvSection() {
  const [query, setQuery] = useState<InstalledQuery>(DEFAULT_INSTALLED_QUERY)
  const supabase = useSupabaseClient()
  const { state, reload } = useInstalledSrvs(query)
  // The tiles ARE the due / conflict buckets, so their counts ignore the bucket a tile selects (otherwise
  // pressing "Overdue" would turn every other tile into the overdue count). Every other filter still applies.
  const { state: summary } = useInstalledSummary({ ...query, due: 'all', mapping: 'all' })
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
  // Owner request 2026-10-02: the tiles are quick filters. One bucket at a time; pressing the active one clears it.
  const pick = useCallback((due: InstalledQuery['due'], mapping: InstalledQuery['mapping']) => {
    setQuery((prev) => {
      const same = prev.due === due && prev.mapping === mapping
      return { ...prev, due: same ? 'all' : due, mapping: same ? 'all' : mapping, page: 0 }
    })
  }, [])
  const isPicked = (due: InstalledQuery['due'], mapping: InstalledQuery['mapping']) => query.due === due && query.mapping === mapping
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.mapping !== 'all' ||
    query.due !== 'all' || query.parentKind !== 'all' || hasSmartFilters(query.filters)


  return (
    <div className="flex min-w-0 flex-col gap-3">
      {/* Compact operational strip, not a dashboard. It follows the active
        * filters (owner request 2026-09-28) - and a failed count is stated,
        * never rendered as 0. */}
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
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4">
            <Metric label="Installed" value={summary.data.total.toLocaleString()} hint={hasFilters ? 'matching the filters' : 'visible to you'}
              onSelect={() => pick('all', 'all')} active={isPicked('all', 'all')} />
            <Metric label="Overdue" value={summary.data.overdue.toLocaleString()} tone="overdue"
              onSelect={() => pick('overdue', 'all')} active={isPicked('overdue', 'all')} />
            {/* Stated explicitly: this bucket INCLUDES overdue. Owner request 2026-10-01: 30 days, not 60;
              * the three "Needs" mapping tiles are removed (every installed valve is mapped). */}
            <Metric
              label="Due ≤30d"
              value={summary.data.attention.toLocaleString()}
              tone="due"
              hint="includes overdue"
              onSelect={() => pick('attention', 'all')} active={isPicked('attention', 'all')}
            />
            {/* Conflict is its own metric: evidence that disagrees is a
              * different problem from evidence that is missing. */}
            <Metric label="Conflict" value={summary.data.conflict.toLocaleString()}
              onSelect={() => pick('all', 'conflict')} active={isPicked('all', 'conflict')} />
          </div>
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

        <MultiSelectFilter id="installed-srv-region" label="Region" value={query.regionId} onChange={(v) => update({ regionId: v || null })}
                           options={regions.state.status === 'ready' ? regions.state.data.map((r) => ({ value: r.region_id, label: r.region_name })) : []} />

        {/* Owner request 2026-10-02: no Mapping filter (every valve is mapped); the Conflict tile still filters. */}
        <MultiSelectFilter id="installed-srv-due" label="Due" value={query.due} empty="all" aliases={DUE_ALIASES}
                           onChange={(due) => update({ due })} options={DUE_OPTIONS} />

        <MultiSelectFilter id="installed-srv-parent" label="Parent" value={query.parentKind} empty="all" allLabel="Any"
                           onChange={(parentKind) => update({ parentKind })} options={PARENT_OPTIONS} />

        <SmartFilterBar id="installed-srv" showRegion={false} value={query.filters} onChange={(filters) => update({ filters })} date={INSTALLED_DATE} />
        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
        <span className="ml-auto">
          <ExportButtons name="installed-srvs" load={queryLoader(supabase, 'Installed SRVs', INSTALLED_SRV_COLUMNS, (c) => installedRequest(c, query))} />
        </span>
      </DataToolbar>

      <RegistryTable

        record={(r) => ({ table: 'installed_relief_valves', id: r.id })}
        extra={(r, done) => (
          <>
            <ReplaceValvePanel valve={r} onDone={done} />
            <ValveHistory valveId={r.id} />
            <RemoveValveButton table="installed_relief_valves" id={r.id} onDone={done} />
          </>
        )}
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
            <Fact label="Region">
              {r.mapping_status === 'needs_station_mapping' ? (
                <span className="text-muted-foreground">Not confirmed</span>
              ) : (
                <RegionChip name={r.region_name} />
              )}
            </Fact>
            <Fact label="Station">
              {r.mapping_status === 'needs_station_mapping' ? (
                <span className="text-muted-foreground">Not confirmed</span>
              ) : (
                <Text value={r.station_name} />
              )}
            </Fact>
            <Fact label="Unit"><Text value={r.unit_name} /></Fact>
            <Fact label="Equipment parent"><ParentCell row={r} /></Fact>
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
        footnote="Mapping is not changed from this screen. Resolving a record is an explicit, audited decision and is deferred — see docs/srv-management.md."
      />
    </div>
  )
}
