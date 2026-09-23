import { useCallback, useMemo, useState } from 'react'
import { Search, X } from 'lucide-react'

import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar, PageContainer, PageHeader } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { DEFAULT_STATION_QUERY, useRegions, useStations } from '@/features/hierarchy/useHierarchy'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { DueBadge, PrecisionDate, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import {
  AreaType, DetectorMappingBadge, DetectorStationCell, DetectorUnitCell, PresenceBadge,
} from '@/features/gas-detectors/GasDetectorPieces'
import {
  DEFAULT_DETECTOR_QUERY, detectorRowKey, useGasDetectorSummary, useGasDetectors,
  type DetectorQuery, type DetectorRegistryRow, type DetectorSort,
} from '@/features/gas-detectors/useGasDetectorManagement'

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
    { key: 'manufacturer', header: 'Manufacturer', sort: 'manufacturer', render: (r) => <Text value={r.manufacturer} /> },
    { key: 'model', header: 'Model', render: (r) => <Text value={r.model} /> },
  ]
}

export function GasDetectorsView() {
  const [query, setQuery] = useState<DetectorQuery>(DEFAULT_DETECTOR_QUERY)
  const { state, reload } = useGasDetectors(query)
  const { state: summary } = useGasDetectorSummary()
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
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.stationId !== null ||
    query.area !== 'all' || query.mapping !== 'all' || query.due !== 'all' ||
    query.presence !== DEFAULT_DETECTOR_QUERY.presence
  const total = state.status === 'ready' ? state.data.total : null

  return (
    <PageContainer>
      <PageHeader
        title="Gas Detector Management"
        description="Gas detectors across every Region you are authorized for, with their calibration status and the areas they cover."
      />

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
              <Metric label="Detectors" value={summary.data.total.toLocaleString()} hint="installed, visible to you" />
              <Metric label="Overdue" value={summary.data.overdue.toLocaleString()} tone="overdue" />
              <Metric
                label="Due ≤60d"
                value={summary.data.attention.toLocaleString()}
                tone="due"
                hint="includes overdue"
              />
              <Metric
                label="Needs unit"
                value={summary.data.needs_unit_mapping.toLocaleString()}
                tone="unmapped"
                hint="mapping"
              />
              {/* A real data-quality signal: no exact date means no countdown is
                * possible, which is different from being within date. */}
              <Metric label="No exact date" value={summary.data.unknown_date.toLocaleString()} />
              {/* Evidence, not a device — and never added to the detector count. */}
              <Metric
                label="Not installed"
                value={summary.data.not_installed.toLocaleString()}
                hint="recorded absence"
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

        <DataToolbar label="Search and filter gas detectors">
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

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Region</span>
            <select
              id="gas-detectors-region" name="gas-detectors-region" value={query.regionId ?? ''}
              // Changing Region clears the Station: a station from the old
              // region would silently contradict the new one.
              onChange={(e) => update({ regionId: e.target.value || null, stationId: null })}
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

          {query.regionId ? (
            <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <span>Station</span>
              <select
                id="gas-detectors-station" name="gas-detectors-station" value={query.stationId ?? ''}
                onChange={(e) => update({ stationId: e.target.value || null })}
                className="h-7 max-w-[12rem] rounded border bg-background px-1.5 text-sm text-foreground"
              >
                <option value="">All Stations</option>
                {stations.state.status === 'ready'
                  ? stations.state.data.rows.map((s) => (
                      <option key={s.station_id} value={s.station_id}>
                        {s.station_name}
                      </option>
                    ))
                  : null}
              </select>
            </label>
          ) : null}

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Area</span>
            <select
              id="gas-detectors-area" name="gas-detectors-area" value={query.area}
              onChange={(e) => update({ area: e.target.value as DetectorQuery['area'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* A classification, not a status. The order is alphabetical, not
                * "good to bad", because neither value is either. */}
              <option value="all">All areas</option>
              <option value="closed">Closed</option>
              <option value="open">Open</option>
            </select>
          </label>

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

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Mapping</span>
            <select
              id="gas-detectors-mapping" name="gas-detectors-mapping" value={query.mapping}
              onChange={(e) => update({ mapping: e.target.value as DetectorQuery['mapping'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* Only the states a detector can actually hold. There is no
                * "needs equipment mapping" — a detector hangs off a Unit. */}
              <option value="all">All states</option>
              <option value="resolved">Resolved</option>
              <option value="needs_unit_mapping">Needs unit mapping</option>
              <option value="conflict">Conflict</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Due</span>
            <select
              id="gas-detectors-due" name="gas-detectors-due" value={query.due}
              onChange={(e) => update({ due: e.target.value as DetectorQuery['due'] })}
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

        <RegistryTable
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
              <Fact label="Serial (source)">
                {r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}
              </Fact>
              <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
              <Fact label="Model"><Text value={r.model} /></Fact>
              <Fact label="Region"><Text value={r.region_name} /></Fact>
              <Fact label="Station"><Text value={r.station_name} /></Fact>
              <Fact label="Unit"><DetectorUnitCell row={r} /></Fact>
              <Fact label="Mapping"><DetectorMappingBadge status={r.mapping_status} /></Fact>
              <Fact label="Presence"><PresenceBadge value={r.detector_presence} /></Fact>
              <Fact label="Area type"><AreaType value={r.area_type} /></Fact>
              {/* Raw source text, preserved and never interpreted. */}
              <Fact label="Area (source text)"><Text value={r.area_type_raw} /></Fact>
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
          footnote={
            'The schema records an area classification (open or closed) on the area, not a physical position for the detector, so no location is shown. ' +
            'Calibration certificate, calibration gas, detection range and sensor type are not columns this schema carries. ' +
            'Rows recorded as not installed are evidence that no detector exists at that location; they carry no serial and no calibration date.'
          }
        />
      </div>
    </PageContainer>
  )
}
