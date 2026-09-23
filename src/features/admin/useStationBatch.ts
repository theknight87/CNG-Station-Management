import { useCallback, useEffect, useState } from 'react'

import { useSupabaseClient } from '@/lib/supabase/client'

/**
 * The approved Stage B Station batch — one specific, already-reviewed batch.
 *
 * WHY THIS EXISTS AT ALL. `cng_stage_b_station_commit` derives its actor from
 * the verified Clerk subject via `cng_require_admin()`, because
 * `import_mapping_decisions.decided_by` is NOT NULL and a mapping decision must
 * name the human who made it (CLAUDE.md §9, §10). An operator connection has no
 * Clerk subject, so the batch can only be run from a real authenticated Admin
 * session. This hook is that session's path to it — nothing more.
 *
 * It is NOT a general mapping tool. The run, both fingerprints and the expected
 * shape are fixed constants below, and the control only unlocks when the LIVE
 * server preview equals every one of them.
 *
 * NOTHING HERE IS THE SECURITY. The database re-derives the candidate set and
 * both fingerprints inside the commit's own transaction and refuses on any
 * drift; a user who edits this file out of the bundle gains exactly nothing.
 * These guards exist so a person is not offered a button that would fail, and
 * so an accidental click cannot become a 281-row write.
 */

/**
 * One reviewed, content-bound batch. The screen and the hook are generic over
 * it; the DATABASE re-derives and enforces every value regardless.
 */
export interface BatchConfig {
  /** Stable key, used for element ids. */
  key: string
  title: string
  previewRpc: 'cng_stage_b_station_preview' | 'cng_stage_b2_station_preview'
  commitRpc: 'cng_stage_b_station_commit' | 'cng_stage_b2_station_commit'
  importRunId: string
  manifestFingerprint: string
  previewFingerprint: string
  groups: number
  rows: number
  reason: string
  /** The exact phrase an Admin must type. Deliberately not paraphrasable. */
  confirmPhrase: string
  /** What the rows move FROM, in words, for the confirmation text. */
  fromStatus: string
  /** What the batch does and does not do, shown before confirmation. */
  scope: readonly string[]
}

/** The batch the owner approved in Prompt 22C. Committed 2026-09-18 (Prompt 22D). */
export const APPROVED_BATCH: BatchConfig = {
  key: 'stage-b',
  title: 'Approved Station Mapping Batch',
  previewRpc: 'cng_stage_b_station_preview',
  commitRpc: 'cng_stage_b_station_commit',
  importRunId: 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64',
  manifestFingerprint: '764d3c0fbe09f3ac95b27ce235f0fb08cfd92711e2a4ec56defb227b5f091b8f',
  previewFingerprint: 'a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769',
  groups: 69,
  rows: 281,
  reason: 'Prompt 22C approved Stage B Station batch',
  confirmPhrase: 'CONFIRM 281 STATION MAPPINGS',
  fromStatus: 'Needs Station Mapping',
  scope: [
    'Confirms the canonical Station for each staged row, and nothing else.',
    'No Unit is assigned.',
    'No equipment is mapped.',
    'No canonical asset is imported.',
    'No alias is created.',
    'The remaining 823 unmatched rows are untouched.',
  ],
}

/**
 * Stage B2 (Phase 6, 2026-09-23): the 308 four-family rows whose PIPELINE-ERA
 * status (`resolved` 268 / `needs_unit_mapping` 40) claimed more than the
 * evidence proves. Their staged Unit came from the forbidden one-Unit
 * inference, so they are confirmed at Station level only. The fingerprint is
 * the DEPLOYED function's, read twice identically on 2026-09-23.
 */
export const STAGE_B2_BATCH: BatchConfig = {
  key: 'stage-b2',
  title: 'Station Mapping Batch B2 — rows with an unproven staged Unit',
  previewRpc: 'cng_stage_b2_station_preview',
  commitRpc: 'cng_stage_b2_station_commit',
  importRunId: 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64',
  manifestFingerprint: '764d3c0fbe09f3ac95b27ce235f0fb08cfd92711e2a4ec56defb227b5f091b8f',
  previewFingerprint: '9ff0975c9e3c5a9fd09869cd91317183099610402bbc5449ccdbecea0616c990',
  groups: 62,
  rows: 308,
  reason: 'Phase 6 Stage B2 Station-only batch (staged Unit from one-Unit inference discarded)',
  confirmPhrase: 'CONFIRM 308 STATION MAPPINGS',
  fromStatus: 'their pipeline-era staged status (Resolved or Needs Unit Mapping)',
  scope: [
    'Confirms the canonical Station for each staged row, and nothing else.',
    'The staged Unit is DISCARDED: it came from "the Station has one Unit", which is not evidence. No Unit is assigned.',
    'No equipment is mapped.',
    'No canonical asset is imported by this step.',
    'No alias is created.',
    '28 rows are recorded detector ABSENCE; they get a Station decision but will never become detector records.',
  ],
}

