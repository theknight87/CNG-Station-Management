import { useCallback, useState } from 'react'
import { ExportButtons } from '@/features/export/ExportButtons'
import { queryLoader } from '@/features/export/exportData'
import { VESSEL_COLUMNS } from '@/features/export/exportColumns'
import { useSupabaseClient } from '@/lib/supabase/client'
import { MakerChip, RegionChip } from '@/components/data/AssetChips'
import { AssetFilterBar } from '@/components/data/AssetFilterBar'
import { hasAssetFilters } from '@/components/data/assetFilters'
import { useMakers } from '@/components/data/useMakers'
import { Search, X } from 'lucide-react'

import { RegistryTable, type RegistryColumn } from '@/components/data/RegistryTable'
import { Identifier } from '@/components/data/TechnicalText'
import { NullValue } from '@/components/data/NullValue'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import { Fact } from '@/features/hierarchy/HierarchyPieces'
import { useRegions } from '@/features/hierarchy/useHierarchy'
import { Metric } from '@/features/relief-valves/SrvPieces'
import { DueBadge, PrecisionDate, Serial, SourceStatus, Text } from '@/features/units/assetDisplay'
import {
  VesselDuplicateSerialBadge, VesselMappingBadge, VesselStationCell, VesselUnitCell,
} from '@/features/vessels/VesselPieces'
import { RelatedSrvs } from '@/features/vessels/RelatedSrvs'
import {
  VESSEL_DATE,
  DEFAULT_VESSEL_QUERY, useVessels, useVesselSummary,
  type VesselAssetType, type VesselQuery, type VesselRegistryRow, type VesselSort,
  vesselRequest,
} from '@/features/vessels/useVesselManagement'
import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DUE_ALIASES, DUE_OPTIONS } from '@/components/data/multiFilter'

/**
 * One registry, driven by asset type.
 *
 * Storage Vessels and Recovery Tanks share this renderer because their schemas
 * genuinely match, field for field — not to force symmetry. Where they DIFFER
 * they diverge honestly: only Storage Vessels show related SRVs, because only
 * Storage Vessels can own one.
 *
 * Fields the schema does not carry — capacity, design or working pressure,
 * manufacture year, certificate reference — are absent rather than drawn as
 * empty columns. An empty "Capacity" column would imply the value is merely
 * missing rather than never recorded.
 */

const LABEL: Record<VesselAssetType, { singular: string; plural: string; dateLabel: string }> = {
  storage_vessel: { singular: 'Storage Vessel', plural: 'Storage Vessels', dateLabel: 'inspection' },
  recovery_tank: { singular: 'Recovery Tank', plural: 'Recovery Tanks', dateLabel: 'inspection' },
}

function columns(assetType: VesselAssetType): RegistryColumn<VesselRegistryRow>[] {
  return [
    { key: 'region', header: 'Region', sort: 'region', render: (r) => <RegionChip name={r.region_name} /> },
    {
      key: 'serial', header: 'Serial', rowHeader: true, sort: 'serial',
      // The badge sits BESIDE the serial, not in place of it: the value the
      // source recorded is still shown exactly as recorded, unmodified.
      render: (r) => (
        <span className="flex flex-col items-start gap-0.5">
          <Serial value={r.serial_number} status={r.serial_status} />
          <VesselDuplicateSerialBadge row={r} />
        </span>
      ),
    },
    { key: 'manufacturer', header: 'Manufacturer', sort: 'manufacturer', render: (r) => <MakerChip value={r.manufacturer} /> },
    { key: 'model', header: 'Model', render: (r) => <Text value={r.model} /> },
    { key: 'station', header: 'Station', sort: 'station', render: (r) => <VesselStationCell row={r} /> },
    { key: 'unit', header: 'Unit', sort: 'unit', render: (r) => <VesselUnitCell row={r} /> },
    { key: 'mapping', header: 'Mapping', sort: 'mapping', render: (r) => <VesselMappingBadge status={r.mapping_status} /> },
    {
      // The schema calls this an INSPECTION, not a calibration. Keeping the
      // technical word matters: they are different procedures.
      key: 'last_inspection', header: 'Last inspection', sort: 'last_inspection',
      render: (r) => <PrecisionDate display={r.last_inspection_display} precision={r.last_inspection_precision} />,
    },
    {
      key: 'next_due', header: 'Next inspection', sort: 'next_due',
      render: (r) => (
        <>
          <PrecisionDate display={r.next_inspection_display} precision={r.next_inspection_precision} />
          {/* Source status such as "منتهية" sits BESIDE a missing date, never
            * becoming one (principle #21). */}
          {!r.next_inspection_display ? <SourceStatus value={r.source_status_raw} /> : null}
        </>
      ),
    },
    {
      key: 'days_left', header: 'Days left', align: 'right', numeric: true,
      // Only an exact date yields a countdown; a year-only date has no day.
      render: (r) => (r.days_left === null ? <NullValue /> : <span>{r.days_left.toLocaleString()}</span>),
    },
    { key: 'due', header: 'Status', render: (r) => <DueBadge status={r.due_status} /> },
    ...(assetType === 'storage_vessel' ? [] : []),
  ]
}

