import { useEffect, useMemo, useState } from 'react'

import { MultiSelectFilter } from '@/components/data/MultiSelectFilter'
import { DataToolbar } from '@/components/layout/PageContainer'
import { Button } from '@/components/ui/button'
import type { ReportSpec } from './reportSpecs'
import { EMPTY_FILTERS, type ReportFilterValues } from './useReportQuery'
import { useRegionOptions, useStationOptions, useUnitOptions } from './useHierarchyOptions'

const DUE_STATES = [
  { value: '', label: 'Any due state' },
  { value: 'overdue', label: 'Overdue' },
  { value: 'due_today', label: 'Due today' },
  { value: 'due_7', label: 'Due within 7 days' },
  { value: 'due_15', label: 'Due within 15 days' },
  { value: 'due_30', label: 'Due within 30 days' },
  { value: 'due_60', label: 'Due within 60 days' },
  { value: 'valid', label: 'Later / current' },
  { value: 'unknown', label: 'Unknown due date' },
]

const MAPPING_STATES = [
  { value: '', label: 'Any mapping status' },
  { value: 'resolved', label: 'Resolved' },
  { value: 'needs_station_mapping', label: 'Needs station mapping' },
  { value: 'needs_unit_mapping', label: 'Needs unit mapping' },
  { value: 'needs_equipment_mapping', label: 'Needs equipment mapping' },
  { value: 'conflict', label: 'Conflict' },
]

/**
 * The report filter bar.
 *
 * DRAFT AND APPLIED ARE SEPARATE. Typing edits a draft; Apply commits it. A
 * report query counts rows across five asset families, so firing one per
 * keystroke would be wasteful and would make the summary flicker between
 * answers to different questions. The search box additionally debounces, so a
 * person who types and then presses Apply is never waiting on a stale request.
 *
 * DEPENDENT BY CONSTRUCTION. Choosing a Region clears the Station and Unit;
 * choosing a Station clears the Unit. A Station/Unit pair that never existed is
 * therefore not expressible from this bar — and could not be read even if it
 * were, because RLS and the composite hierarchy decide, not this component.
 */