/** Stage B's phrase, kept as a named export for existing callers. */
export const CONFIRM_PHRASE = APPROVED_BATCH.confirmPhrase

export interface StationBatchPreview {
  import_run_id: string
  manifest_fingerprint: string | null
  preview_fingerprint: string
  candidate_groups: number
  candidate_rows: number
  deterministic_groups: number
  owner_review_groups: number
  rows_with_existing_decision: number
  storage_vessels: number
  recovery_tanks: number
  gas_detectors: number
  hoses: number
  canonical_stations: number
  canonical_units: number
  existing_decisions: number
}

export interface CommitResult {
  import_run_id: string
  decisions_written: number
  rows_confirmed: number
  groups_confirmed: number
  preview_fingerprint: string
}

/**
 * The guard, derived ENTIRELY from what the server currently reports.
 *
 * `already_executed` is a SERVER fact, not a remembered one: once the batch has
 * run, every candidate row carries an active decision, which the preview
 * reports. So a page refresh — or a different browser, or another Admin — sees
 * the completed state too, and nothing in `localStorage` can resurrect the
 * button.
 */
export type BatchGuard =
  | { kind: 'loading' }
  | { kind: 'load_error'; message: string }
  | { kind: 'ready'; preview: StationBatchPreview }
  | { kind: 'already_executed'; preview: StationBatchPreview }
  | { kind: 'blocked'; preview: StationBatchPreview; reasons: string[] }

/**
 * The execution state.
 *
 * `uncertain` is the important one. A 281-row write whose outcome is unknown
 * must never be retried on a guess: the database is the only thing that can say
 * whether it happened, so the UI stops, says so, and offers a read-only check.
 */
export type BatchRun =
  | { kind: 'idle' }
  | { kind: 'submitting' }
  | { kind: 'succeeded'; result: CommitResult }
  | { kind: 'refused'; message: string }
  | { kind: 'uncertain'; detail: string }
  | { kind: 'verified_committed'; rows: number }
  | { kind: 'verified_not_executed' }
  | { kind: 'verified_unexpected'; detail: string }

/**
 * Compares the LIVE preview against the approved batch.
 *
 * Every mismatch is listed rather than the first one, because an Admin deciding
 * whether something drifted needs to see what drifted.
 */
export function evaluateGuard(preview: StationBatchPreview, batch: BatchConfig = APPROVED_BATCH): BatchGuard {
  // Already run? Every approved row now carries an active decision.
  if (preview.rows_with_existing_decision >= batch.rows) {
    return { kind: 'already_executed', preview }
  }

  const reasons: string[] = []
  if (preview.import_run_id !== batch.importRunId) {
    reasons.push('The import run is not the approved one.')
  }
  if (preview.manifest_fingerprint !== batch.manifestFingerprint) {
    reasons.push('The manifest fingerprint no longer matches the approved source content.')
  }
  if (preview.preview_fingerprint !== batch.previewFingerprint) {
    reasons.push('The preview fingerprint no longer matches the approved proposal.')
  }
  if (preview.candidate_groups !== batch.groups) {
    reasons.push(`The batch now proposes ${preview.candidate_groups} Station groups, not ${batch.groups}.`)
  }
  if (preview.candidate_rows !== batch.rows) {
    reasons.push(`The batch now covers ${preview.candidate_rows} staged rows, not ${batch.rows}.`)
  }
  if (preview.owner_review_groups > 0) {
    reasons.push(`${preview.owner_review_groups} groups now need owner review and are not part of an approved deterministic batch.`)
  }
  // A partial decision state is neither "ready" nor "already executed".
  if (preview.rows_with_existing_decision > 0) {
    reasons.push(`${preview.rows_with_existing_decision} rows already carry a mapping decision.`)
  }

  if (reasons.length > 0) return { kind: 'blocked', preview, reasons }
  return { kind: 'ready', preview }
}

