/**
 * DRY-RUN CLI.
 *
 * Runs the complete pipeline against the six source workbooks and writes a
 * factual report. It performs the SAME parsing, normalization, matching and
 * validation a commit would, and writes to NO canonical table.
 *
 * Safety properties, enforced here rather than promised:
 *   * the workbooks are opened read-only and their checksums are asserted
 *     identical before and after the run
 *   * nothing in the imported module graph opens a database connection
 *   * the report is data, not a claim: every count is computed from what the
 *     run actually produced
 *
 * Usage:  npx tsx scripts/import/dry-run.ts <sourceDir> [outFile]
 */

import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'

import { runDryRun, sha256File } from '../../src/import/run'
import { WORKBOOKS } from '../../src/import/sources'

async function checksums(dir: string): Promise<Record<string, string>> {
  const out: Record<string, string> = {}
  for (const wb of WORKBOOKS) out[wb.file] = await sha256File(`${dir}/${wb.file}`)
  return out
}

async function main() {
  const sourceDir = process.argv[2]
  const outFile = process.argv[3] ?? 'artifacts/import/dry-run-report.json'
  if (!sourceDir) {
    console.error('usage: dry-run.ts <sourceDir> [outFile]')
    process.exit(2)
  }

  const before = await checksums(sourceDir)
  const result = await runDryRun({ sourceDir })
  const after = await checksums(sourceDir)

  const unchanged = Object.keys(before).every((f) => before[f] === after[f])
  if (!unchanged) {
    // The pipeline must never write to a source file. If this ever fires, the
    // run is not trustworthy and the report is not written.
    console.error('FATAL: a source workbook changed during the run')
    for (const f of Object.keys(before)) {
      if (before[f] !== after[f]) console.error(`  ${f}: ${before[f]} -> ${after[f]}`)
    }
    process.exit(1)
  }

  const payload = {
    ...result.report,
    checksumsVerifiedUnchanged: true,
    stagedRowCount: result.stagedRows.length,
    conflictCount: result.conflicts.length,
    conflicts: result.conflicts.slice(0, 50),
  }

  mkdirSync(dirname(outFile), { recursive: true })
  writeFileSync(outFile, JSON.stringify(payload, null, 2), 'utf8')

  // Console summary. Deliberately counts and reasons only: no row dumps, and
  // no workbook contents beyond the unmatched-name list the report needs.
  const r = result.report
  console.log('=== DRY RUN (no canonical write) ===')
  console.log('files read:')
  for (const f of r.files) console.log(`  ${f.file} :: ${f.sheet} (header row ${f.headerRow}) -> ${f.target}: ${f.rowsRead} rows`)
  console.log('sheets excluded:')
  for (const e of r.excludedSheets) console.log(`  ${e.file} :: ${e.sheet} — ${e.reason}`)
  console.log('counts by target:', r.counts)
  console.log('outcomes:', r.outcomes)
  console.log('mapping status:', r.mappingStatus)
  console.log('date precision:', r.datePrecision)
  console.log('issues by type:', r.issuesByType)
  console.log(`blocking: ${r.blockingIssues}  non-blocking: ${r.nonBlockingIssues}`)
  console.log('owner-confirmed rule applications:', JSON.stringify(r.ownerConfirmedRuleApplications, null, 2))
  console.log(`source conflicts: ${r.sourceConflicts}`)
  console.log(`proposals generated: ${r.proposalsGenerated} (auto-accepted: ${r.proposalsAutoAccepted})`)
  console.log(`replayed rows: ${r.replayedRows}  changed rows: ${r.changedRows}`)
  console.log(`distinct unmatched station names: ${r.unmatchedStationNames.length}`)
  console.log(`report written to ${outFile}`)
}

main().catch((err) => {
  console.error(err)
  process.exit(1)
})
