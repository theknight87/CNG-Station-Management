import { Link, useOutletContext } from 'react-router-dom'

import { Identifier } from '@/components/data/TechnicalText'
import { NullValue, ValueOrNull } from '@/components/data/NullValue'
import { SectionHeader } from '@/components/layout/PageContainer'
import { Count, Fact, FactGrid } from '@/features/hierarchy/HierarchyPieces'
import type { UnitSummary } from '@/features/hierarchy/useHierarchy'

/**
 * Unit Overview: what this Unit contains, and what needs attention.
 *
 * NOT A SECOND DASHBOARD. No oversized KPI cards, no charts. A compact
 * equipment inventory and a short attention line, both reading from the
 * `v_unit_summary` row the workspace header already loaded - so the Overview
 * costs no extra query at all.
 *
 * NO EMPTY EXPECTED SLOTS. Equipment types with no record are shown with a real
 * `0`, not as a placeholder waiting to be filled. Nothing in the schema says a
 * Unit must have a recovery tank, so drawing an empty one would assert a
 * requirement that does not exist.
 *
 * The SRV count is the Unit-CONFIRMED count from `v_unit_summary`, which counts
 * `installed_relief_valves` by `unit_id`. Valves awaiting Station or Unit
 * confirmation have a NULL `unit_id` and are excluded; warehouse stock is a
 * different table entirely.
 */

const EQUIPMENT: { label: string; key: keyof UnitSummary; to: string }[] = [
  { label: 'Compressors', key: 'compressors', to: 'compressor' },
  { label: 'Recovery Tanks', key: 'recovery_tanks', to: 'recovery-tank' },
  { label: 'Dispensers', key: 'dispensers', to: 'dispensers' },
  { label: 'Storage Vessels', key: 'storage_vessels', to: 'storage' },
  { label: 'Gas Detectors', key: 'gas_detectors', to: 'gas-detectors' },
  { label: 'Hoses', key: 'hoses', to: 'hoses' },
  { label: 'Relief Valves', key: 'installed_srvs', to: 'srvs' },
]

export function OverviewSection() {
  const unit = useOutletContext<UnitSummary>()

  return (
    <div className="flex min-w-0 flex-col gap-3">
      <section aria-labelledby="unit-equipment" className="rounded border bg-card p-3">
        <SectionHeader
          id="unit-equipment"
          title="Equipment on this Unit"
          description="Counts of records actually mapped to this Unit. An equipment type with no record is not a gap."
        />
        <ul className="mt-2.5 grid grid-cols-2 gap-x-4 gap-y-2 sm:grid-cols-4 lg:grid-cols-7">
          {EQUIPMENT.map((e) => (
            <li key={e.key}>
              <Link
                to={`/units/${unit.unit_id}/${e.to}`}
                className="group block rounded focus-visible:outline-none"
              >
                <span className="block text-xs uppercase tracking-wide text-muted-foreground">{e.label}</span>
                <span className="mt-0.5 block text-lg font-semibold tabular text-brand-strong group-hover:underline">
                  {(unit[e.key] as number).toLocaleString()}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      </section>

      <section aria-labelledby="unit-attention" className="rounded border bg-card p-3">
        <SectionHeader
          id="unit-attention"
          title="Attention"
          description="Computed from exact dates only. A record with no exact next-due date is never counted as within date."
        />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Overdue"><Count value={unit.overdue} tone="overdue" /></Fact>
          </FactGrid>
        </div>
      </section>

      <section aria-labelledby="unit-record" className="rounded border bg-card p-3">
        <SectionHeader id="unit-record" title="Unit record" />
        <div className="mt-2.5">
          <FactGrid>
            <Fact label="Job number">
              {unit.job_number ? <Identifier value={unit.job_number} /> : <NullValue />}
            </Fact>
            <Fact label="Job number (source)"><ValueOrNull value={unit.job_number_raw} /></Fact>
            <Fact label="Notes"><ValueOrNull value={unit.notes} /></Fact>
          </FactGrid>

          {/* Source-reported counts are evidence, not records. They are kept
            * for traceability and never reconciled automatically against the
            * equipment above (principle #6, #18). */}
          {unit.dispenser_count_reported !== null ||
          unit.hose_count_reported !== null ||
          unit.storage_count_reported !== null ? (
            <div className="mt-3 border-t pt-2.5">
              <p className="mb-2 text-xs text-muted-foreground">
                Counts the source workbook reported. Kept for traceability and never reconciled automatically against
                the records above.
              </p>
              <FactGrid>
                <Fact label="Dispensers (source)"><ValueOrNull value={unit.dispenser_count_reported} /></Fact>
                <Fact label="Hoses (source)"><ValueOrNull value={unit.hose_count_reported} /></Fact>
                <Fact label="Storage (source)"><ValueOrNull value={unit.storage_count_reported} /></Fact>
              </FactGrid>
            </div>
          ) : null}
        </div>
      </section>
    </div>
  )
}
