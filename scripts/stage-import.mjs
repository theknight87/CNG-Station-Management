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
 *            makes exactly one RPC call.
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
import { stat } from 'node:fs/promises'
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

const mode = process.argv[2]
const dir = arg('source-dir')
if (!dir || !['preview', 'commit'].includes(mode)) {
  console.error('usage: stage-import.mjs <preview|commit> --source-dir <dir>' +
    ' [--expect-fingerprint <hex>] [--label <text>]')
  process.exit(2)
}
if (mode === 'preview') await preview(dir)
else await commit(dir, arg('expect-fingerprint'), arg('label'))
