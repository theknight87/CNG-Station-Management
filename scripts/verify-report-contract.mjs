#!/usr/bin/env node
/**
 * REPORT CONTRACT GATE (Prompt 20B).
 *
 * The frontend/report-view contract is the one boundary neither existing suite
 * could see: the SQL suites do not know what the browser asks for, and the
 * frontend tests do not know what the database actually exposes. So a report
 * spec naming a column no view has — `station_display` on `v_vessel_management`,
 * the defect the owner found in production — passed every check and then failed
 * in the browser with `column ... does not exist`.
 *
 * This script closes that gap by comparing the two directly: every column each
 * report SELECTs, RENDERS, FILTERS on, SEARCHES, ORDERS by, identifies rows by,
 * or SUMMARISES, against `information_schema.columns` for that report's view.
 *
 * Any mismatch exits non-zero. Per CLAUDE.md §7a the exit code is the verdict;
 * nothing here greps for success.
 *
 * Usage: node scripts/verify-report-contract.mjs <database>
 */
import { execFileSync } from 'node:child_process'
import { REPORT_SPECS, selectColumnsFor } from '../src/features/reports/reportSpecs.ts'

const db = process.argv[2]
if (!db) {
  console.error('usage: verify-report-contract.mjs <database>')
  process.exit(2)
}

const viewNames = [...new Set(REPORT_SPECS.map((s) => s.view))]
const sql = `
SELECT table_name, column_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (${viewNames.map((v) => `'${v}'`).join(',')})`

let raw
try {
  raw = execFileSync('sudo', ['-n', '-u', 'postgres', 'psql', '-d', db, '-tAF|', '-c', sql], {
    encoding: 'utf8',
  })
} catch (err) {
  console.error(`could not read the schema of "${db}": ${err.message}`)
  process.exit(2)
}

const actual = new Map()
for (const line of raw.trim().split('\n').filter(Boolean)) {
  const [view, column] = line.split('|')
  if (!actual.has(view)) actual.set(view, new Set())
  actual.get(view).add(column)
}

/** Every column this report asks the database for, and why it asks. */
function requiredColumns(spec) {
  const need = new Map()
  const add = (column, use) => {
    if (!column) return
    if (!need.has(column)) need.set(column, new Set())
    need.get(column).add(use)
  }
  for (const c of selectColumnsFor(spec)) add(c, 'select')
  for (const c of spec.columns) add(c.key, 'render')
  for (const [key, value] of Object.entries(spec.filterColumns)) {
    if (key === 'search') for (const c of value) add(c, 'search')
    else add(value, `filter:${key}`)
  }
  for (const o of spec.orderBy) add(o.column, 'order')
  add(spec.idColumn, 'row identity')
  if (spec.summaryBreakdown) add(spec.summaryBreakdown.column, 'summary')
  return need
}

let failures = 0
for (const spec of REPORT_SPECS) {
  const have = actual.get(spec.view)
  if (!have) {
    console.error(`FAILED: report "${spec.id}" reads ${spec.view}, which does not exist`)
    failures++
    continue
  }
  for (const [column, uses] of requiredColumns(spec)) {
    if (!have.has(column)) {
      console.error(
        `FAILED: report "${spec.id}" uses ${spec.view}.${column} for ` +
          `${[...uses].join(', ')} — that column does not exist`,
      )
      failures++
    }
  }
}

if (failures > 0) {
  console.error(`\nreport contract: ${failures} mismatch(es)`)
  process.exit(1)
}
console.log(`report contract: ${REPORT_SPECS.length} reports, ${viewNames.length} views, 0 mismatches`)