/**
 * Tells a DATABASE REFUSAL from a TRANSPORT FAILURE, and errs toward uncertain.
 *
 * A refusal carries a PostgreSQL SQLSTATE: the server was reached, it decided,
 * and nothing was written. Anything else — a dropped socket, a proxy, a timeout,
 * an error with no code — leaves the outcome genuinely unknown, and guessing
 * "it failed" is how a batch gets run twice.
 */
export function classifyRpcError(error: { code?: string | null; message?: string } | null): 'refused' | 'uncertain' {
  const code = error?.code ?? ''
  return /^[0-9A-Z]{5}$/.test(code) ? 'refused' : 'uncertain'
}

export function useStationBatch(batch: BatchConfig = APPROVED_BATCH): {
  guard: BatchGuard
  run: BatchRun
  execute: () => Promise<void>
  verify: () => Promise<void>
  refresh: () => void
} {
  const supabase = useSupabaseClient()
  const [guard, setGuard] = useState<BatchGuard>({ kind: 'loading' })
  const [run, setRun] = useState<BatchRun>({ kind: 'idle' })
  const [nonce, setNonce] = useState(0)

  const loadPreview = useCallback(async (): Promise<StationBatchPreview | null> => {
    if (!supabase) return null
    const { data, error } = await supabase
      .rpc(batch.previewRpc, { p_import_run_id: batch.importRunId })
      .maybeSingle()
    if (error) {
      setGuard({ kind: 'load_error', message: error.message })
      return null
    }
    if (!data) {
      setGuard({ kind: 'load_error', message: 'The server returned no preview for the approved batch.' })
      return null
    }
    return data as StationBatchPreview
  }, [supabase, batch])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      const preview = await loadPreview()
      if (cancelled || !preview) return
      setGuard(evaluateGuard(preview, batch))
    })()
    return () => { cancelled = true }
  }, [loadPreview, nonce, batch])

  const execute = useCallback(async () => {
    if (!supabase) return
    // Locks the control for the rest of this page's life. Re-enabling only ever
    // happens by re-reading the server, never by a local flag.
    setRun({ kind: 'submitting' })
    try {
      const { data, error } = await supabase.rpc(batch.commitRpc, {
        p_import_run_id: batch.importRunId,
        p_expected_manifest_fingerprint: batch.manifestFingerprint,
        p_expected_preview_fingerprint: batch.previewFingerprint,
        p_reason: batch.reason,
      })
      if (error) {
        if (classifyRpcError(error) === 'refused') {
          setRun({ kind: 'refused', message: error.message })
        } else {
          setRun({ kind: 'uncertain', detail: error.message })
        }
        return
      }
      const row = (Array.isArray(data) ? data[0] : data) as CommitResult | undefined
      if (!row || typeof row.decisions_written !== 'number') {
        setRun({ kind: 'uncertain', detail: 'The server returned no readable result.' })
        return
      }
      setRun({ kind: 'succeeded', result: row })
      setNonce((n) => n + 1)
    } catch (thrown) {
      // A throw is a transport failure by definition: the request may or may not
      // have reached the database. NEVER retry from here.
      setRun({ kind: 'uncertain', detail: thrown instanceof Error ? thrown.message : 'The request did not complete.' })
    }
  }, [supabase, batch])

  /** Read-only outcome check after an uncertain result. Writes nothing. */
  const verify = useCallback(async () => {
    const preview = await loadPreview()
    if (!preview) return
    const decided = preview.rows_with_existing_decision
    if (decided >= batch.rows) {
      setRun({ kind: 'verified_committed', rows: decided })
    } else if (decided === 0 && preview.preview_fingerprint === batch.previewFingerprint) {
      setRun({ kind: 'verified_not_executed' })
    } else {
      setRun({
        kind: 'verified_unexpected',
        detail: `${decided} of ${batch.rows} rows carry a decision. This is neither a completed batch nor an untouched one.`,
      })
    }
    setGuard(evaluateGuard(preview, batch))
  }, [loadPreview, batch])

  const refresh = useCallback(() => setNonce((n) => n + 1), [])

  return { guard, run, execute, verify, refresh }
}
