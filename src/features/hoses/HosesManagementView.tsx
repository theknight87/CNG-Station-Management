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
import { DueBadge, PrecisionDate, Pressure, SourceStatus, Text } from '@/features/units/assetDisplay'
import {
  HoseDescription, HoseMappingBadge, HoseSerial, HoseStationCell, HoseUnitCell,
} from '@/features/hoses/HosePieces'
import {
  DEFAULT_HOSE_QUERY, useHoseSummary, useHoses,
  type HoseQuery, type HoseRegistryRow, type HoseSort,
} from '@/features/hoses/useHoseManagement'

/**
 * Global Hoses Management — the company-wide hose registry.
 *
 * IDENTITY LEADS. A hose is an individually traceable item, so Serial is the
 * row header and comes first, followed immediately by the test-attention
 * columns. Description is genuinely useful but it is descriptive, not
 * identifying, so it sits after them rather than consuming prime scan width.
 *
 * TERMINOLOGY IS THE SCHEMA'S. The columns are `last_test_date` and
 * `next_test_date`, so the headers read "Last test" and "Next test". They are
 * NOT relabelled "Calibration" — testing a hose and calibrating an instrument
 * are different activities, and the project's alert vocabulary calls this
 * subject `hose_hydrotest`. Nothing in the schema or the source says
 * "hydrostatic", so nothing here claims it does.
 *
 * Fields deliberately ABSENT, because no column exists for them: manufacturer,
 * model, length, diameter, hose type, material, installation date, and
 * certificate reference. Manufacturer and model are NOT parsed out of
 * `description` — free text stays free text.
 */

