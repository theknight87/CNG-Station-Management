#!/usr/bin/env node
/**
 * Stage A operator runner (Prompt 21C).
 *
 *   node scripts/stage-a.mjs preview --run <import_run_id>
 *   node scripts/stage-a.mjs commit  --run <import_run_id> \
 *        --expect-manifest <hex> --expect-preview <hex>
 *
 * WHY A CLI AND NOT A SCREEN. Creating the canonical hierarchy is an operator
 * action performed once. Exposing it in the browser would mean granting a
 * browser role EXECUTE on a function that writes `stations` and `units` — a
 * permanent piece of attack surface for a task nobody repeats. The database
 * enforces this rather than trusting the choice: EXECUTE is `service_role` only,
 * so this runner is the only caller that can exist.
 *
 * CREDENTIALS. The connection string is read from CNG_DB_URL in the environment
 * and is never written to a file, never logged, and never stored in the
 * repository. Only the host and database name are ever printed.
 *
 * FAIL CLOSED. `commit` forwards the two fingerprints you approved; it does not
 * look them up. The database re-derives both and refuses if either has moved, so
 * an approval cannot silently widen into "commit whatever is there now".
 */
import { Client } from 'pg'
import { readFile } from 'node:fs/promises'

function arg(name) {
  const i = process.argv.indexOf(name)
  return i === -1 ? undefined : process.argv[i + 1]
}

function safeHost(connectionString) {
  try {
    const u = new URL(connectionString)
    return `${u.hostname}${u.pathname}`
  } catch {
    return '(unparseable connection string)'
  }
}

async function tlsFor(connectionString, caPath) {
  let host = ''
  try { host = new URL(connectionString).hostname } catch { /* handled below */ }
  const loopback = host === 'localhost' || host === '127.0.0.1' || host === '::1'
  if (loopback) return false
  if (caPath) return { rejectUnauthorized: true, ca: await readFile(caPath, 'utf8') }
  return { rejectUnauthorized: true }
}

async function connect() {
  const connectionString = process.env.CNG_DB_URL
  if (!connectionString) {
    console.error('CNG_DB_URL must be set in the environment.')
    console.error('It is never read from a file and never stored in the repository.')
    process.exit(2)
  }
  const client = new Client({
    connectionString,
    ssl: await tlsFor(connectionString, arg('--ca')),
  })
  await client.connect()
  console.log(`connected to ${safeHost(connectionString)}`)
  return client
}

async function preview(runId) {
  const client = await connect()
  try {
    const { rows } = await client.query('SELECT * FROM cng_stage_a_preview($1::uuid)', [runId])
    const p = rows[0]
    if (!p || p.preview_fingerprint === null) {
      console.error(`no staging run ${runId}`)
      process.exitCode = 1
      return
    }
    console.log('')
    console.log('  import run            ', p.import_run_id)
    console.log('  manifest fingerprint  ', p.manifest_fingerprint)
    console.log('  preview fingerprint   ', p.preview_fingerprint)
    console.log('')
    console.log('  source rows           ', p.source_rows)
    console.log('  proposed Stations     ', p.proposed_stations)
    console.log('  proposed Units        ', p.proposed_units)
    console.log('  Stations with no Unit ', p.stations_without_unit, '(no Unit is invented for these)')
    console.log('')
    console.log('  existing Stations     ', p.existing_stations)
    console.log('  existing Units        ', p.existing_units)
    console.log('')
    console.log('Nothing has been written. To commit, approve BOTH fingerprints above and run:')
    console.log('')
    console.log(`  node scripts/stage-a.mjs commit --run ${p.import_run_id} \\`)
    console.log(`       --expect-manifest ${p.manifest_fingerprint} \\`)
    console.log(`       --expect-preview ${p.preview_fingerprint}`)
    console.log('')
  } finally {
    await client.end()
  }
}

async function commit(runId, expectManifest, expectPreview) {
  if (!expectManifest || !expectPreview) {
    console.error('commit requires --expect-manifest and --expect-preview, both taken from the')
    console.error('preview you approved. There is deliberately no "approve current state" option.')
    process.exit(2)
  }
  const client = await connect()
  try {
    // One call is one transaction. A partial hierarchy cannot exist.
    await client.query('BEGIN')
    const { rows } = await client.query(
      'SELECT * FROM cng_stage_a_commit($1::uuid, $2::text, $3::text)',
      [runId, expectManifest, expectPreview],
    )
    await client.query('COMMIT')
    const r = rows[0]
    console.log('')
    console.log('  Stations created    ', r.stations_created)
    console.log('  Units created       ', r.units_created)
    console.log('  staging rows linked ', r.staging_rows_linked)
    console.log('  committed proposal  ', r.preview_fingerprint)
    console.log('')
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {})
    console.error('COMMIT REFUSED — nothing was written.')
    console.error(err.message)
    process.exitCode = 1
  } finally {
    await client.end()
  }
}

const mode = process.argv[2]
const runId = arg('--run')
if (!runId) {
  console.error('--run <import_run_id> is required')
  process.exit(2)
}
if (mode === 'preview') await preview(runId)
else if (mode === 'commit') await commit(runId, arg('--expect-manifest'), arg('--expect-preview'))
else {
  console.error('usage: stage-a.mjs preview|commit --run <import_run_id> [--expect-manifest <hex> --expect-preview <hex>]')
  process.exit(2)
}
