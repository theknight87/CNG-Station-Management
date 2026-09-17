import { useState } from 'react'

import { SectionHeader } from '@/components/layout/PageContainer'
import { ErrorState, LoadingState } from '@/components/states/AppStates'
import { Button } from '@/components/ui/button'
import {
  APPROVED_BATCH, CONFIRM_PHRASE, useStationBatch,
  type StationBatchPreview,
} from '../useStationBatch'

/**
 * The approved Stage B Station batch — a temporary, single-purpose control.
 *
 * It exists for ONE reason: the commit derives its actor from the verified
 * Clerk subject, so only a real authenticated Admin session can run it. This is
 * that session's path to one already-reviewed batch. It is not a mapping tool,
 * it takes no input that reaches the database, and it will be removed once the
 * batch is committed.
 *
 * THE SCREEN IS NOT THE PROTECTION. Every number shown is re-derived by the
 * database inside the commit's own transaction, which refuses on any drift.
 * What the screen adds is refusing to OFFER an action that would fail, and
 * making an accidental 281-row write impossible.
 */

/** Fingerprints are 64 hex characters; show enough to compare, not to wrap. */
function shortHash(hash: string | null): string {
  if (!hash) return ''
  return `${hash.slice(0, 12)}…${hash.slice(-8)}`
}

function Facts({ preview }: { preview: StationBatchPreview | null }) {
  const rows: Array<[string, string]> = [
    ['Stage', 'Station confirmation'],
    ['Station groups', String(APPROVED_BATCH.groups)],
    ['Staged rows', String(APPROVED_BATCH.rows)],
    ['Expected decisions', String(APPROVED_BATCH.rows)],
    ['Confirmed mapping status', 'Needs Unit Mapping'],
    ['Import run', APPROVED_BATCH.importRunId],
    ['Approved proposal', shortHash(APPROVED_BATCH.previewFingerprint)],
    ['Approved source content', shortHash(APPROVED_BATCH.manifestFingerprint)],
  ]
  if (preview) {
    rows.push(['Live proposal on the server', shortHash(preview.preview_fingerprint)])
    rows.push([
      'Live families',
      `${preview.storage_vessels} storage vessels · ${preview.recovery_tanks} recovery tanks · ` +
      `${preview.gas_detectors} gas detectors · ${preview.hoses} hoses`,
    ])
  }

  return (
    <dl className="grid grid-cols-1 gap-x-6 gap-y-1 text-sm sm:grid-cols-[minmax(0,14rem)_1fr]">
      {rows.map(([label, value]) => (
        <div key={label} className="contents">
          <dt className="text-muted-foreground">{label}</dt>
          <dd className="font-mono text-xs tabular-nums sm:text-sm">{value}</dd>
        </div>
      ))}
    </dl>
  )
}

function Scope() {
  return (
    <ul className="space-y-0.5 text-sm text-muted-foreground">
      <li>Confirms the canonical Station for each staged row, and nothing else.</li>
      <li>No Unit is assigned.</li>
      <li>No equipment is mapped.</li>
      <li>No canonical asset is imported.</li>
      <li>No alias is created.</li>
      <li>The remaining 823 unmatched rows are untouched.</li>
    </ul>
  )
}

