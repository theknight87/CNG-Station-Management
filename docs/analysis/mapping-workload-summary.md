# Pre-import mapping workload — analysis (Prompt 20E)

**Read-only.** No mapping decision was written, no `mapping_status` changed, no RPC that writes a
decision was called, no Station or asset was created, no staging row was altered, no migration was
added, no schema object changed.

Baseline at the time of analysis: `origin/main` = `2aaa1a2`, working tree clean, 43 migrations in
the repository, production project `cng-station-management` ref `ypkggegquetvpsflkaxg`, 43
migrations applied.

---

## 1. Phase 1 STOP — the live staged workload is 0, not 1,104

The analysis stopped at Phase 1 as instructed, because the live counts do not match the expected
figure and the difference is not a small drift.

| Asset family | Expected | Actual live | Difference |
| --- | --- | --- | --- |
| Storage Vessels | 433 | **0** | −433 |
| Recovery Tanks | 403 | **0** | −403 |
| Gas Detectors | 219 | **0** | −219 |
| Hoses | 49 | **0** | −49 |
| **Total** | **1,104** | **0** | **−1,104** |

Supporting production counts, all read-only:

| Table | Rows |
| --- | --- |
| `import_staging_rows` | 0 |
| `import_batches` | 0 |
| `import_mapping_decisions` | 0 |
| `import_issues` | 0 |
| `stations`, `units` | 0, 0 |
| `storage_vessels`, `recovery_tanks`, `gas_detectors`, `hoses`, `installed_relief_valves` | 0 |
| `station_aliases` | 0 |
| `owner_confirmed_station_aliases` | 1 |

## 2. Proven cause

**The difference is not status change, source replay, existing decisions, stale decisions or data
drift. The rows were never persisted in the first place.**

Two independent facts establish it:

1. **The import module has no database write path.** `src/import/` contains
   `pipeline.ts`, `staging.ts`, `run.ts`, `sources.ts`, `buildCanonical.ts`, `mappingDecisions.ts`,
   plus `readers/`, `normalize/` and `resolve/`. A search across all of them for a Supabase client,
   `createClient`, a `pg` client or any INSERT returns nothing. `runImport()` declares
   `mode: 'dry_run'` and *returns* `{ report, stagedRows, issues, conflicts }` as in-memory values.
   Nothing writes to `import_staging_rows`.

2. **The source workbooks are not in this repository.** `src/import/sources.ts` names six files by
   their delivered names (`Station data base.xlsx`, `Assets DataBase - East, west and Delta
   Completed.xlsx`, `Warehouse Relief Data.xlsx`, …) and `run.ts` reads them from a caller-supplied
   `sourceDir`. No `.xlsx` exists anywhere in the working tree.

So **1,104 is a dry-run computation, not a stored workload.** It is what the pipeline calculated,
in an earlier session with the workbooks present, that it *would* classify as
`needs_station_mapping`. The project documentation has always described these as "staged"
Prompt-21 blocker rows, which is accurate about the pipeline's classification and, read literally,
misleading about where the rows live. They live nowhere yet.

**This does not invalidate the figure.** It is a reproducible property of the source data plus the
pipeline, and it remains the best available estimate of the workload. It simply cannot be queried,
grouped, fingerprinted or turned into a review queue until the rows exist.

## 3. What this means for Phases 2–7

Phases 2 through 7 — Station-identity grouping, classification into the seven preparation
categories, candidate generation, batch decision units, the impact-ordered queue and the reduction
statistics — **all require the actual rows and their raw Station text.** With zero rows and no
workbooks reachable from here, producing any of them would mean inventing Station names, counts and
categories. That is fabricated technical data, and Phase 10 and data principle #1 both forbid it.

They are therefore **not attempted**, rather than attempted and filled with plausible-looking
output. The two CSV artifacts beside this file carry their agreed column contracts and zero data
rows, so the analysis can be re-run into the same shape the moment the evidence exists.

