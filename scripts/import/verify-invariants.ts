/**
 * Invariant checks against the REAL workbooks.
 *
 * The unit tests prove these rules on fixtures. This proves they also hold
 * across all 7,163 real source rows, which is the claim that actually matters
 * before Prompt 21 commits anything.
 *
 * Every check is stated as "must be 0" so a regression is impossible to read
 * as a success.
 */

import { runDryRun } from '../../src/import/run'

interface Check {
  name: string
  count: number
}

async function main() {
  const sourceDir = process.argv[2]
  if (!sourceDir) {
    console.error('usage: verify-invariants.ts <sourceDir>')
    process.exit(2)
  }

  const { stagedRows, report } = await runDryRun({ sourceDir })
  const srv = stagedRows.filter((r) => r.targetTable === 'installed_relief_valves')

  const checks: Check[] = [
    {
      name: 'installed SRVs carrying ANY equipment parent',
      count: srv.filter((r) =>
        r.normalized['compressor_id'] !== null ||
        r.normalized['storage_vessel_id'] !== null ||
        r.normalized['dispenser_id'] !== null).length,
    },
    {
      name: 'installed SRVs marked resolved (the source cannot prove a parent)',
      count: srv.filter((r) => r.mappingStatus === 'resolved').length,
    },
    {
      name: 'rows given a dispenser parent hint (no source proves one)',
      count: stagedRows.filter((r) => r.normalized['expected_parent_kind'] === 'dispenser').length,
    },
    {
      name: 'year-only dates that gained a day',
      count: stagedRows.filter((r) =>
        ['last_calibration', 'next_due_date', 'issue_date', 'last_test'].some((k) => {
          const d = r.normalized[k] as { precision?: string; value?: string | null } | null
          return d?.precision === 'year_only' && d.value != null
        })).length,
    },
    {
      name: 'identifiers rendered in scientific notation',
      count: stagedRows.filter((r) => {
        const s = r.normalized['serial_number']
        return typeof s === 'string' && /\d[eE][+-]?\d/.test(s)
      }).length,
    },
    {
      name: 'fabricated placeholders in a serial field',
      count: stagedRows.filter((r) => {
        const s = r.normalized['serial_number']
        return typeof s === 'string' && ['N/A', 'NA', '-', 'unknown', 'UNKNOWN', '0000'].includes(s)
      }).length,
    },
    {
      name: 'warehouse rows given an installed mapping lifecycle',
      count: stagedRows.filter((r) =>
        r.targetTable === 'warehouse_relief_valves' && r.mappingStatus !== null).length,
    },
    {
      name: 'rows staged from the Repair Kit sheet',
      count: stagedRows.filter((r) => r.provenance.sheet.trim() === 'Repair Kit').length,
    },
    {
      name: 'proposals auto-accepted',
      count: report.proposalsAutoAccepted,
    },
    {
      name: 'staged rows claiming to have been committed',
      count: stagedRows.filter((r) => 'committed_entity_id' in r.normalized).length,
    },
    {
      name: 'rows with a station id but no confirmed resolution',
      count: stagedRows.filter((r) => {
        const st = r.resolution['station'] as { kind?: string } | undefined
        return r.normalized['station_id'] != null &&
          st !== undefined &&
          !['exact_canonical', 'confirmed_alias', 'owner_confirmed'].includes(st.kind ?? '')
      }).length,
    },
  ]

  let failed = 0
  for (const c of checks) {
    const ok = c.count === 0
    if (!ok) failed++
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c.name}: ${c.count} (must be 0)`)
  }

  console.log(`\nchecked ${stagedRows.length} real source rows`)
  console.log(failed === 0 ? 'ALL INVARIANTS HOLD' : `${failed} INVARIANT(S) VIOLATED`)
  process.exit(failed === 0 ? 0 : 1)
}

main().catch((e) => { console.error(e); process.exit(1) })
