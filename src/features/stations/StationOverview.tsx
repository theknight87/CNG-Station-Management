import { useParams } from 'react-router-dom'
import { RecordAdminTools } from '@/features/record-tools/RecordAdminTools'

import {
  DataTable,
  RowHeaderCell,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  TableScroll,
} from '@/components/data/DataTable'
import { Identifier, EntityName } from '@/components/data/TechnicalText'
import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { usePublishBreadcrumbs } from '@/components/layout/breadcrumbContext'
import { PageContainer, PageHeader, SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState, NotFound, NotImplemented } from '@/components/states/AppStates'
import { AttentionBadge, Count, EntityLink, Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { useStation } from '@/features/hierarchy/useHierarchy'

/**
 * One Station: its own attributes, and the Units it owns.
 *
 * Two things this screen is careful about.
 *
 * **It has no Job Number.** Job Number lives on the Unit, not the Station, and
 * inventing a Station-level one to fill a gap in the layout would be exactly
 * the fabrication data principle #1 forbids.
 *
 * **A Station with no Units is a complete record.** Principle #19: a Station
 * whose Units are unknown is not "incomplete" and is never badged as such.
 * There is no default Unit and none is ever created to have somewhere to hang
 * assets (decision D7) — so an empty Units table says exactly that and offers
 * no "add a Unit to fix this" nudge.
 */
export function StationOverview() {
  const { stationId } = useParams<{ stationId: string }>()
  const { state, reload } = useStation(stationId)
  const loaded = state.status === 'ready' ? state.data.station : null

  usePublishBreadcrumbs(
    loaded
      ? [
          { label: 'Regions', to: '/regions' },
          { label: loaded.region_name, to: `/regions/${loaded.region_id}` },
          { label: loaded.station_name, isEntity: true },
        ]
      : null,
  )

  if (state.status === 'loading') return <PageContainer><LoadingState label="Loading Station" /></PageContainer>
  if (state.status === 'unconfigured')
    return <PageContainer><NotImplemented feature="Station detail" phase="waiting on database configuration" /></PageContainer>
  if (state.status === 'error')
    return <PageContainer><ErrorState message={state.message} onRetry={reload} /></PageContainer>

  const { station, units } = state.data
  if (!station) {
    return (
      <PageContainer>
        <NotFound
          what="Station"
          detail="This Station does not exist, or it is outside the Regions you are authorized for."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader
        title={station.station_name}
        isEntity
        description={`${station.region_name} Region`}
        actions={<AttentionBadge overdue={station.overdue} unresolved={station.unresolved_mapping} />}
      />

      <section aria-labelledby="station-facts" className="rounded border bg-card p-3">
        <SectionHeader id="station-facts" title="Station" />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Region">{station.region_name}</Fact>
            <Fact label="Bay status">
              {/* The raw source text is kept beside the normalized value
                * (principle #6) and shown when they differ, so an engineer can
                * see what the workbook actually said. */}
              <ValueOrNull value={station.bay_status} />
              {station.bay_status_raw && station.bay_status_raw !== station.bay_status ? (
                <span className="ml-1.5 text-xs text-muted-foreground">
                  source: <Identifier value={station.bay_status_raw} />
                </span>
              ) : null}
            </Fact>
            <Fact label="Units"><Count value={station.units} /></Fact>
            <Fact label="Assets"><Count value={station.assets} /></Fact>
            <Fact label="Overdue"><Count value={station.overdue} tone="overdue" /></Fact>
            <Fact label="Due ≤60d"><Count value={station.approaching_due} tone="due" /></Fact>
            <Fact label="Unresolved mapping">
              <Count value={station.unresolved_mapping} tone="unmapped" />
            </Fact>
            <Fact label="Notes">
              <ValueOrNull value={station.notes} />
            </Fact>
          </FactGrid>

          {/* Flagged for review is a fact about the SOURCE, not a defect in the
            * record, and it is stated rather than styled as damage. */}
          {station.needs_review ? (
            <p className="mt-3 flex flex-wrap items-center gap-2 text-sm">
              <StatusBadge kind="conflict" label="Flagged for review" />
              <span className="text-muted-foreground">
                {station.review_reason ?? 'Source evidence needs human confirmation.'}
              </span>
            </p>
          ) : null}
        </div>
      </section>

      <SectionHeader
        id="station-units"
        title="Units"
        description="Compressors, dispensers, vessels and detectors belong to a Unit, not to the Station."
      />

      {units.length === 0 ? (
        <EmptyState
          title="No Units recorded for this Station"
          description="This is a complete record with an unknown Unit structure, not an incomplete one. A Unit is never created automatically just to hold assets — the structure is confirmed from source evidence in Admin → Data Quality."
        />
      ) : (
        <TableScroll label="Units in this Station">
          <DataTable caption="Units in this Station with their equipment counts">
            <TableHead>
              <TableRow>
                <TableHeader>Unit</TableHeader>
                <TableHeader>Job number</TableHeader>
                <TableHeader align="right">Compressors</TableHeader>
                <TableHeader align="right">Dispensers</TableHeader>
                <TableHeader align="right">Storage</TableHeader>
                <TableHeader align="right">Recovery tanks</TableHeader>
                <TableHeader align="right">Gas detectors</TableHeader>
                <TableHeader align="right">Hoses</TableHeader>
                <TableHeader align="right">SRVs</TableHeader>
                <TableHeader align="right">Overdue</TableHeader>
              </TableRow>
            </TableHead>
            <TableBody>
              {units.map((unit) => (
                <TableRow key={unit.unit_id}>
                  <RowHeaderCell>
                    <EntityLink to={`/units/${unit.unit_id}`}>
                      <EntityName name={unit.unit_name} />
                    </EntityLink>
                  </RowHeaderCell>
                  <TableCell>
                    {/* Identifiers are TEXT and are shown exactly as stored —
                      * leading zeros and dashes intact (principle #11, #15). */}
                    {unit.job_number ? <Identifier value={unit.job_number} /> : <NullValue />}
                  </TableCell>
                  <TableCell align="right" numeric><Count value={unit.compressors} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.dispensers} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.storage_vessels} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.recovery_tanks} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.gas_detectors} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.hoses} /></TableCell>
                  {/* Unit-confirmed SRVs only. An SRV whose Unit is unproven is
                    * never attributed to a Unit (CLAUDE.md §4). */}
                  <TableCell align="right" numeric><Count value={unit.installed_srvs} /></TableCell>
                  <TableCell align="right" numeric><Count value={unit.overdue} tone="overdue" /></TableCell>
                </TableRow>
              ))}
            </TableBody>
          </DataTable>
        </TableScroll>
      )}

      {station.unresolved_mapping > 0 ? (
        <p className="text-sm text-muted-foreground">
          {station.unresolved_mapping.toLocaleString()} asset
          {station.unresolved_mapping === 1 ? '' : 's'} at this Station have no confirmed place in the hierarchy yet, so
          they are not counted under any Unit above. They are resolved in Admin → Data Quality.
        </p>
      ) : null}
      <section aria-label="Photos and editing" className="rounded border bg-card p-3">
        <RecordAdminTools record={{ table: 'stations', id: station.station_id }} onSaved={reload} />
      </section>
    </PageContainer>
  )
}
