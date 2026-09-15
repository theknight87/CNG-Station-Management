import { Link, useParams } from 'react-router-dom'

import { Identifier, EntityName } from '@/components/data/TechnicalText'
import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { PageContainer, PageHeader, SectionHeader } from '@/components/layout/PageContainer'
import { ErrorState, LoadingState, NotFound, NotImplemented } from '@/components/states/AppStates'
import { Count, Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import { useUnit } from '@/features/hierarchy/useHierarchy'

/**
 * The Unit NAVIGATION BOUNDARY (Prompt 9 §-scope).
 *
 * Prompt 9 owns getting you HERE — Region → Station → Unit — and proving the
 * Unit exists, sits under the Station and Region you navigated through, and
 * carries the equipment counts the hierarchy says it does.
 *
 * Prompt 10 owns the full Unit Detail: the equipment tabs, the SRVs tab, and
 * every per-asset table. So this page states what it knows and links onward
 * without pretending to be that screen. It shows no fabricated equipment rows
 * and no empty tabs dressed up as real ones.
 */
export function UnitOverview() {
  const { unitId } = useParams<{ unitId: string }>()
  const { state, reload } = useUnit(unitId)

  if (state.status === 'loading') return <PageContainer><LoadingState label="Loading Unit" /></PageContainer>
  if (state.status === 'unconfigured')
    return <PageContainer><NotImplemented feature="Unit detail" phase="waiting on database configuration" /></PageContainer>
  if (state.status === 'error')
    return <PageContainer><ErrorState message={state.message} onRetry={reload} /></PageContainer>

  const unit = state.data
  if (!unit) {
    return (
      <PageContainer>
        <NotFound
          what="Unit"
          detail="This Unit does not exist, or it is outside the Regions you are authorized for."
        />
      </PageContainer>
    )
  }

  return (
    <PageContainer>
      <PageHeader
        title={unit.unit_name}
        isEntity
        description={`${unit.region_name} Region`}
      />

      <p className="text-sm text-muted-foreground">
        Part of{' '}
        <Link
          to={`/stations/${unit.station_id}`}
          className="rounded font-medium text-brand-strong underline-offset-4 hover:underline"
        >
          <EntityName name={unit.station_name} />
        </Link>
      </p>

      <section aria-labelledby="unit-facts" className="rounded border bg-card p-3">
        <SectionHeader id="unit-facts" title="Unit" />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Job number">
              {unit.job_number ? <Identifier value={unit.job_number} /> : <NullValue />}
            </Fact>
            <Fact label="Station"><EntityName name={unit.station_name} /></Fact>
            <Fact label="Region">{unit.region_name}</Fact>
            <Fact label="Notes"><ValueOrNull value={unit.notes} /></Fact>
          </FactGrid>
        </div>
      </section>

      <section aria-labelledby="unit-equipment" className="rounded border bg-card p-3">
        <SectionHeader
          id="unit-equipment"
          title="Equipment on this Unit"
          description="Counts only. The equipment tables and the SRVs tab are built in Prompt 10."
        />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Compressors"><Count value={unit.compressors} /></Fact>
            <Fact label="Dispensers"><Count value={unit.dispensers} /></Fact>
            <Fact label="Storage vessels"><Count value={unit.storage_vessels} /></Fact>
            <Fact label="Recovery tanks"><Count value={unit.recovery_tanks} /></Fact>
            <Fact label="Gas detectors"><Count value={unit.gas_detectors} /></Fact>
            <Fact label="Hoses"><Count value={unit.hoses} /></Fact>
            {/* Only SRVs whose Unit is CONFIRMED. An unresolved SRV is never
              * shown in a Unit's SRV count or tab (CLAUDE.md §4). */}
            <Fact label="Installed SRVs"><Count value={unit.installed_srvs} /></Fact>
            <Fact label="Overdue"><Count value={unit.overdue} tone="overdue" /></Fact>
          </FactGrid>
        </div>

        {/* Source-reported counts are kept separate from what the hierarchy
          * actually holds, and are never reconciled silently. A workbook
          * saying "3 dispensers" is evidence, not a dispenser record. */}
        {unit.dispenser_count_reported !== null ||
        unit.hose_count_reported !== null ||
        unit.storage_count_reported !== null ? (
          <div className="mt-3 border-t pt-2.5">
            <p className="mb-2 text-xs text-muted-foreground">
              Counts the source workbook reported. Kept for traceability and never reconciled automatically against the
              records above.
            </p>
            <FactGrid>
              <Fact label="Dispensers (source)"><ValueOrNull value={unit.dispenser_count_reported} /></Fact>
              <Fact label="Hoses (source)"><ValueOrNull value={unit.hose_count_reported} /></Fact>
              <Fact label="Storage (source)"><ValueOrNull value={unit.storage_count_reported} /></Fact>
            </FactGrid>
          </div>
        ) : null}
      </section>

      {/* Deliberately NOT the generic NotImplemented panel: its copy says
        * "nothing is shown here because there is no real data", which would
        * contradict the real counts above. This page is a boundary, not a
        * stub, so it says exactly what is and is not here. */}
      <p className="rounded border bg-muted/30 px-3 py-2 text-sm text-muted-foreground">
        The equipment tables and the Unit SRVs tab are built in Prompt 10. The counts above are real; no per-asset rows
        are shown here because that screen does not exist yet, and none are invented to fill the space.
      </p>
    </PageContainer>
  )
}
