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

/** The batch the owner approved in Prompt 22C. */
export const APPROVED_BATCH = {
  importRunId: 'cdad1e5e-7faa-4f3b-9432-12a720f3dd64',
  manifestFingerprint: '764d3c0fbe09f3ac95b27ce235f0fb08cfd92711e2a4ec56defb227b5f091b8f',
  previewFingerprint: 'a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769',
  groups: 69,
  rows: 281,
  reason: 'Prompt 22C approved Stage B Station batch',
} as const

/** The exact phrase an Admin must type. Deliberately not paraphrasable. */
export const CONFIRM_PHRASE = 'CONFIRM 281 STATION MAPPINGS'

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
export function evaluateGuard(preview: StationBatchPreview): BatchGuard {
  // Already run? Every approved row now carries an active decision.
  if (preview.rows_with_existing_decision >= APPROVED_BATCH.rows) {
    return { kind: 'already_executed', preview }
  }

  const reasons: string[] = []
  if (preview.import_run_id !== APPROVED_BATCH.importRunId) {
    reasons.push('The import run is not the approved one.')
  }
  if (preview.manifest_fingerprint !== APPROVED_BATCH.manifestFingerprint) {
    reasons.push('The manifest fingerprint no longer matches the approved source content.')
  }
  if (preview.preview_fingerprint !== APPROVED_BATCH.previewFingerprint) {
    reasons.push('The preview fingerprint no longer matches the approved proposal.')
  }
  if (preview.candidate_groups !== APPROVED_BATCH.groups) {
    reasons.push(`The batch now proposes ${preview.candidate_groups} Station groups, not ${APPROVED_BATCH.groups}.`)
  }
  if (preview.candidate_rows !== APPROVED_BATCH.rows) {
    reasons.push(`The batch now covers ${preview.candidate_rows} staged rows, not ${APPROVED_BATCH.rows}.`)
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

export function useStationBatch(): {
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
      .rpc('cng_stage_b_station_preview', { p_import_run_id: APPROVED_BATCH.importRunId })
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
  }, [supabase])

  useEffect(() => {
    let cancelled = false
    void (async () => {
      const preview = await loadPreview()
      if (cancelled || !preview) return
      setGuard(evaluateGuard(preview))
    })()
    return () => { cancelled = true }
  }, [loadPreview, nonce])

  const execute = useCallback(async () => {
    if (!supabase) return
    // Locks the control for the rest of this page's life. Re-enabling only ever
    // happens by re-reading the server, never by a local flag.
    setRun({ kind: 'submitting' })
    try {
      const { data, error } = await supabase.rpc('cng_stage_b_station_commit', {
        p_import_run_id: APPROVED_BATCH.importRunId,
        p_expected_manifest_fingerprint: APPROVED_BATCH.manifestFingerprint,
        p_expected_preview_fingerprint: APPROVED_BATCH.previewFingerprint,
        p_reason: APPROVED_BATCH.reason,
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
  }, [supabase])

  /** Read-only outcome check after an uncertain result. Writes nothing. */
  const verify = useCallback(async () => {
    const preview = await loadPreview()
    if (!preview) return
    const decided = preview.rows_with_existing_decision
    if (decided >= APPROVED_BATCH.rows) {
      setRun({ kind: 'verified_committed', rows: decided })
    } else if (decided === 0 && preview.preview_fingerprint === APPROVED_BATCH.previewFingerprint) {
      setRun({ kind: 'verified_not_executed' })
    } else {
      setRun({
        kind: 'verified_unexpected',
        detail: `${decided} of ${APPROVED_BATCH.rows} rows carry a decision. This is neither a completed batch nor an untouched one.`,
      })
    }
    setGuard(evaluateGuard(preview))
  }, [loadPreview])

  const refresh = useCallback(() => setNonce((n) => n + 1), [])

  return { guard, run, execute, verify, refresh }
}
