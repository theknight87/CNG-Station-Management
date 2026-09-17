#!/usr/bin/env node
/**
 * The controlled staging runner (Prompt 20F).
 *
 * WHY THIS IS A CLI AND NOT A SCREEN. Persisting a staging run means parsing six
 * workbooks and writing thousands of rows. Doing that through the production
 * frontend would mean either uploading the workbooks to a browser-reachable
 * endpoint or granting `authenticated` INSERT on the import tables — each of
 * which adds real, permanent attack surface to the deployed application for a
 * task performed a handful of times by one operator. So the write path is
 * `service_role`-only (migration 0044 grants EXECUTE to nothing else), the key
 * never leaves the operator's shell, and the browser gains NO new authority:
 * every import table keeps its existing `authenticated` SELECT-only grant.
 *
 *   preview  reads the workbooks, runs the existing dry run, prints the
 *            manifest, the SHA-256 of every file, the counts and the issue
 *            distribution, and writes NOTHING. Zero database calls.
 *
 *   commit   re-runs the same dry run, re-computes the fingerprint, REFUSES if
 *            it does not match the one approved on the command line, and then
 *            makes exactly one RPC call over HTTP/PostgREST.
 *
 *   emit     the same preview, but WRITES the payload to a local file instead of
 *            sending it. Zero database calls.
 *
 *   commit-direct
 *            sends an EMITTED file over a direct PostgreSQL connection instead of
 *            the HTTP gateway, because a 13.2 MB body is dropped upstream of
 *            PostgREST before the request is ever served (proved: the request
 *            appears in no edge log and `import_runs.n_tup_ins` stayed 0). It
 *            binds the payload as QUERY PARAMETERS, so nothing is spliced into
 *            SQL text, and calls the SAME `cng_stage_import_batch` exactly once
 *            inside ONE transaction.
 *
 * The commit is one call to one function, so it is one transaction: the whole
 * batch lands or none of it does. A partially written batch cannot exist.
 *
 * Usage:
 *   node scripts/stage-import.mjs preview --source-dir <dir>
 *   node scripts/stage-import.mjs commit  --source-dir <dir> \
 *        --expect-fingerprint <hex> --label "<text>"
 *
 * Environment for `commit` only:
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 * Neither is read by `preview`, and neither is ever printed.
 */
import { createHash } from 'node:crypto'
import { readFile, rm, stat, writeFile } from 'node:fs/promises'
import { runDryRun, sha256File } from '../src/import/run.ts'
import { WORKBOOKS } from '../src/import/sources.ts'
import { buildStagingPayload, manifestFingerprint } from '../src/import/stagingPayload.ts'

const PIPELINE_VERSION = '0044-staging-commit'

function arg(name, fallback = null) {
  const i = process.argv.indexOf(`--${name}`)
  return i === -1 ? fallback : process.argv[i + 1]
}

const sha256 = (text) => createHash('sha256').update(text, 'utf8').digest('hex')

/**
 * Every expected workbook must be present and readable before anything runs.
 * A partial source set must not produce a partial staging run that looks whole.
 */
async function collectSources(dir) {
  const sources = []
  const missing = []
  for (const wb of WORKBOOKS) {
    const path = `${dir}/${wb.file}`
    try {
      const info = await stat(path)
      sources.push({ file: wb.file, sha256: await sha256File(path), bytes: info.size })
    } catch {
      missing.push(wb.file)
    }
  }
  if (missing.length > 0) {
    console.error('Missing required source workbook(s):')
    for (const m of missing) console.error(`  - ${m}`)
    console.error(`Expected in: ${dir}`)
    process.exit(2)
  }
  return sources
}