export function AdminStationBatchSection() {
  const { guard, run, execute, verify, refresh } = useStationBatch()
  const [dialogOpen, setDialogOpen] = useState(false)
  const [typed, setTyped] = useState('')

  const preview = guard.kind === 'ready' || guard.kind === 'already_executed' || guard.kind === 'blocked'
    ? guard.preview
    : null

  // The control is live ONLY while the server says ready and nothing has been
  // submitted from this page. Every later state is terminal here.
  const canOpenDialog = guard.kind === 'ready' && run.kind === 'idle'
  const phraseMatches = typed === CONFIRM_PHRASE

  return (
    <section aria-labelledby="station-batch-heading" className="space-y-4">
      <SectionHeader
        id="station-batch-heading"
        title="Approved Station Mapping Batch"
        description="A temporary control for one reviewed batch. It confirms Stations only, and is removed once the batch is committed."
      />

      {guard.kind === 'loading' && <LoadingState label="Reading the approved batch from the server" />}

      {guard.kind === 'load_error' && (
        <ErrorState
          title="The approved batch could not be read"
          message={guard.message}
          onRetry={refresh}
        />
      )}

      {preview && (
        <div className="space-y-4 rounded-md border p-4">
          <Facts preview={preview} />
          <Scope />
        </div>
      )}

      {guard.kind === 'blocked' && (
        <div role="alert" className="space-y-2 rounded-md border border-[--status-overdue] p-4">
          <p className="font-medium text-[--status-overdue]">APPROVED BATCH HAS CHANGED — EXECUTION BLOCKED</p>
          <ul className="list-inside list-disc space-y-0.5 text-sm">
            {guard.reasons.map((reason) => <li key={reason}>{reason}</li>)}
          </ul>
          <p className="text-sm text-muted-foreground">
            Nothing has been written. The batch needs re-review and a fresh approval before it can run.
          </p>
        </div>
      )}

      {guard.kind === 'already_executed' && run.kind !== 'succeeded' && (
        <div role="status" className="space-y-1 rounded-md border p-4">
          <p className="font-medium">This batch has already been committed.</p>
          <p className="text-sm text-muted-foreground">
            {preview?.rows_with_existing_decision} staged rows carry an active mapping decision, so there is
            nothing left to confirm. This is read from the server, so it stays true after a refresh.
          </p>
        </div>
      )}

      {guard.kind === 'ready' && (
        <div className="space-y-3">
          <Button
            type="button"
            onClick={() => { setTyped(''); setDialogOpen(true) }}
            disabled={!canOpenDialog}
          >
            Confirm Station Mapping…
          </Button>
          {run.kind !== 'idle' && (
            <p className="text-sm text-muted-foreground">
              This batch has been submitted from this page. The control will not run again here.
            </p>
          )}
        </div>
      )}

      {dialogOpen && (
        <div
          role="dialog"
          aria-modal="true"
          aria-labelledby="station-batch-confirm-heading"
          className="space-y-3 rounded-md border-2 border-[--brand-strong] p-4"
        >
          <h3 id="station-batch-confirm-heading" className="font-medium">
            Confirm the Station mapping for {APPROVED_BATCH.rows} staged rows
          </h3>
          <p className="text-sm">
            This will create {APPROVED_BATCH.rows} mapping decisions and move those rows from
            {' '}Needs Station Mapping to Needs Unit Mapping.
          </p>
          <p className="text-sm text-muted-foreground">
            This does not assign Units or equipment, and does not import canonical assets.
          </p>

          <label htmlFor="station-batch-phrase" className="block text-sm font-medium">
            Type <span className="font-mono">{CONFIRM_PHRASE}</span> to enable the final action
          </label>
          <input
            id="station-batch-phrase"
            type="text"
            autoComplete="off"
            spellCheck={false}
            value={typed}
            onChange={(event) => setTyped(event.target.value)}
            className="w-full max-w-md rounded border bg-background px-2 py-1 font-mono text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[--brand-strong]"
          />

          <div className="flex flex-wrap gap-2">
            <Button
              type="button"
              disabled={!phraseMatches || !canOpenDialog}
              onClick={() => { setDialogOpen(false); void execute() }}
            >
              Confirm Station Mapping
            </Button>
            <Button type="button" variant="outline" onClick={() => setDialogOpen(false)}>
              Cancel
            </Button>
          </div>
        </div>
      )}

      {run.kind === 'submitting' && (
        <div role="status" aria-live="polite">
          <LoadingState label="Confirming the Station mapping — do not close this page" />
        </div>
      )}

      {run.kind === 'refused' && (
        <div role="alert" className="space-y-1 rounded-md border border-[--status-overdue] p-4">
          <p className="font-medium text-[--status-overdue]">The database refused the batch. Nothing was written.</p>
          <p className="text-sm">{run.message}</p>
          <p className="text-sm text-muted-foreground">
            The batch needs re-review. Do not submit again from this page.
          </p>
        </div>
      )}

      {run.kind === 'uncertain' && (
        <div role="alert" className="space-y-2 rounded-md border border-[--status-overdue] p-4">
          <p className="font-medium text-[--status-overdue]">Execution result is uncertain.</p>
          <p className="text-sm">Do not submit again. Production verification is required.</p>
          <p className="text-xs text-muted-foreground">{run.detail}</p>
          <Button type="button" variant="outline" onClick={() => void verify()}>
            Check what actually happened
          </Button>
        </div>
      )}

      {run.kind === 'verified_committed' && (
        <div role="status" className="rounded-md border p-4">
          <p className="font-medium">Verified: the batch was committed.</p>
          <p className="text-sm text-muted-foreground">
            {run.rows} staged rows carry an active mapping decision. Nothing further is required.
          </p>
        </div>
      )}

      {run.kind === 'verified_not_executed' && (
        <div role="status" className="rounded-md border p-4">
          <p className="font-medium">Verified: the batch did not run.</p>
          <p className="text-sm text-muted-foreground">
            No mapping decision exists and the approved proposal is unchanged. Reload this page to try again.
          </p>
        </div>
      )}

      {run.kind === 'verified_unexpected' && (
        <div role="alert" className="rounded-md border border-[--status-overdue] p-4">
          <p className="font-medium text-[--status-overdue]">Unexpected state — stop.</p>
          <p className="text-sm">{run.detail}</p>
          <p className="text-sm text-muted-foreground">Do not submit again. This needs investigation before anything else happens.</p>
        </div>
      )}

      {run.kind === 'succeeded' && (
        <div role="status" className="space-y-1 rounded-md border p-4">
          <p className="font-medium">Station Mapping Batch Completed</p>
          <dl className="grid grid-cols-[minmax(0,14rem)_1fr] gap-x-6 text-sm">
            <dt className="text-muted-foreground">Groups confirmed</dt>
            <dd className="tabular-nums">{run.result.groups_confirmed}</dd>
            <dt className="text-muted-foreground">Rows confirmed</dt>
            <dd className="tabular-nums">{run.result.rows_confirmed}</dd>
            <dt className="text-muted-foreground">Mapping decisions created</dt>
            <dd className="tabular-nums">{run.result.decisions_written}</dd>
            <dt className="text-muted-foreground">Confirmed mapping status</dt>
            <dd>Needs Unit Mapping</dd>
          </dl>
          <p className="text-sm text-muted-foreground">
            No Units were assigned. No equipment was mapped. No canonical assets were imported.
          </p>
        </div>
      )}
    </section>
  )
}