export function ReportFiltersBar({
  spec, applied, onApply,
}: {
  spec: ReportSpec
  applied: ReportFilterValues
  onApply: (next: ReportFilterValues) => void
}) {
  // The draft is stored WITH the applied state it was seeded from, so both
  // resets — applying the filters, and switching report — happen by derivation
  // during render rather than in an effect that would cascade a second render.
  // A Unit filter from the SRV report means nothing on the warehouse report,
  // which has no Unit column at all.
  const seed = useMemo(() => JSON.stringify([spec.id, applied]), [spec.id, applied])
  const [draftState, setDraftState] = useState({ seed, values: applied })
  const draft = draftState.seed === seed ? draftState.values : applied

  const regions = useRegionOptions()
  const stations = useStationOptions(draft.region)
  const units = useUnitOptions(draft.station)

  const has = (key: string) => spec.filters.includes(key as never)
  const set = (patch: Partial<ReportFilterValues>) =>
    setDraftState({ seed, values: { ...draft, ...patch } })
  const dirty = JSON.stringify(draft) !== JSON.stringify(applied)
  const filtered = JSON.stringify(applied) !== JSON.stringify(EMPTY_FILTERS)
  const controlId = (field: string) => `report-${spec.id}-${field}`

  return (
    <form
      onSubmit={(e) => { e.preventDefault(); onApply(draft) }}
      onReset={(e) => {
        e.preventDefault()
        setDraftState({ seed, values: EMPTY_FILTERS })
        onApply(EMPTY_FILTERS)
      }}
    >
      <DataToolbar label={`Filter the ${spec.label} report`}>
        {/* Each may hold several values, or exclude them ("All except"); see multiFilter.ts. */}
        {has('region') ? (
          <MultiSelectFilter id={controlId('region')} label="Region" allLabel="Every Region" value={draft.region}
                             onChange={(region) => set({ region, station: '', unit: '' })}
                             options={regions.map((r) => ({ value: r.id, label: r.label }))} />
        ) : null}

        {/* Stations are offered once a Region is chosen, Units once a Station is: a pair the hierarchy does not
          * support is never offered. */}
        {has('station') && draft.region !== '' ? (
          <MultiSelectFilter id={controlId('station')} label="Station" allLabel="Every Station" value={draft.station}
                             onChange={(station) => set({ station, unit: '' })}
                             options={stations.map((s) => ({ value: s.id, label: s.label }))} />
        ) : null}

        {has('unit') && draft.station !== '' ? (
          <MultiSelectFilter id={controlId('unit')} label="Unit" allLabel="Every Unit" value={draft.unit}
                             onChange={(unit) => set({ unit })} options={units.map((u) => ({ value: u.id, label: u.label }))} />
        ) : null}

        {has('assetType') && spec.assetTypeOptions ? (
          <MultiSelectFilter id={controlId('asset')} label="Asset type" allLabel="Every asset type" value={draft.assetType}
                             onChange={(assetType) => set({ assetType })} options={spec.assetTypeOptions} />
        ) : null}

        {has('dueState') ? (
          <MultiSelectFilter id={controlId('due')} label="Due state" allLabel="Any due state" value={draft.dueState}
                             onChange={(dueState) => set({ dueState })} options={DUE_STATES.filter((o) => o.value !== '')} />
        ) : null}

        {has('mappingStatus') ? (
          <Field label="Mapping status" htmlFor={controlId('mapping')}>
            <select
              id={controlId('mapping')} name={controlId('mapping')} value={draft.mappingStatus}
              onChange={(e) => set({ mappingStatus: e.target.value })}
              className="h-7 rounded border bg-background px-1 text-xs"
            >
              {MAPPING_STATES.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </Field>
        ) : null}

        {has('dateRange') ? (
          <Field label="Day" htmlFor={controlId('day')}>
            <input
              id={controlId('day')} name={controlId('day')} type="date" value={draft.from === draft.to ? draft.from : ''}
              onChange={(e) => set({ from: e.target.value, to: e.target.value })}
              className="h-7 rounded border bg-background px-1 text-xs"
            />
          </Field>
        ) : null}

        {has('search') ? (
          <Field label="Search" htmlFor={controlId('search')}>
            <DebouncedSearch
              id={controlId('search')}
              value={draft.search}
              onChange={(v) => set({ search: v })}
              placeholder="Serial, Job No. or Station"
            />
          </Field>
        ) : null}

        <div className="flex items-end gap-2">
          <Button type="submit" size="sm" disabled={!dirty}>Apply</Button>
          <Button type="reset" size="sm" variant="outline" disabled={!dirty && !filtered}>
            Clear
          </Button>
        </div>
      </DataToolbar>
    </form>
  )
}

/**
 * A debounced search box.
 *
 * The typed value is local and immediate, so the field never feels laggy; the
 * value handed upward settles 300ms after typing stops. Apply is still an
 * explicit act — the debounce only keeps the draft from churning.
 */
function DebouncedSearch({
  id, value, onChange, placeholder,
}: { id: string; value: string; onChange: (v: string) => void; placeholder: string }) {
  // Same technique: the typed text is stored with the value it was seeded from,
  // so an external reset (Clear, or a report switch) is picked up by derivation.
  const [local, setLocal] = useState({ seed: value, text: value })
  const text = local.seed === value ? local.text : value
  useEffect(() => {
    if (text === value) return
    const timer = setTimeout(() => onChange(text), 300)
    return () => clearTimeout(timer)
  }, [text, value, onChange])
  return (
    <input
      id={id} name={id} type="search" value={text}
      onChange={(e) => setLocal({ seed: value, text: e.target.value })}
      placeholder={placeholder}
      className="h-7 w-56 rounded border bg-background px-1 text-xs"
    />
  )
}

function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <label className="text-xs font-medium" htmlFor={htmlFor}>{label}</label>
      {children}
    </div>
  )
}