async function preview(dir) {
  const sources = await collectSources(dir)
  const fingerprint = manifestFingerprint(sources, sha256)
  const { report, stagedRows, issues, conflicts } = await runDryRun({ sourceDir: dir })

  console.log('=== SOURCE MANIFEST ===')
  for (const s of sources) {
    console.log(`  ${s.sha256}  ${String(s.bytes).padStart(8)}  ${s.file}`)
  }
  console.log(`  manifest fingerprint: ${fingerprint}`)
  console.log(`  pipeline version:     ${PIPELINE_VERSION}`)

  console.log('\n=== SHEETS READ ===')
  for (const f of report.files) {
    console.log(`  ${String(f.rowsRead).padStart(5)}  ${f.target.padEnd(24)} ${f.file} :: ${f.sheet}`)
  }
  console.log('\n=== SHEETS EXCLUDED (and why) ===')
  for (const e of report.excludedSheets) {
    console.log(`  ${e.file} :: ${e.sheet} — ${e.reason}`)
  }

  console.log('\n=== COUNTS BY TARGET ===')
  for (const [k, v] of Object.entries(report.counts)) console.log(`  ${k.padEnd(28)} ${v}`)
  console.log('\n=== MAPPING STATUS ===')
  for (const [k, v] of Object.entries(report.mappingStatus)) console.log(`  ${k.padEnd(28)} ${v}`)
  console.log('\n=== OUTCOMES ===')
  for (const [k, v] of Object.entries(report.outcomes)) console.log(`  ${k.padEnd(28)} ${v}`)
  console.log('\n=== ISSUES BY TYPE ===')
  for (const [k, v] of Object.entries(report.issuesByType)) console.log(`  ${k.padEnd(40)} ${v}`)
  console.log(`  blocking: ${report.blockingIssues}   non-blocking: ${report.nonBlockingIssues}`)
  console.log(`  source conflicts: ${report.sourceConflicts}`)

  const payload = buildStagingPayload({
    label: 'preview', startedAt: report.startedAt, pipelineVersion: PIPELINE_VERSION,
    sources, fingerprint, files: report.files, excludedSheets: report.excludedSheets,
    counts: report.counts, mappingStatus: report.mappingStatus, outcomes: report.outcomes,
    issuesByType: report.issuesByType,
    ownerConfirmedRuleApplications: report.ownerConfirmedRuleApplications,
    stagedRows, issues, conflicts,
  })

  console.log('\n=== WOULD PERSIST ===')
  console.log(`  import_runs             1`)
  console.log(`  import_batches          ${payload.batches.length}`)
  console.log(`  import_staging_rows     ${payload.rows.length}`)
  console.log(`  import_issues           ${payload.issues.length}`)
  console.log(`  import_source_conflicts ${payload.conflicts.length}`)
  console.log('\nNO DATABASE CALL WAS MADE. This was a preview.')
  return { payload, fingerprint }
}

