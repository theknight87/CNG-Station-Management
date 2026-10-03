import { useCallback, useMemo, useState } from 'react'
import { ExportButtons } from '@/features/export/ExportButtons'
import { queryLoader } from '@/features/export/exportData'
import { GAS_DETECTOR_COLUMNS } from '@/features/export/exportColumns'
import { useSupabaseClient } from '@/lib/supabase/client'
import { MakerChip, RegionChip } from '@/components/data/AssetChips'
import { AssetFilterBar } from '@/components/data/AssetFilterBar'
import { hasAssetFilters } from '@/components/data/assetFilters'
import { useMakers } from '@/components/data/useMakers'
import { Search, X } from 'lucide-react'

import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { DEFAULT_STATION_QUERY, useRegions, useStations } from '@/features/hierarchy/useHierarchy'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { DueBadge, PrecisionDate, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import {
  AreaType, DetectorMappingBadge, DetectorStationCell, DetectorUnitCell, PresenceBadge,
} from '@/features/gas-detectors/GasDetectorPieces'
import {
  DETECTOR_DATE,
  DEFAULT_DETECTOR_QUERY, detectorRowKey, useGasDetectorSummary, useGasDetectors,
  type DetectorQuery, type DetectorRegistryRow, type DetectorSort,
  detectorRequest,
} from '@/features/gas-detectors/useGasDetectorManagement'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DUE_ALIASES, DUE_OPTIONS } from '@/components/data/multiFilter'

/**
 * Global Gas Detector Management — the company-wide calibration registry.
 *
 * A REGISTRY, NOT A MONITORING CONSOLE. There is no live reading, no gas
 * concentration, no alarm state, no connectivity indicator and no gauge,
 * because the schema stores none of those. What it stores is an inventory and a
 * calibration history, and that is what is drawn.
 *
 * The columns are exactly the fields `v_gas_detector_management` carries.
 * Deliberately ABSENT, because no column exists for them: detector location
 * (the schema has `area_type`, an area classification, and nothing positional),
 * calibration certificate number, calibration gas or concentration, detection
 * range, sensor type, installation date and firmware version. An empty column
 * would imply the value is merely missing rather than never recorded.
 */

/**
 * Column ORDER is a deliberate priority decision, not the schema's order.
 *
 * This is a calibration registry, so calibration attention leads: identity,
 * then hierarchy, then the area, then the next-due triple (date, countdown,
 * status). Manufacturer and Model are reference data an engineer looks up
 * rather than scans, so they sit after the attention columns.
 *
 * The measured reason: with Manufacturer and Model in third and fourth place,
 * `Days left` and `Status` fell outside the 1152px visible region at the
 * 1440px desktop target and could only be reached by scrolling the table
 * sideways — the two values the screen exists to surface were the two you
 * could not see.
 */