export function VesselRegistrySection({ assetType }: { assetType: VesselAssetType }) {
  const [query, setQuery] = useState<VesselQuery>(DEFAULT_VESSEL_QUERY)
  const supabase = useSupabaseClient()
  const { state, reload } = useVessels(assetType, query)
  const makers = useMakers('v_vessel_management', 'manufacturer', ['asset_type', assetType])
  // The tiles ARE these buckets, so their counts ignore the bucket a tile selects; every other filter applies.
  const { state: summary } = useVesselSummary(assetType, { ...query, due: 'all', mapping: 'all', duplicateSerial: false })
  const regions = useRegions()
  const label = LABEL[assetType]

  const update = useCallback((patch: Partial<VesselQuery>) => {
    setQuery((prev) => ({ ...prev, ...patch, page: 'page' in patch ? (patch.page as number) : 0 }))
  }, [])

  const onSort = useCallback((key: string) => {
    setQuery((prev) => ({
      ...prev,
      sort: key as VesselSort,
      direction: prev.sort === key && prev.direction === 'asc' ? 'desc' : 'asc',
      page: 0,
    }))
  }, [])

  const clearFilters = useCallback(() => setQuery(DEFAULT_VESSEL_QUERY), [])
  // Owner request 2026-10-02: the tiles are quick filters. One bucket at a time; pressing the active one clears it.
  type Bucket = Pick<VesselQuery, 'due' | 'mapping' | 'duplicateSerial'>
  const NONE: Bucket = { due: 'all', mapping: 'all', duplicateSerial: false }
  const isPicked = (b: Partial<Bucket>) => {
    const t = { ...NONE, ...b }
    return query.due === t.due && query.mapping === t.mapping && query.duplicateSerial === t.duplicateSerial
  }
  const pick = (b: Partial<Bucket>) => update(isPicked(b) ? NONE : { ...NONE, ...b })
  const tile = (b: Partial<Bucket>) => ({ onSelect: () => pick(b), active: isPicked(b) })
  const hasFilters =
    Boolean(query.search.trim()) ||
    query.regionId !== null ||
    query.mapping !== 'all' ||
    query.due !== 'all' ||
    query.duplicateSerial ||
    hasAssetFilters(query.filters)

  return (
    <div className="flex min-w-0 flex-col gap-3">
      {/* Counted over the whole authorized dataset for THIS asset type, not the
        * current page and not the current filters — and a failed count is
        * stated rather than rendered as a zero. */}
      {summary.status === 'error' ? (
        <p className="rounded border border-destructive/30 bg-destructive/5 px-3 py-2 text-sm">
          The attention summary could not be loaded, so no counts are shown. The table below is unaffected.
        </p>
      ) : null}
      {summary.status === 'ready' ? (
        <section aria-labelledby="vessel-attention" className="rounded border bg-card px-3 py-2">
          <h2 id="vessel-attention" className="sr-only">
            {label.plural} attention summary
          </h2>
          <div className="grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-3 lg:grid-cols-7">
            <Metric label={label.plural} value={summary.data.total.toLocaleString()} hint={hasFilters ? 'matching the filters' : 'visible to you'} {...tile({})} />
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
            <Metric label="Conflict" value={summary.data.conflict.toLocaleString()} {...tile({ mapping: 'conflict' })} />
            {/* A real data-quality signal: no exact date means no countdown is
              * possible, which is different from being within date. */}
            <Metric label="No exact date" value={summary.data.unknown_date.toLocaleString()} {...tile({ due: 'unknown' })} />
            {/* Candidates for review, not confirmed duplicates. Nothing is
              * merged or removed on the strength of a repeated string. */}
            <Metric
              label="Duplicate serial"
              value={summary.data.serial_duplicate.toLocaleString()}
              hint="candidates"
              {...tile({ duplicateSerial: true })}
            />
          </div>
          {hasFilters ? (
            <p className="mt-1.5 text-xs text-muted-foreground">Counts match the current filters. Press a tile to show only those rows.</p>
          ) : null}
        </section>
      ) : null}

      <DataToolbar label={`Search and filter ${label.plural.toLowerCase()}`}>
        <label className="relative flex min-w-0 flex-1 items-center sm:max-w-xs">
          <Search className="pointer-events-none absolute left-2 h-3.5 w-3.5 text-muted-foreground" aria-hidden="true" />
          <span className="sr-only">Search {label.plural.toLowerCase()}</span>
          <input
            type="search"
            value={query.search}
            onChange={(e) => update({ search: e.target.value })}
            placeholder="Serial, manufacturer, station…"
            dir="auto"
            className="h-7 w-full rounded border bg-background pl-7 pr-2 text-sm placeholder:text-muted-foreground"
          />
        </label>

        <MultiSelectFilter id="vessel-region" label="Region" value={query.regionId} onChange={(v) => update({ regionId: v || null })}
                           options={regions.state.status === 'ready' ? regions.state.data.map((r) => ({ value: r.region_id, label: r.region_name })) : []} />

        {/* Owner request 2026-10-02: no Mapping filter; the Needs unit / Conflict tiles still filter. */}
        <MultiSelectFilter id="vessel-due" label="Due" value={query.due} empty="all" aliases={DUE_ALIASES}
                           onChange={(due) => update({ due })} options={DUE_OPTIONS} />

        {/* A single checkbox rather than a new filtering system: it narrows the
          * existing query by one server-side column and hides no member of a
          * candidate group, because both halves carry the flag. */}
        <label className="flex items-center gap-1.5 text-xs text-muted-foreground">
          <input
            type="checkbox"
            checked={query.duplicateSerial}
            onChange={(e) => update({ duplicateSerial: e.target.checked })}
            className="h-3.5 w-3.5 rounded border"
          />
          <span>Duplicate serial candidates only</span>
        </label>

        <AssetFilterBar id={`vessel-${assetType}`} value={query.filters} onChange={(filters) => update({ filters })} makers={makers} date={VESSEL_DATE} />
        {hasFilters ? (
          <Button variant="ghost" size="sm" onClick={clearFilters} className="h-7">
            <X className="mr-1 h-3.5 w-3.5" aria-hidden="true" />
            Clear
          </Button>
        ) : null}
        <span className="ml-auto">
          <ExportButtons name={assetType === 'storage_vessel' ? 'storage-vessels' : 'recovery-tanks'}
                         load={queryLoader(supabase, label.plural, VESSEL_COLUMNS, (c) => vesselRequest(c, assetType, query))} />
        </span>
      </DataToolbar>

      <RegistryTable

        record={(r) => ({ table: r.asset_type === 'storage_vessel' ? 'storage_vessels' : 'recovery_tanks', id: r.id })}
        label={label.plural}
        state={state}
        reload={reload}
        columns={columns(assetType)}
        rowKey={(r) => r.id}
        sort={query.sort}
        direction={query.direction}
        onSort={onSort}
        page={query.page}
        pageSize={query.pageSize}
        onPage={(p) => setQuery((prev) => ({ ...prev, page: p }))}
        onClearFilters={clearFilters}
        emptyTitle={`No ${label.plural} are currently recorded`}
        emptyDescription={`${label.plural} appear here once the source workbooks have been imported. Nothing has been imported yet.`}
        errorTitle={`Could not load ${label.plural}`}
        detail={(r) => (
          <>
            <Fact label="Serial"><Serial value={r.serial_number} status={r.serial_status} /></Fact>
            <Fact label="Serial (source)">
              {r.serial_number_raw ? <Identifier value={r.serial_number_raw} /> : <NullValue />}
            </Fact>
            {r.serial_duplicate ? (
              <Fact label="Serial review"><VesselDuplicateSerialBadge row={r} /></Fact>
            ) : null}
            <Fact label="Manufacturer"><Text value={r.manufacturer} /></Fact>
            <Fact label="Model"><Text value={r.model} /></Fact>
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
            <Fact label="Unit"><VesselUnitCell row={r} /></Fact>
            <Fact label="Last inspection">
              <PrecisionDate display={r.last_inspection_display} precision={r.last_inspection_precision} />
            </Fact>
            <Fact label="Next inspection">
              <PrecisionDate display={r.next_inspection_display} precision={r.next_inspection_precision} />
            </Fact>
            <Fact label="Days left">{r.days_left === null ? <NullValue /> : r.days_left.toLocaleString()}</Fact>
            <Fact label="Status"><DueBadge status={r.due_status} /></Fact>
            <Fact label="Notes"><Text value={r.notes} /></Fact>

            {/* ONLY Storage Vessels. A Recovery Tank cannot own an SRV: there
              * is no recovery_tank_id column, no foreign key, and
              * srv_parent_kind does not include it. */}
            {assetType === 'storage_vessel' ? <RelatedSrvs vesselId={r.id} /> : null}
          </>
        )}
        footnote={
          assetType === 'storage_vessel'
            ? 'Capacity, design pressure, manufacture year and certificate reference are not columns this schema carries, so they are not shown. Expand a row to see its confirmed relief valves.'
            : 'Capacity, design pressure, manufacture year and certificate reference are not columns this schema carries. Recovery Tanks have no relief-valve relationship in this schema, so none is shown.'
        }
      />
    </div>
  )
}
