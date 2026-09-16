import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { StatusBadge } from '@/components/data/StatusBadge'
import { DataToolbar, SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import type { SrvParentKind } from '@/types/domain'
import {
  EMPTY_QUEUE_FILTERS, PRE_IMPORT_TARGETS, useAdminDataQuality, useMappingQueues,
  useStagedMappingDecision, type QueueFilters, type SrvQueueRow, type StagedQueueRow,
} from '../useAdminDataQuality'
import { useEquipment, useRegions, useStations, useUnits } from '../useMappingOptions'

const PARENT_KINDS: SrvParentKind[] = ['compressor', 'storage_vessel', 'dispenser']

const SRV_STATUSES = [
  { value: '', label: 'Every unresolved status' },
  { value: 'needs_station_mapping', label: 'Needs station mapping' },
  { value: 'needs_unit_mapping', label: 'Needs unit mapping' },
  { value: 'needs_equipment_mapping', label: 'Needs equipment mapping' },
  { value: 'conflict', label: 'Conflict' },
]

const STAGED_STATUSES = [
  { value: '', label: 'Every unresolved status' },
  { value: 'needs_station_mapping', label: 'Needs station mapping' },
  { value: 'needs_unit_mapping', label: 'Needs unit mapping' },
  { value: 'conflict', label: 'Conflict' },
]

/**
 * Data quality: the counts, and the five working queues.
 *
 * TWO STAGES OF ONE JOB, DELIBERATELY NOT MERGED.
 *
 *   * Installed SRVs are STORED records. Their canonical `station_id` is
 *     nullable, so they import unresolved and are mapped in the asset table.
 *   * Storage Vessels, Recovery Tanks, Gas Detectors and Hoses are not records
 *     yet. Their canonical `station_id` is NOT NULL, so a row with no proven
 *     Station cannot be stored at all — and the answer is to confirm the Station
 *     BEFORE the import, on the staging row, not to relax the column.
 *
 * RAW, CANDIDATE and CONFIRMED are three separate columns in every staged row.
 * A candidate is a similarity proposal and is labelled as one; it is never
 * rendered in the confirmed column and never pre-selected.
 *
 * NO COUNT IS HARD-CODED. Every figure is counted live.
 */
export function AdminDataQualitySection() {
  const { queues, loadError: countError, actionError, busy, mapSrv } = useAdminDataQuality()
  const [filters, setFilters] = useState<QueueFilters>(EMPTY_QUEUE_FILTERS)
  const queue = useMappingQueues(filters)
  const staged = useStagedMappingDecision()
  const [openRow, setOpenRow] = useState<string | null>(null)
  const regions = useRegions()

  const set = (patch: Partial<QueueFilters>) => {
    setOpenRow(null)
    setFilters({ ...filters, ...patch })
  }

  const open = (queues ?? []).filter((q) => q.open_count > 0)
  const selectedSrv = (queue.srvRows ?? []).find((r) => r.id === openRow) ?? null
  const selectedStaged = (queue.stagedRows ?? []).find((r) => r.staging_row_id === openRow) ?? null

  return (
    <div className="space-y-6">
      <section className="space-y-3" aria-labelledby="admin-dq-heading">
        <SectionHeader
          id="admin-dq-heading"
          title="Open data-quality queues"
          description="Records the source did not fully prove — stored assets awaiting mapping, and staged rows awaiting a pre-import decision. Counted live; nothing here is a remembered figure."
        />
        {countError ? (
          <ErrorState title="The data-quality queues could not be loaded" message={countError} />
        ) : !queues ? (
          <LoadingState label="Loading data quality" />
        ) : open.length === 0 ? (
          <EmptyState
            title="No open data-quality queues"
            description="Every stored asset and every staged row has the hierarchy its source proved. This is counted from live data, not assumed."
          />
        ) : (
          <TableScroll label="Open data-quality queues">
            <DataTable caption="Open data-quality queues, counted from live data">
              <TableHead>
                <TableRow>
                  <TableHeader>Asset</TableHeader>
                  <TableHeader>Queue</TableHeader>
                  <TableHeader align="right">Open</TableHeader>
                </TableRow>
              </TableHead>
              <TableBody>
                {open.map((q) => (
                  <TableRow key={`${q.asset}:${q.queue}`}>
                    <TableCell>{q.asset}</TableCell>
                    <TableCell>{q.queue}</TableCell>
                    <TableCell align="right" numeric>{q.open_count.toLocaleString()}</TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </DataTable>
          </TableScroll>
        )}
      </section>

      <section className="space-y-3" aria-labelledby="admin-map-heading">
        <SectionHeader
          id="admin-map-heading"
          title="Mapping queue"
          description="One record per row, with the source evidence a human needs. Nothing here proposes a mapping: a similarity candidate is shown as a candidate and confirms nothing."
        />

        <DataToolbar label="Filter the mapping queue">
          <Field label="Asset type" htmlFor="q-asset">
            <select
              id="q-asset" value={filters.assetType}
              onChange={(e) => set({ assetType: e.target.value as QueueFilters['assetType'] })}
              className="h-7 rounded border bg-background px-1 text-xs"
            >
              <option value="">Installed SRV (stored)</option>
              {PRE_IMPORT_TARGETS.map((t) => (
                <option key={t.value} value={t.value}>{t.label} (staged, pre-import)</option>
              ))}
            </select>
          </Field>
          <Field label="Mapping status" htmlFor="q-status">
            <select
              id="q-status" value={filters.mappingStatus}
              onChange={(e) => set({ mappingStatus: e.target.value })}
              className="h-7 rounded border bg-background px-1 text-xs"
            >
              {(filters.assetType === '' ? SRV_STATUSES : STAGED_STATUSES).map((o) => (
                <option key={o.value} value={o.value}>{o.label}</option>
              ))}
            </select>
          </Field>
          <Field label={filters.assetType === '' ? 'Region' : 'Region (from source)'} htmlFor="q-region">
            <select
              id="q-region" value={filters.region}
              onChange={(e) => set({ region: e.target.value })}
              className="h-7 rounded border bg-background px-1 text-xs"
            >
              <option value="">Every Region</option>
              {(filters.assetType === ''
                ? regions.map((r) => ({ value: r.id, label: r.label }))
                : regions.map((r) => ({ value: r.label, label: r.label }))
              ).map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
            </select>
          </Field>
          <Field label="Station search" htmlFor="q-station">
            <input
              id="q-station" type="search" value={filters.stationSearch}
              onChange={(e) => set({ stationSearch: e.target.value })}
              placeholder="name or raw source name"
              className="h-7 w-56 rounded border bg-background px-1 text-xs"
            />
          </Field>
          {JSON.stringify(filters) !== JSON.stringify(EMPTY_QUEUE_FILTERS) ? (
            <Button type="button" variant="outline" size="sm"
                    onClick={() => setFilters(EMPTY_QUEUE_FILTERS)}>
              Clear filters
            </Button>
          ) : null}
        </DataToolbar>

        {actionError ? <ErrorState title="That mapping was refused" message={actionError} /> : null}
        {staged.actionError ? (
          <ErrorState title="That decision was refused" message={staged.actionError} />
        ) : null}

        {queue.loadError ? (
          <ErrorState title="The mapping queue could not be loaded" message={queue.loadError} />
        ) : filters.assetType === '' ? (
          <SrvQueue
            rows={queue.srvRows}
            openRow={openRow}
            onToggle={(id) => setOpenRow(openRow === id ? null : id)}
          />
        ) : (
          <StagedQueue
            rows={queue.stagedRows}
            openRow={openRow}
            onToggle={(id) => setOpenRow(openRow === id ? null : id)}
          />
        )}

        {selectedSrv ? (
          <SrvMappingForm
            key={selectedSrv.id}
            row={selectedSrv}
            busy={busy}
            onSubmit={async (decision) => {
              const ok = await mapSrv(selectedSrv, decision)
              if (ok) { setOpenRow(null); queue.reload() }
            }}
          />
        ) : null}

        {selectedStaged ? (
          <StagedMappingForm
            key={selectedStaged.staging_row_id}
            row={selectedStaged}
            busy={staged.busy}
            onSubmit={async (stationId, unitId, reason) => {
              const ok = await staged.decide(selectedStaged, stationId, unitId, reason)
              if (ok) { setOpenRow(null); queue.reload() }
            }}
          />
        ) : null}

        {queue.srvRows || queue.stagedRows ? (
          <div className="flex items-center gap-3">
            <span className="text-xs text-muted-foreground">
              Showing{' '}
              <span className="tabular">
                {(queue.srvRows ?? queue.stagedRows ?? []).length}
              </span>{' '}
              records
              {queue.hasMore ? ', more available' : ' — this is the whole queue under these filters'}
            </span>
            {queue.hasMore ? (
              <Button type="button" variant="outline" size="sm"
                      disabled={queue.loading} onClick={queue.loadMore}>
                Load more
              </Button>
            ) : null}
          </div>
        ) : null}
      </section>
    </div>
  )
}

// ---------------------------------------------------------------------------
// The stored installed-SRV queue
// ---------------------------------------------------------------------------

function SrvQueue({
  rows, openRow, onToggle,
}: { rows: SrvQueueRow[] | null; openRow: string | null; onToggle: (id: string) => void }) {
  if (!rows) return <LoadingState label="Loading the SRV queue" />
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No unresolved relief valves"
        description="Every stored SRV has a confirmed Station, Unit and equipment parent."
      />
    )
  }
  return (
    <TableScroll label="Installed SRV mapping queue">
      <DataTable caption="Unresolved installed relief valves, with their source evidence">
        <TableHead>
          <TableRow>
            <TableHeader>Mapping status</TableHeader>
            <TableHeader>Source Station (raw)</TableHeader>
            <TableHeader>Confirmed Station</TableHeader>
            <TableHeader>Confirmed Unit</TableHeader>
            <TableHeader>Serial</TableHeader>
            <TableHeader>Location hint</TableHeader>
            <TableHeader>Source</TableHeader>
            <TableHeader>Resolve</TableHeader>
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.id} selected={openRow === row.id}>
              <TableCell>{row.mapping_status}</TableCell>
              <TableCell>{row.source_station_name_raw ?? <NullValue />}</TableCell>
              <TableCell>{row.station_name ?? <NullValue />}</TableCell>
              <TableCell>{row.unit_name ?? <NullValue />}</TableCell>
              <TableCell>{row.serial_number ?? row.serial_number_raw ?? <NullValue />}</TableCell>
              <TableCell>
                {row.expected_parent_kind ? (
                  <span title="A hint from the source Location column. It narrows the choices; it never selects a parent.">
                    {row.expected_parent_kind}
                  </span>
                ) : <NullValue />}
              </TableCell>
              <TableCell className="text-xs text-muted-foreground">
                {row.source_file ?? <NullValue />}
                {row.source_row === null ? null : ` r${row.source_row}`}
              </TableCell>
              <TableCell>
                <Button
                  type="button" variant="outline" size="sm"
                  aria-label={`${openRow === row.id ? 'Cancel resolving' : 'Resolve'} relief valve ${row.serial_number ?? row.id}`}
                  onClick={() => onToggle(row.id)}
                >
                  {openRow === row.id ? 'Cancel' : 'Resolve'}
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </DataTable>
    </TableScroll>
  )
}

// ---------------------------------------------------------------------------
// The pre-import staged queue
// ---------------------------------------------------------------------------

function StagedQueue({
  rows, openRow, onToggle,
}: { rows: StagedQueueRow[] | null; openRow: string | null; onToggle: (id: string) => void }) {
  if (!rows) return <LoadingState label="Loading the pre-import queue" />
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No staged rows awaiting a decision"
        description="Nothing of this asset type is staged unresolved. A production import has not been run, so this is expected until Prompt 21."
      />
    )
  }
  return (
    <TableScroll label="Pre-import mapping queue">
      <DataTable caption="Staged rows awaiting a pre-import mapping decision, with raw source evidence, automated candidates and any confirmed decision">
        <TableHead>
          <TableRow>
            <TableHeader>Staged status</TableHeader>
            <TableHeader>Raw Region</TableHeader>
            <TableHeader>Raw Station</TableHeader>
            <TableHeader>Raw location</TableHeader>
            <TableHeader>Serial</TableHeader>
            <TableHeader>Manufacturer</TableHeader>
            <TableHeader>Model</TableHeader>
            <TableHeader>Source</TableHeader>
            <TableHeader>Candidate</TableHeader>
            <TableHeader>Confirmed</TableHeader>
            <TableHeader>Decide</TableHeader>
          </TableRow>
        </TableHead>
        <TableBody>
          {rows.map((row) => (
            <TableRow key={row.staging_row_id} selected={openRow === row.staging_row_id}>
              <TableCell>{row.staged_mapping_status}</TableCell>
              <TableCell>{row.raw_region ?? <NullValue />}</TableCell>
              <TableCell>{row.raw_station ?? <NullValue />}</TableCell>
              <TableCell>{row.raw_location ?? <NullValue />}</TableCell>
              <TableCell>{row.serial_number ?? row.raw_serial ?? <NullValue />}</TableCell>
              <TableCell>{row.manufacturer ?? row.raw_manufacturer ?? <NullValue />}</TableCell>
              <TableCell>{row.model ?? row.raw_model ?? <NullValue />}</TableCell>
              <TableCell className="text-xs text-muted-foreground">
                {row.source_file} · {row.source_sheet} · r{row.source_row}
              </TableCell>
              <TableCell>
                <CandidateCell row={row} />
              </TableCell>
              <TableCell>
                <ConfirmedCell row={row} />
              </TableCell>
              <TableCell>
                <Button
                  type="button" variant="outline" size="sm"
                  aria-label={`${
                    openRow === row.staging_row_id
                      ? 'Cancel deciding'
                      : row.decision_id ? 'Change decision for' : 'Decide'
                  } staged row ${row.source_row_key}`}
                  onClick={() => onToggle(row.staging_row_id)}
                >
                  {openRow === row.staging_row_id
                    ? 'Cancel'
                    : row.decision_id ? 'Change' : 'Decide'}
                </Button>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </DataTable>
    </TableScroll>
  )
}

/**
 * A CANDIDATE. Rendered in the neutral treatment with the word "suggested" and
 * its score, never with a status colour — a proposal that looks like a
 * confirmation is how a guess becomes a fact.
 */
function CandidateCell({ row }: { row: StagedQueueRow }) {
  const top = (row.candidate_proposals ?? [])[0]
  if (!top?.name) {
    return <span className="text-xs text-muted-foreground">No suggestion</span>
  }
  return (
    <span className="inline-flex items-center gap-1 rounded border border-dashed px-1 text-xs text-muted-foreground">
      <span>Suggested: {top.name}</span>
      {typeof top.score === 'number' ? (
        <span className="tabular">{top.score.toFixed(2)}</span>
      ) : null}
      <span className="sr-only">
        — an automated similarity suggestion only. It confirms nothing and is not applied.
      </span>
    </span>
  )
}

/** A CONFIRMED human decision, or the honest absence of one. */
function ConfirmedCell({ row }: { row: StagedQueueRow }) {
  if (!row.decision_id) {
    return (
      <StatusBadge
        kind="unmapped"
        label="Not decided"
        description="No human has confirmed a Station for this row, so the import would hold it"
      />
    )
  }
  return (
    <span className="text-xs">
      <StatusBadge
        kind={row.confirmed_mapping_status === 'resolved' ? 'ok' : 'unmapped'}
        label={row.confirmed_mapping_status === 'resolved' ? 'Station + Unit' : 'Station only'}
        description={
          row.confirmed_mapping_status === 'resolved'
            ? 'A human confirmed both the Station and the Unit'
            : 'A human confirmed the Station; the Unit is genuinely unknown'
        }
      />
      <span className="ml-1">
        {row.confirmed_station_name}
        {row.confirmed_unit_name ? ` · ${row.confirmed_unit_name}` : ''}
      </span>
      {row.decided_by_name ? (
        <span className="ml-1 text-muted-foreground">by {row.decided_by_name}</span>
      ) : null}
    </span>
  )
}

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------

function SrvMappingForm({
  row, busy, onSubmit,
}: {
  row: SrvQueueRow
  busy: boolean
  onSubmit: (decision: {
    stationId: string; unitId: string | null
    parentKind: SrvParentKind | null; parentId: string | null; reason: string
  }) => void | Promise<void>
}) {
  const [stationId, setStationId] = useState(row.station_id ?? '')
  const [unitId, setUnitId] = useState(row.unit_id ?? '')
  const [parentKind, setParentKind] = useState<SrvParentKind | ''>(row.expected_parent_kind ?? '')
  const [parentId, setParentId] = useState('')
  const [reason, setReason] = useState('')

  const stations = useStations()
  const units = useUnits(stationId || null)
  const equipment = useEquipment(parentKind === '' ? null : parentKind, unitId || null)

  return (
    <form
      className="space-y-2 rounded border bg-muted/40 p-2"
      onSubmit={(e) => {
        e.preventDefault()
        void onSubmit({
          stationId,
          unitId: unitId === '' ? null : unitId,
          parentKind: parentId === '' ? null : (parentKind as SrvParentKind),
          parentId: parentId === '' ? null : parentId,
          reason,
        })
      }}
    >
      <p className="text-xs text-muted-foreground">
        Confirm only what the evidence proves. Confirming the Station alone leaves the record
        awaiting its Unit; confirming the Unit leaves it awaiting its equipment. The database
        records the resulting state, and refuses a Unit or a parent that does not belong.
      </p>
      <div className="flex flex-wrap items-end gap-3">
        <Field label="Station" htmlFor={`st-${row.id}`}>
          <select
            id={`st-${row.id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={stationId}
            onChange={(e) => { setStationId(e.target.value); setUnitId(''); setParentId('') }}
          >
            <option value="">Not confirmed</option>
            {stations.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
          </select>
        </Field>
        <Field label="Unit" htmlFor={`un-${row.id}`}>
          <select
            id={`un-${row.id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={unitId} disabled={stationId === ''}
            onChange={(e) => { setUnitId(e.target.value); setParentId('') }}
          >
            <option value="">Not confirmed</option>
            {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
          </select>
        </Field>
        <Field label="Parent kind" htmlFor={`pk-${row.id}`}>
          <select
            id={`pk-${row.id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={parentKind} disabled={unitId === ''}
            onChange={(e) => { setParentKind(e.target.value as SrvParentKind | ''); setParentId('') }}
          >
            <option value="">Not confirmed</option>
            {PARENT_KINDS.map((k) => <option key={k} value={k}>{k}</option>)}
          </select>
        </Field>
        <Field label="Parent equipment" htmlFor={`pe-${row.id}`}>
          <select
            id={`pe-${row.id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={parentId} disabled={parentKind === ''}
            onChange={(e) => setParentId(e.target.value)}
          >
            <option value="">Not confirmed</option>
            {equipment.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
          </select>
        </Field>
        <Field label="Evidence" htmlFor={`rs-${row.id}`}>
          <input
            id={`rs-${row.id}`} type="text" value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="What proved this"
            className="h-7 w-56 rounded border bg-background px-1 text-xs"
          />
        </Field>
        <Button type="submit" size="sm" disabled={busy || stationId === ''}>
          Record decision
        </Button>
      </div>
    </form>
  )
}

function StagedMappingForm({
  row, busy, onSubmit,
}: {
  row: StagedQueueRow
  busy: boolean
  onSubmit: (stationId: string, unitId: string | null, reason: string) => void | Promise<void>
}) {
  const [stationId, setStationId] = useState(row.confirmed_station_id ?? '')
  const [unitId, setUnitId] = useState(row.confirmed_unit_id ?? '')
  const [reason, setReason] = useState('')

  const stations = useStations()
  const units = useUnits(stationId || null)
  const id = row.staging_row_id
  // Hoses are the asset type where Station-only is explicitly a valid end state.
  const unitOptional = row.target_table === 'hoses'

  return (
    <form
      className="space-y-2 rounded border bg-muted/40 p-2"
      onSubmit={(e) => {
        e.preventDefault()
        void onSubmit(stationId, unitId === '' ? null : unitId, reason)
      }}
    >
      <div className="text-xs text-muted-foreground">
        <p>
          <strong>Raw source:</strong> {row.source_file} · {row.source_sheet} · row{' '}
          <span className="tabular">{row.source_row}</span> — Region{' '}
          {row.raw_region ?? 'not stated'}, Station {row.raw_station ?? 'not stated'}. This text is
          preserved exactly and is never changed by a decision.
        </p>
        <p>
          {unitOptional
            ? 'Confirm the Station. The Unit is optional for a hose: leave it unconfirmed where the source genuinely does not prove it.'
            : 'Confirm the Station, and the Unit where the evidence proves it. Leaving the Unit unconfirmed is recorded honestly, not treated as complete.'}
          {' '}A suggestion, if one is shown in the queue, is not a mapping and is never applied.
        </p>
      </div>
      <div className="flex flex-wrap items-end gap-3">
        <Field label="Confirmed Station" htmlFor={`sst-${id}`}>
          <select
            id={`sst-${id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={stationId}
            onChange={(e) => { setStationId(e.target.value); setUnitId('') }}
          >
            <option value="">Not confirmed</option>
            {stations.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
          </select>
        </Field>
        <Field label="Confirmed Unit" htmlFor={`sun-${id}`}>
          <select
            id={`sun-${id}`} className="h-7 rounded border bg-background px-1 text-xs"
            value={unitId} disabled={stationId === ''}
            onChange={(e) => setUnitId(e.target.value)}
          >
            <option value="">Not confirmed</option>
            {units.map((u) => <option key={u.id} value={u.id}>{u.label}</option>)}
          </select>
        </Field>
        <Field label="Evidence" htmlFor={`srs-${id}`}>
          <input
            id={`srs-${id}`} type="text" value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="What proved this"
            className="h-7 w-56 rounded border bg-background px-1 text-xs"
          />
        </Field>
        <Button type="submit" size="sm" disabled={busy || stationId === ''}>
          {row.decision_id ? 'Replace decision' : 'Record decision'}
        </Button>
      </div>
    </form>
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