function columns(): RegistryColumn<DetectorRegistryRow>[] {
  return [
    { key: 'region', header: 'Region', sort: 'region', render: (r) => <RegionChip name={r.region_name} /> },
    {
      key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
      render: (r) => <Serial value={r.serial_number} status={r.serial_status} />,
    },
    { key: 'station', header: 'Station', sort: 'station', render: (r) => <DetectorStationCell row={r} /> },
    { key: 'unit', header: 'Unit', sort: 'unit', render: (r) => <DetectorUnitCell row={r} /> },
    {
      // A classification, rendered identically for both values. Never coloured
      // as though "Closed" were a warning.
      key: 'area', header: 'Area type', sort: 'area', render: (r) => <AreaType value={r.area_type} />,
    },
    {
      key: 'next_due', header: 'Next calibration', sort: 'next_due',
      render: (r) => (
        <>
          <PrecisionDate display={r.next_calibration_display} precision={r.next_calibration_precision} />
          {/* Source status such as "منتهي" sits BESIDE a missing date, never
            * becoming one (principle #21). */}
          {!r.next_calibration_display ? <SourceStatus value={r.source_status_raw} /> : null}
        </>
      ),
    },
    {
      key: 'days_left', header: 'Days left', align: 'right', numeric: true,
      // Only an exact date yields a countdown; a year-only date has no day, and
      // the SQL returns NULL rather than inventing 1 January or 31 December.
      render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
    },
    { key: 'due', header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
    {
      // The schema calls this a CALIBRATION, not an inspection. Keeping the
      // technical word matters: they are different procedures.
      key: 'last_calibration', header: 'Last calibration', sort: 'last_calibration',
      render: (r) => <PrecisionDate display={r.last_calibration_display} precision={r.last_calibration_precision} />,
    },
    { key: 'mapping', header: 'Mapping', sort: 'mapping', render: (r) => <DetectorMappingBadge status={r.mapping_status} /> },
    { key: 'manufacturer', header: 'Manufacturer', sort: 'manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { key: 'model', header: 'Model', render: (r) => <Text value={r.model} /> },
  ]
}

export function GasDetectorsView() {
  const [query, setQuery] = useState<DetectorQuery>(DEFAULT_DETECTOR_QUERY)
  const supabase = useSupabaseClient()
  const { state, reload } = useGasDetectors(query)
  const makers = useMakers('v_gas_detector_management')
  // The tiles ARE these buckets, so their counts ignore the bucket a tile selects; every other filter applies.
  const { state: summary } = useGasDetectorSummary({ ...query, due: 'all', mapping: 'all' })
  const regions = useRegions()

  // Stations for the dependent filter, scoped to the chosen Region so the list
  // stays bounded. Without a Region the dropdown is not offered at all rather
  // than loading every station in the company.
  const stationQuery = useMemo(
    () => ({ ...DEFAULT_STATION_QUERY, regionId: query.regionId, pageSize: 200 }),
    [query.regionId],
  )
  const stations = useStations(stationQuery, { enabled: Boolean(query.regionId) })

  const update = useCallback((patch: Partial<DetectorQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as DetectorSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => setQuery(DEFAULT_DETECTOR_QUERY), [])
  // Owner request 2026-10-02: the tiles are quick filters. One bucket at a time; pressing the active one clears it.
  type Bucket = Pick<DetectorQuery, 'due' | 'mapping' | 'presence'>
  const NONE: Bucket = { due: 'all', mapping: 'all', presence: 'installed' }
  const isPicked = (b: Partial<Bucket>) => {
    const t = { ...NONE, ...b }
    return query.due === t.due && query.mapping === t.mapping && query.presence === t.presence
  }
  const pick = (b: Partial<Bucket>) => update(isPicked(b) ? NONE : { ...NONE, ...b })
  const tile = (b: Partial<Bucket>) => ({ onSelect: () => pick(b), active: isPicked(b) })
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.stationId !== null ||
    query.area !== 'all' || query.mapping !== 'all' || query.due !== 'all' ||
    query.presence !== DEFAULT_DETECTOR_QUERY.presence || hasAssetFilters(query.filters)
  const total = state.status === 'ready' ? state.data.total : null

  // The page header and the section tabs belong to the workspace (Installed is one of its tabs).
  return (
    <>

      <div className="flex min-w-0 flex-col gap-3">
        {/* Counted over the whole authorized dataset, not the current page and
          * not the current filters — and a failed count is STATED rather than
          * rendered as a zero. */}
        {summary.status === 'error' ? (
          <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
            The attention summary could not be loaded, so no counts are shown. The table below is unaffected.
          </p>
        ) : null}
        {summary.status === 'ready' ? (
          <section aria-labelledby="detector-attention" className="rounded border bg-card px-3 py-2">
            <h2 id="detector-attention" className="sr-only">
              Gas detector attention summary
            </h2>
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3 lg:grid-cols-6">
              <Metric label="Detectors" value={summary.data.total.toLocaleString()} hint={hasFilters ? 'installed, matching the filters' : 'installed, visible to you'} {...tile({})} />
              <Metric label="Overdue" value={summary.data.overdue.toLocaleString()} tone="overdue" {...tile({ due: 'overdue' })} />
              <Metric
                label="Due ≤30d"
                value={summary.data.attention.toLocaleString()}
                tone="due"
                hint="includes overdue"
                {...tile({ due: 'attention' })}
              />
              <Metric
                label="Needs unit"
                value={summary.data.needs_unit_mapping.toLocaleString()}
                tone="unmapped"
                hint="mapping"
                {...tile({ mapping: 'needs_unit_mapping' })}
              />
              {/* A real data-quality signal: no exact date means no countdown is
                * possible, which is different from being within date. */}
              <Metric label="No exact date" value={summary.data.unknown_date.toLocaleString()} {...tile({ due: 'unknown' })} />
              {/* Evidence, not a device — and never added to the detector count. */}
              <Metric
                label="Not installed"
                value={summary.data.not_installed.toLocaleString()}
                hint="recorded absence"
                {...tile({ presence: 'not_installed' })}
              />
            </div>
            <p className="mt-1.5 text-xs text-muted-foreground">
              Area classification of installed detectors: <span className="tabular">{summary.data.open_area.toLocaleString()}</span>{' '}
              open, <span className="tabular">{summary.data.closed_area.toLocaleString()}</span> closed. Detectors whose
              area is not recorded are counted in neither.
              {total !== null && total !== summary.data.total ? (
                <>
                  {' '}
                  The table below shows <span className="tabular">{total.toLocaleString()}</span> rows matching the
                  current filters.
                </>
              ) : null}
            </p>
          </section>
        ) : null}

        <DataToolbar label="Search and filter gas detectors" filtersActive={hasFilters}>
          <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
            <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
            <span className="sr-only">Search gas detectors</span>
            <input
              id="gas-detectors-search" name="gas-detectors-search" type="search"
              value={query.search}
              onChange={(e) => update({ search: e.target.value })}
              placeholder="Serial, manufacturer, model, station…"
              dir="auto"
              className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
            />
          </label>

          {/* Changing Region clears the Station: a station from the old region would silently contradict the new one. */}
          <MultiSelectFilter id="gas-detectors-region" label="Region" value={query.regionId} onChange={(v) => update({ regionId: v || null, stationId: null })}
                             options={regions.state.status === 'ready' ? regions.state.data.map((r) => ({ value: r.region_id, label: r.region_name })) : []} />

          {query.regionId ? (
            <MultiSelectFilter id="gas-detectors-station" label="Station" value={query.stationId} onChange={(v) => update({ stationId: v || null })}
                               options={stations.state.status === 'ready' ? stations.state.data.rows.map((s) => ({ value: s.station_id, label: s.station_name })) : []} />
          ) : null}

          {/* A classification, not a status: listed alphabetically, because neither value is "good" or "bad". */}
          <MultiSelectFilter id="gas-detectors-area" label="Area" value={query.area} empty="all" allLabel="All areas"
                             onChange={(area) => update({ area })} options={[{ value: 'closed', label: 'Closed' }, { value: 'open', label: 'Open' }]} />

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Presence</span>
            <select
              id="gas-detectors-presence" name="gas-detectors-presence" value={query.presence}
              onChange={(e) => update({ presence: e.target.value as DetectorQuery['presence'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* Defaults to installed: the registry's subject is the device.
                * Recorded absence is evidence and is reachable here, but it is
                * never silently mixed into a detector count. */}
              <option value="installed">Installed detectors</option>
              <option value="not_installed">Recorded as not installed</option>
              <option value="unknown">Presence unknown</option>
              <option value="all">All records</option>
            </select>
          </label>

          {/* Owner request 2026-10-02: no Mapping filter; the Needs unit tile still filters. */}
          <MultiSelectFilter id="gas-detectors-due" label="Due" value={query.due} empty="all" aliases={DUE_ALIASES}
                             onChange={(due) => update({ due })} options={DUE_OPTIONS} />

          <AssetFilterBar id="gas-detectors" value={query.filters} onChange={(filters) => update({ filters })}
                          makers={makers.length ? makers : undefined} date={DETECTOR_DATE} />
          {hasFilters ? (
            <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
              <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
              Clear
            </Button>
          ) : null}
          <span className="ml-auto">
            <ExportButtons name="gas-detectors" load={queryLoader(supabase, 'Gas detectors', GAS_DETECTOR_COLUMNS, (c) => detectorRequest(c, query))} />
          </span>
        </DataToolbar>

        <RegistryTable

          record={(r) => (r.detector_id ? { table: 'gas_detectors', id: r.detector_id } : null)}
          label="Gas Detectors"
          state={state}
          reload={reload}
          columns={columns()}
          rowKey={detectorRowKey}
          sort={query.sort}
          direction={query.direction}
          onSort={onSort}
          page={query.page}
          pageSize={query.pageSize}
          onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
          onClearFilters={clearFilters}
          emptyTitle="No Gas Detectors are currently recorded"
          emptyDescription="Gas detectors appear here once the source workbooks have been imported. Nothing has been imported yet."
          errorTitle="Could not load Gas Detectors"
          detail={(r) => (
            <>
              <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
              <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
              <Fact label="Model"><Text value={r.model} /></Fact>
              <Fact label="Region"><RegionChip name={r.region_name} /></Fact>
              <Fact label="Station"><Text value={r.station_name} /></Fact>
              <Fact label="Unit"><DetectorUnitCell row={r} /></Fact>
              <Fact label="Presence"><PresenceBadge value={r.detector_presence} /></Fact>
              <Fact label="Area type"><AreaType value={r.area_type} /></Fact>
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
          footnote={
            'The schema records an area classification (open or closed) on the area, not a physical position for the detector, so no location is shown. ' +
            'Calibration certificate, calibration gas, detection range and sensor type are not columns this schema carries. ' +
            'Rows recorded as not installed are evidence that no detector exists at that location; they carry no serial and no calibration date.'
          }
        />
      </div>
    </>
  )
}