function columns(): RegistryColumn<HoseRegistryRow>[] {
  return [
    {
      // Identity first, and the duplicate condition travels WITH the serial
      // rather than hiding in a separate column, because it is a fact about
      // this identifier.
      key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
      render: (r) => <HoseSerial row={r} />,
    },
    { key: 'station', header: 'Station', sort: 'station', render: (r) => <HoseStationCell row={r} /> },
    { key: 'unit', header: 'Unit', sort: 'unit', render: (r) => <HoseUnitCell row={r} /> },
    {
      key: 'next_due', header: 'Next test', sort: 'next_due',
      render: (r) => (
        <>
          <PrecisionDate display={r.next_test_display} precision={r.next_test_precision} />
          {/* Source status such as "منتهي" sits BESIDE a missing date, never
            * becoming one (principle #21). */}
          {!r.next_test_display ? <SourceStatus value={r.source_status_raw} /> : null}
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
      key: 'last_test', header: 'Last test', sort: 'last_test',
      render: (r) => <PrecisionDate display={r.last_test_display} precision={r.last_test_precision} />,
    },
    { key: 'mapping', header: 'Mapping', sort: 'mapping', render: (r) => <HoseMappingBadge status={r.mapping_status} /> },
    {
      key: 'description', header: 'Description', sort: 'description',
      render: (r) => <HoseDescription value={r.description} />,
    },
    {
      // The stored unit, never inferred from magnitude and never converted.
      key: 'working_pressure', header: 'Working pressure', align: 'right',
      render: (r) => (
        <Pressure value={r.working_pressure_value} unit={r.working_pressure_unit} raw={r.working_pressure_raw} />
      ),
    },
  ]
}

export function HosesManagementView() {
  const [query, setQuery] = useState<HoseQuery>(DEFAULT_HOSE_QUERY)
  const { state, reload } = useHoses(query)
  const { state: summary } = useHoseSummary()
  const regions = useRegions()

  // Stations for the dependent filter, scoped to the chosen Region so the list
  // stays bounded. Without a Region the dropdown is not offered at all rather
  // than loading every station in the company.
  const stationQuery = useMemo(
    () => ({ ...DEFAULT_STATION_QUERY, regionId: query.regionId, pageSize: 200 }),
    [query.regionId],
  )
  const stations = useStations(stationQuery, { enabled: Boolean(query.regionId) })

  const update = useCallback((patch: Partial<HoseQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as HoseSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => setQuery(DEFAULT_HOSE_QUERY), [])
  const hasFilters =
    Boolean(query.search.trim()) || query.regionId !== null || query.stationId !== null ||
    query.mapping !== 'all' || query.due !== 'all' || query.serial !== 'all'
  const total = state.status === 'ready' ? state.data.total : null

  return (
    <PageContainer>
      <PageHeader
        title="Hoses Management"
        description="Hoses across every Region you are authorized for, with their test status and serial traceability."
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
          <section aria-labelledby="hose-attention" className="rounded border bg-card px-3 py-2">
            <h2 id="hose-attention" className="sr-only">
              Hose attention summary
            </h2>
            <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4 lg:grid-cols-7">
              <Metric label="Hoses" value={summary.data.total.toLocaleString()} hint="visible to you" />
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
              {/* Serial quality is its OWN dimension — neither of these is a
                * mapping problem and neither is an overdue test. */}
              <Metric label="No serial" value={summary.data.serial_missing.toLocaleString()} hint="not recorded" />
              <Metric
                label="Duplicate serial"
                value={summary.data.serial_duplicate.toLocaleString()}
                hint="reported, never merged"
              />
            </div>
            {total !== null && total !== summary.data.total ? (
              <p className="mt-1.5 text-xs text-muted-foreground">
                Counts cover all hoses visible to you. The table below shows{' '}
                <span className="tabular">{total.toLocaleString()}</span> matching the current filters.
              </p>
            ) : null}
          </section>
        ) : null}

        <DataToolbar label="Search and filter hoses">
          <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
            <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
            <span className="sr-only">Search hoses</span>
            <input
              id="hoses-search" name="hoses-search" type="search"
              value={query.search}
              onChange={(e) => update({ search: e.target.value })}
              placeholder="Serial, description, station…"
              dir="auto"
              className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
            />
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Region</span>
            <select
              id="hoses-region" name="hoses-region" value={query.regionId ?? ''}
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
                id="hoses-station" name="hoses-station" value={query.stationId ?? ''}
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
            <span>Serial</span>
            <select
              id="hoses-serial" name="hoses-serial" value={query.serial}
              onChange={(e) => update({ serial: e.target.value as HoseQuery['serial'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* Serial QUALITY, not mapping and not due status. */}
              <option value="all">Any serial state</option>
              <option value="recorded">Serial recorded</option>
              <option value="missing">No serial recorded</option>
              <option value="duplicate">Duplicate serial</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Mapping</span>
            <select
              id="hoses-mapping" name="hoses-mapping" value={query.mapping}
              onChange={(e) => update({ mapping: e.target.value as HoseQuery['mapping'] })}
              className="h-7 rounded border bg-background px-1.5 text-sm text-foreground"
            >
              {/* Only the states a hose can actually hold. */}
              <option value="all">All states</option>
              <option value="resolved">Resolved</option>
              <option value="needs_unit_mapping">Needs unit mapping</option>
              <option value="conflict">Conflict</option>
            </select>
          </label>

          <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
            <span>Due</span>
            <select
              id="hoses-due" name="hoses-due" value={query.due}
              onChange={(e) => update({ due: e.target.value as HoseQuery['due'] })}
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
          label="Hoses"
          state={state}
          reload={reload}
          columns={columns()}
          rowKey={(r) => r.id}
          sort={query.sort}
          direction={query.direction}
          onSort={onSort}
          page={query.page}
          pageSize={query.pageSize}
          onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
          onClearFilters={clearFilters}
          emptyTitle="No Hoses are currently recorded"
          emptyDescription="Hoses appear here once the source workbooks have been imported. Nothing has been imported yet."
          errorTitle="Could not load Hoses"
          detail={(r) => (
            <>
              <Fact label="Serial"><HoseSerial row={r} /></Fact>
              <Fact label="Serial (source)">
                {r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}
              </Fact>
              {/* The full text, untruncated — the column shows a shortened form. */}
              <Fact label="Description">
                {r.description ? <span dir="auto">{r.description}</span> : <NullValue />}
              </Fact>
              <Fact label="Region"><Text value={r.region_name} /></Fact>
              <Fact label="Station"><Text value={r.station_name} /></Fact>
              <Fact label="Unit"><HoseUnitCell row={r} /></Fact>
              <Fact label="Dispenser"><Text value={r.dispenser_name} /></Fact>
              <Fact label="Mapping"><HoseMappingBadge status={r.mapping_status} /></Fact>
              <Fact label="Working pressure">
                <Pressure value={r.working_pressure_value} unit={r.working_pressure_unit} raw={r.working_pressure_raw} />
              </Fact>
              <Fact label="Test pressure">
                <Pressure value={r.test_pressure_value} unit={r.test_pressure_unit} raw={r.test_pressure_raw} />
              </Fact>
              <Fact label="Last test">
                <PrecisionDate display={r.last_test_display} precision={r.last_test_precision} />
              </Fact>
              <Fact label="Next test">
                <PrecisionDate display={r.next_test_display} precision={r.next_test_precision} />
              </Fact>
              <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
              <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
              <Fact label="Source status"><Text value={r.source_status_raw} /></Fact>
              <Fact label="Source file"><Text value={r.source_file} /></Fact>
              <Fact label="Source row">
                {r.source_row === null ? <NullValue /> : <span className="tabular">{r.source_row}</span>}
              </Fact>
              <Fact label="Notes"><Text value={r.notes} /></Fact>
            </>
          )}
          footnote={
            'The schema records a free-text description, not manufacturer and model, so neither is shown and neither is parsed out of the description. ' +
            'Pressures carry only the unit the source proved and are never converted. ' +
            'A duplicate serial is reported beside the identifier and never merged, suffixed or repaired; a missing serial stays empty and is never generated.'
          }
        />
      </div>
    </PageContainer>
  )
}
