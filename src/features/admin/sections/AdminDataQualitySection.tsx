import { useState } from 'react'

import {
  DataTable, TableBody, TableCell, TableHead, TableHeader, TableRow, TableScroll,
} from '@/components/data/DataTable'
import { NullValue } from '@/components/data/NullValue'
import { SectionHeader } from '@/components/layout/PageContainer'
import { EmptyState, ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import type { SrvParentKind } from '@/types/domain'
import { useAdminDataQuality, type SrvQueueRow } from '../useAdminDataQuality'
import { useEquipment, useStations, useUnits } from '../useMappingOptions'

const PARENT_KINDS: SrvParentKind[] = ['compressor', 'storage_vessel', 'dispenser']

/**
 * Data quality, and the manual SRV mapping workflow.
 *
 * COUNTS COME FROM THE DATA. Nothing on this screen is a remembered figure from
 * a dry run: `v_admin_data_quality` counts live rows, so a resolved record
 * leaves the queue and a genuine zero reads as zero.
 *
 * THE HIERARCHY IS NOT SKIPPABLE. Station, then Unit, then equipment — each
 * offered only once the level above is confirmed. The resulting mapping_status
 * is derived in SQL from how far the decision actually goes, so this form cannot
 * declare a record resolved by asserting it, and the composite foreign keys
 * reject an impossible parent whatever the form offers.
 */
export function AdminDataQualitySection() {
  const { queues, srvQueue, loadError, actionError, busy, mapSrv } = useAdminDataQuality()
  const [openRow, setOpenRow] = useState<string | null>(null)

  if (loadError) {
    return <ErrorState title="The data-quality queues could not be loaded" message={loadError} />
  }
  if (!queues || !srvQueue) return <LoadingState label="Loading data quality" />

  const open = queues.filter((q) => q.open_count > 0)
  const selected = srvQueue.find((r) => r.id === openRow) ?? null

  return (
    <div className="space-y-6">
      <section className="space-y-3" aria-labelledby="admin-dq-heading">
        <SectionHeader
          id="admin-dq-heading"
          title="Open data-quality queues"
          description="Records the source did not fully prove. They are preserved, visible and searchable — never dropped, and never resolved by a guess."
        />
        {open.length === 0 ? (
          <EmptyState
            title="No open data-quality queues"
            description="Every stored asset has the hierarchy its source proved. This is counted from live data, not assumed."
          />
        ) : (
          <TableScroll label="Open data-quality queues">
            <DataTable caption="Open data-quality queues, counted from live data">
              <TableHead>
                <TableRow>
                  <TableHeader>Asset</TableHeader>
                  <TableHeader>Queue</TableHeader>
                  <TableHeader>Open</TableHeader>
                </TableRow>
              </TableHead>
              <TableBody>
                {open.map((q) => (
                  <TableRow key={`${q.asset}:${q.queue}`}>
                    <TableCell>{q.asset}</TableCell>
                    <TableCell>{q.queue}</TableCell>
                    <TableCell className="tabular">{q.open_count.toLocaleString()}</TableCell>
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
          title="SRV mapping queue"
          description="The source evidence for each unresolved valve, shown raw beside the normalized value. An engineer decides; nothing here proposes a parent."
        />

        {actionError ? (
          <ErrorState title="That mapping was refused" message={actionError} />
        ) : null}

        {srvQueue.length === 0 ? (
          <EmptyState
            title="No unresolved relief valves"
            description="Every stored SRV has a confirmed Station, Unit and equipment parent."
          />
        ) : (
          <TableScroll label="SRV mapping queue">
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
                {srvQueue.map((row) => (
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
                    ) : (
                      <NullValue />
                    )}
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">
                    {row.source_file ?? <NullValue />}
                    {row.source_row === null ? null : ` r${row.source_row}`}
                  </TableCell>
                  <TableCell>
                    <Button
                      type="button" variant="outline" size="sm"
                      onClick={() => setOpenRow(openRow === row.id ? null : row.id)}
                    >
                      {openRow === row.id ? 'Cancel' : 'Resolve'}
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
              </TableBody>
            </DataTable>
          </TableScroll>
        )}

        {selected ? (
          <MappingForm
            key={selected.id}
            row={selected}
            busy={busy}
            onSubmit={async (decision) => {
              const ok = await mapSrv(selected, decision)
              if (ok) setOpenRow(null)
            }}
          />
        ) : null}
      </section>
    </div>
  )
}

function MappingForm({
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
  // The hint pre-selects the KIND of equipment, never a specific record.
  const [parentKind, setParentKind] = useState<SrvParentKind | ''>(row.expected_parent_kind ?? '')
  const [parentId, setParentId] = useState('')
  const [reason, setReason] = useState('')

  const stations = useStations()
  const units = useUnits(stationId || null)
  const equipment = useEquipment(parentKind === '' ? null : parentKind, unitId || null)

  return (
    <form
      className="space-y-2 border-t bg-muted/40 p-2"
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

function Field({ label, htmlFor, children }: { label: string; htmlFor: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-0.5">
      <label className="text-xs font-medium" htmlFor={htmlFor}>{label}</label>
      {children}
    </div>
  )
}