**Nothing about the blocker is resolved or reduced by this finding.** The 1,104 rows will still need
Station decisions; they will simply need them after the dry run is re-executed against the
workbooks and its staging output is persisted.

## 4. Persisted identity fields (Phase 0.3) — documented and verified against production

These exist and are correct; the grouping analysis is blocked only by the absence of rows.

| Concept | Column on `import_staging_rows` | Null? |
| --- | --- | --- |
| Source workbook | `source_file` | NOT NULL |
| Source sheet | `source_sheet` | NOT NULL |
| Source row | `source_row` | NOT NULL |
| Stable row identity | `source_row_key` (file/sheet/row) | NOT NULL |
| **Source-content fingerprint** | `source_row_hash` | NOT NULL |
| Asset family | `target_table` | NOT NULL |
| Raw source record (incl. raw Station text) | `source_raw` (jsonb) | NOT NULL |
| Normalized values (incl. normalized Station) | `normalized` (jsonb) | nullable |
| Candidate/match information | `resolution` (jsonb) | nullable |
| Mapping status | `mapping_status` | nullable |
| Confirmed hierarchy | `region_id`, `station_id`, `unit_id` | all nullable |
| Commit linkage | `committed_entity_id`, `committed_at` | nullable |
| Replay classification | `outcome` (enum) | NOT NULL |

Human decisions live separately in `import_mapping_decisions`, keyed by `source_row_key` **and**
`reviewed_source_row_hash` (migration 0041), the latter captured server-side and a parameter of no
function.

## 5. Phase 8 — existing batch-resolution capability: **INSUFFICIENT**

This part needed no data and was completed by inspection.

`cng_admin_decide_staged_mapping(p_staging_row_id uuid, p_station_id uuid, p_unit_id uuid,
p_expected_decision_at timestamptz, p_reason text)` takes **exactly one staging row id**. It reads
that row, derives `reviewed_source_row_hash` from it server-side, checks the per-row
`p_expected_decision_at` precondition, and writes one decision. The Admin → Data Quality screen
matches: one `openRow` at a time, no multi-select, no bulk control.

A "batch" is therefore expressible today only as N client-side sequential calls. That is a loop,
not a batch decision, and it is unsatisfactory for four reasons:

1. **Not atomic** — a failure at row 300 of 433 leaves the workload half-decided.
2. **No preview** — the owner cannot see the exact set a single confirmation would cover.
3. **No batch audit identity** — N independent decisions, with nothing recording that one human
   ruling covered them.
4. **No guard against set drift** — rows whose source content changed between preview and commit
   would be swept in silently, which is precisely the hazard migration 0041 was written to close.

The per-row content binding itself is sound and must not be bypassed. Any batch path has to apply
it *per row inside the batch*, refusing the rows whose hash moved and reporting them, never
skipping them silently.

## 6. Minimal requirements for a future Prompt 20F (NOT implemented here)

Recorded as a recommendation only.

1. A **preview** RPC returning the exact rows a proposed batch would cover, each with its current
   `source_row_hash` and status — read-only, admin-only, RLS-bounded.
2. A **commit** RPC taking the candidate Station (and optional Unit) plus the **explicit list of
   staging row ids and the hash observed for each at preview time**. Per row it re-derives the hash
   server-side; a mismatch means that row is **rejected and reported**, never decided.
3. **One batch identity** recorded on every decision it writes, so the ruling is auditable as one
   human act and supersedable through the established model.
4. Admin only, explicit confirmation, no fuzzy input, `SECURITY DEFINER` with pinned `search_path`,
   actor derived server-side, no user-supplied identity parameter.
5. It must be **incapable of mapping a row the owner did not see** — that is the acceptance test,
   and it should be proved to fail against a naive implementation before being accepted.

## 7. Owner-confirmed rules encountered

`owner_confirmed_station_aliases` holds exactly **1** row in production. Its impact on the workload
cannot be measured without the staged rows. The ruling it encodes (`ابنوب` = `ابنوب اسيوط`) remains
an exact explicit pair and is not licence for generic governorate-suffix stripping.
