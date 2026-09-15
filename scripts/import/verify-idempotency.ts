/**
 * Replay verification against the REAL workbooks.
 *
 * Runs the pipeline twice over the same unchanged sources. The second run is
 * seeded with the first run's (key, hash) index, which is exactly what a real
 * re-import would read back from `import_staging_rows`.
 *
 * Proves: reprocessing an unchanged source detects every row as a replay, so a
 * commit cannot silently create a second set of production entities. Then
 * mutates ONE row in memory to prove a genuine source change is NOT mistaken
 * for a replay.
 */

import { runDryRun } from '../../src/import/run'
import { sourceRowHash } from '../../src/import/staging'

async function main() {
  const sourceDir = process.argv[2]
  if (!sourceDir) {
    console.error('usage: verify-idempotency.ts <sourceDir>')
    process.exit(2)
  }

  const first = await runDryRun({ sourceDir })
  const prior = new Map(first.stagedRows.map((r) => [r.sourceRowKey, r.sourceRowHash]))
  console.log(`run 1: ${first.stagedRows.length} staged rows, ${first.report.replayedRows} replays`)

  const second = await runDryRun({ sourceDir, prior })
  console.log(`run 2 (same sources): ${second.stagedRows.length} staged rows, ${second.report.replayedRows} replays`)

  const allReplayed = second.report.replayedRows === second.stagedRows.length
  console.log(`every row detected as a replay: ${allReplayed}`)

  // Determinism: identical input must hash identically across runs.
  const h1 = new Map(first.stagedRows.map((r) => [r.sourceRowKey, r.sourceRowHash]))
  const drift = second.stagedRows.filter((r) => h1.get(r.sourceRowKey) !== r.sourceRowHash)
  console.log(`rows whose hash drifted between runs: ${drift.length}`)

  // A genuinely changed row must NOT be treated as a replay.
  const sample = first.stagedRows[0]
  const tampered = new Map(prior)
  tampered.set(sample.sourceRowKey, sourceRowHash({ ...sample.sourceRaw, __changed: 'yes' }))
  const third = await runDryRun({ sourceDir, prior: tampered })
  const changedRow = third.stagedRows.find((r) => r.sourceRowKey === sample.sourceRowKey)
  const detectedAsChanged = Boolean((changedRow?.resolution as { sourceChanged?: string })?.sourceChanged)
  console.log(`a changed source row is detected as changed, not replayed: ${detectedAsChanged}`)
  console.log(`run 3 replays: ${third.report.replayedRows} (expected ${second.stagedRows.length - 1})`)

  const ok = allReplayed && drift.length === 0 && detectedAsChanged &&
    third.report.replayedRows === second.stagedRows.length - 1
  console.log(ok ? 'IDEMPOTENCY VERIFIED' : 'IDEMPOTENCY CHECK FAILED')
  process.exit(ok ? 0 : 1)
}

main().catch((e) => { console.error(e); process.exit(1) })