async function commit(dir, expected, label) {
  if (!expected) {
    console.error('commit requires --expect-fingerprint (from a preview you reviewed)')
    process.exit(2)
  }
  const url = process.env.SUPABASE_URL
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY
  if (!url || !key) {
    console.error('commit requires SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY in the environment')
    process.exit(2)
  }

  const { payload, fingerprint } = await preview(dir)

  // The source-content binding. A workbook edited between preview and commit
  // changes the fingerprint, and this refuses rather than silently persisting
  // content nobody reviewed.
  if (fingerprint !== expected) {
    console.error('\nREFUSED: the source content changed since the approved preview.')
    console.error(`  approved: ${expected}`)
    console.error(`  current:  ${fingerprint}`)
    process.exit(3)
  }
  payload.manifest.label = label ?? `staging ${new Date().toISOString()}`

  console.log('\n=== COMMITTING (one transaction) ===')
  const res = await fetch(`${url}/rest/v1/rpc/cng_stage_import_batch`, {
    method: 'POST',
    headers: {
      apikey: key,
      Authorization: `Bearer ${key}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_manifest: payload.manifest,
      p_batches: payload.batches,
      p_rows: payload.rows,
      p_issues: payload.issues,
      p_conflicts: payload.conflicts,
    }),
  })
  const text = await res.text()
  if (!res.ok) {
    // The body can echo back request content; the status and the server's
    // message are what a diagnosis needs, and no key is ever printed.
    console.error(`FAILED: HTTP ${res.status}`)
    console.error(text.slice(0, 2000))
    process.exit(1)
  }
  console.log(text)
  console.log('\nStaging committed. No canonical asset was written and no mapping was decided.')
}


/**
 * EMIT. The preview, written to a file rather than sent.
 *
 * The file holds exactly the object the HTTP commit path serialises: its five
 * keys become the five arguments of `cng_stage_import_batch`, unchanged. Nothing
 * is re-parsed, re-normalized or re-classified between emit and commit — that is
 * the whole point of separating them, and a test asserts the equivalence.
 */
async function emit(dir, outPath) {
  if (!outPath) {
    console.error('emit requires --out <file>')
    process.exit(2)
  }
  const { payload, fingerprint } = await preview(dir)
  const json = JSON.stringify(payload)
  await writeFile(outPath, json, 'utf8')
  console.log('\n=== EMITTED ===')
  console.log(`  file:        ${outPath}`)
  console.log(`  bytes:       ${Buffer.byteLength(json, 'utf8')}`)
  console.log(`  file sha256: ${createHash('sha256').update(json, 'utf8').digest('hex')}`)
  console.log(`  fingerprint: ${fingerprint}`)
  console.log('\nSTILL NO DATABASE CALL. Review the counts above, then run commit-direct.')
}

/** Host of a connection string, for a message that names no credential. */
function safeHost(connectionString) {
  try {
    const u = new URL(connectionString)
    return `${u.hostname}${u.port ? ':' + u.port : ''}${u.pathname}`
  } catch {
    return '(unparseable connection string)'
  }
}

/**
 * TLS policy.
 *
 * A remote database is contacted over verified TLS or not at all. There is no
 * flag to turn verification off: that would quietly downgrade the one protection
 * standing between a service-role session and the network. Where the server's
 * chain is not in the system store — Supabase publishes its CA in the dashboard
 * under Settings -> Database -> SSL Configuration — the operator supplies it with
 * `--ca <file>`, which VERIFIES against that certificate rather than skipping.
 *
 * Plaintext is permitted for loopback only, because a local test database has no
 * certificate and the traffic never leaves the machine.
 */
async function tlsFor(connectionString, caPath) {
  let host = ''
  try { host = new URL(connectionString).hostname } catch { /* handled below */ }
  const loopback = host === 'localhost' || host === '127.0.0.1' || host === '::1'
  if (loopback) return false
  if (caPath) return { rejectUnauthorized: true, ca: await readFile(caPath, 'utf8') }
  return { rejectUnauthorized: true }
}

async function commitDirect(payloadPath, expected, caPath) {
  if (!payloadPath) {
    console.error('commit-direct requires --payload <file> (from emit)')
    process.exit(2)
  }
  if (!expected) {
    console.error('commit-direct requires --expect-fingerprint (from the preview you approved)')
    process.exit(2)
  }
  const connectionString = process.env.CNG_DB_URL
  if (!connectionString) {
    console.error('commit-direct requires CNG_DB_URL in the environment.')
    console.error('It is never read from a file and never stored in the repository.')
    process.exit(2)
  }

  const raw = await readFile(payloadPath, 'utf8')
  const payload = JSON.parse(raw)

  // ---- Fingerprint gate, BEFORE any connection is opened. -----------------
  // Two independent checks: the fingerprint the file CLAIMS must equal the one
  // approved, and the fingerprint RECOMPUTED from the file's own source hashes
  // must equal it too. The second catches a file whose manifest was edited to
  // claim an approval its contents do not support.
  const claimed = payload?.manifest?.manifest_fingerprint
  if (claimed !== expected) {
    console.error('\nREFUSED: the payload does not carry the approved fingerprint.')
    console.error(`  approved: ${expected}`)
    console.error(`  payload:  ${claimed ?? '(absent)'}`)
    process.exit(3)
  }
  const recomputed = manifestFingerprint(payload.manifest.sources ?? [], sha256)
  if (recomputed !== expected) {
    console.error('\nREFUSED: the payload manifest does not recompute to its own fingerprint.')
    console.error(`  approved:   ${expected}`)
    console.error(`  recomputed: ${recomputed}`)
    process.exit(3)
  }

  console.log('=== APPROVED PAYLOAD ===')
  console.log(`  file:        ${payloadPath}`)
  console.log(`  fingerprint: ${expected} (claimed and recomputed)`)
  console.log(`  batches ${payload.batches.length} · rows ${payload.rows.length}` +
    ` · issues ${payload.issues.length} · conflicts ${payload.conflicts.length}`)

  const { Client } = await import('pg')
  const client = new Client({
    connectionString,
    ssl: await tlsFor(connectionString, caPath),
    // A 13 MB bind parameter is not slow, but a stalled connection must not hang
    // an operator's terminal indefinitely.
    statement_timeout: 600_000,
    query_timeout: 600_000,
  })

  try {
    await client.connect()
  } catch (err) {
    // Never echo the connection string: it carries the password.
    console.error(`FAILED to connect to ${safeHost(connectionString)}: ${err.code ?? err.message}`)
    if (String(err.message).match(/certificate|self.signed|SSL/i)) {
      console.error('TLS verification failed. Supply the server CA with --ca <file>.')
      console.error('Supabase publishes it under Settings -> Database -> SSL Configuration.')
    }
    process.exit(1)
  }

  try {
    // ---- Replay gate. The partial unique index in migration 0044 is the real
    // enforcement; this only turns a constraint violation into a clear message,
    // and it runs BEFORE the write is attempted.
    const prior = await client.query(
      `SELECT count(*)::int AS n FROM import_runs
        WHERE summary ->> 'manifest_fingerprint' = $1 AND completed_at IS NOT NULL`,
      [expected],
    )
    if (prior.rows[0].n > 0) {
      console.error('\nREFUSED: a completed staging run already exists for this source content.')
      console.error('Nothing was written. Inspect the existing run before doing anything else.')
      process.exit(4)
    }

    // ---- ONE transaction, ONE call. The payload travels as five BIND
    // PARAMETERS, so no part of it is ever spliced into SQL text.
    console.log('\n=== COMMITTING (one transaction, one call) ===')
    await client.query('BEGIN')
    const res = await client.query(
      'SELECT * FROM cng_stage_import_batch($1::jsonb, $2::jsonb, $3::jsonb, $4::jsonb, $5::jsonb)',
      [
        JSON.stringify(payload.manifest),
        JSON.stringify(payload.batches),
        JSON.stringify(payload.rows),
        JSON.stringify(payload.issues),
        JSON.stringify(payload.conflicts),
      ],
    )
    await client.query('COMMIT')

    const r = res.rows[0]
    console.log(`  import_run_id           ${r.import_run_id}`)
    console.log(`  batches_written         ${r.batches_written}`)
    console.log(`  rows_written            ${r.rows_written}`)
    console.log(`  issues_written          ${r.issues_written}`)
    console.log(`  conflicts_written       ${r.conflicts_written}`)
    console.log('\nStaging committed. No canonical asset was written and no mapping was decided.')
  } catch (err) {
    // Fail closed. Any error rolls the whole batch back, so a partial batch
    // cannot survive to look ready.
    try { await client.query('ROLLBACK') } catch { /* connection already gone */ }
    console.error(`\nFAILED and ROLLED BACK: ${err.code ?? ''} ${err.message}`)
    console.error('Nothing was persisted. Verify with a read-only query before retrying.')
    process.exit(1)
  } finally {
    await client.end().catch(() => {})
  }

  // The emitted file is a full copy of the source data. Remove it once it has
  // served its purpose rather than leaving it on disk.
  try {
    await rm(payloadPath)
    console.log(`\nDeleted the temporary payload: ${payloadPath}`)
  } catch {
    console.log(`\nCould not delete ${payloadPath} — please delete it yourself.`)
  }
}

const mode = process.argv[2]
const dir = arg('source-dir')
const MODES = ['preview', 'emit', 'commit', 'commit-direct']
const needsSourceDir = mode === 'preview' || mode === 'emit' || mode === 'commit'
if (!MODES.includes(mode) || (needsSourceDir && !dir)) {
  console.error('usage:')
  console.error('  stage-import.mjs preview       --source-dir <dir>')
  console.error('  stage-import.mjs emit          --source-dir <dir> --out <file>')
  console.error('  stage-import.mjs commit        --source-dir <dir> --expect-fingerprint <hex> [--label <text>]')
  console.error('  stage-import.mjs commit-direct --payload <file> --expect-fingerprint <hex> [--ca <file>]')
  process.exit(2)
}
if (mode === 'preview') await preview(dir)
else if (mode === 'emit') await emit(dir, arg('out'))
else if (mode === 'commit') await commit(dir, arg('expect-fingerprint'), arg('label'))
else await commitDirect(arg('payload'), arg('expect-fingerprint'), arg('ca'))
