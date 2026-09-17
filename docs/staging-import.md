# Persisted staging import (Prompt 20F)

## Terminology — four different things, never interchangeable

| Term | Meaning | Where it lives |
| --- | --- | --- |
| **Parsed row** | a row the reader took from a workbook sheet | memory, during a run |
| **Dry-run staged row** | a parsed row after normalization, matching and validation | memory only; discarded when the process exits |
| **Persisted staging row** | a dry-run staged row written to the database for review | `import_staging_rows` |
| **Mapping decision** | a human ruling binding a staged row to a Station/Unit | `import_mapping_decisions` |
| **Canonical imported row** | an asset in an operational table | `storage_vessels`, `hoses`, … (Prompt 21) |

The well-known **7,163** and **1,104** figures are *dry-run staged rows*. Until a staging commit
runs they exist in no database. Earlier documentation called them "staged", which is true of the
classification and easy to misread as "stored"; they were never stored.

## The gap this closed

Prompt 6 built the parser, the normalizer and the dry run. `src/import/` contains no database
client, and `runDryRun()` returns its rows in memory. Nothing ever persisted them, so
`import_staging_rows` was empty and Prompt 20E could not group a workload that did not exist.

Migration **0044** adds the writer and nothing else: **no new table, no new column, no new enum**.
Everything required already existed from 0004/0026.

## Preview, emit and commit

```
node scripts/stage-import.mjs preview       --source-dir <dir>
node scripts/stage-import.mjs emit          --source-dir <dir> --out <file>
node scripts/stage-import.mjs commit        --source-dir <dir> --expect-fingerprint <hex> [--label <text>]
node scripts/stage-import.mjs commit-direct --payload <file> --expect-fingerprint <hex> [--ca <file>]
```

**Use `emit` + `commit-direct`.** The HTTP `commit` path is retained and unchanged,
but it does not work at this size: a 13.2 MB body is dropped upstream of PostgREST
before the request is ever served. That was proved, not assumed — the attempt
appears in **no edge log**, and `import_runs.n_tup_ins` stayed at **0**, so the
function never executed its first statement.

**Preview** makes zero database calls. It prints the SHA-256 of every workbook, the manifest
fingerprint, sheets read, sheets excluded and why, counts by target, mapping-status distribution,
outcomes, issues by type, and exactly what would be persisted.

**Emit** is the same preview, written to a file instead of sent. Still zero database calls.

**Commit** (HTTP) re-runs the dry run, re-computes the fingerprint and **refuses** if it differs
from the approved one, then makes one RPC call.

**Commit-direct** reads an emitted file and sends it over a direct PostgreSQL connection. It gates
on the fingerprint **twice before opening a connection** — the value the file claims must equal the
approved one, and the value **recomputed from the file's own source hashes** must equal it too, so a
manifest edited to claim an approval its contents do not support is refused. It then refuses a
replay, and makes exactly one call inside one transaction.

Either way, one call is one transaction: the whole batch lands or none of it does, so a partially
written batch cannot exist to be mistaken for a ready one.

`commit` reads `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`; `commit-direct` reads `CNG_DB_URL`.
None is ever printed, none is read from a file, and none appears in the repository or any frontend
file. On a connection failure the host and database are named; the credential never is.

### Why the direct transport cannot change import semantics

It is a change of **transport only**. Both paths take the same object from the same builder and
hand its five keys to the same five parameters of the same `cng_stage_import_batch`. HTTP
serialises them into one JSON body; the direct path binds them as five **query parameters**, so no
part of the payload is ever spliced into SQL text. Parsing, normalization, mapping, issue
generation, fingerprinting, source classification and staging semantics all happen in `emit`,
before either transport is chosen, and four tests assert the two carry identical values.

### TLS

A remote database is contacted over **verified** TLS or not at all — there is no flag to disable
verification. Where the server's chain is not in the system store, supply it with `--ca <file>`
(Supabase publishes its CA under Settings → Database → SSL Configuration); that VERIFIES against
that certificate rather than skipping. Plaintext is permitted for loopback only, because a local
test database has no certificate and the traffic never leaves the machine.

## Why a CLI and not a screen

Doing this through the production frontend would mean uploading workbooks to a browser-reachable
endpoint or granting `authenticated` INSERT on the import tables — permanent attack surface for a
task one operator performs a handful of times. EXECUTE on the writer is granted to `service_role`
ONLY; **not even an admin in a browser can call it**. The import tables keep their existing
`authenticated` SELECT-only grants, so Admin → Data Quality continues to read the workload exactly
as before.

## The canonical firewall

`cng_stage_import_batch` writes `import_runs`, `import_batches`, `import_staging_rows`,
`import_issues` and `import_source_conflicts`. Those five INSERTs are written as literals — that
list *is* the allowlist — and the function contains **no dynamic SQL**, so `target_table` is stored
as data and a caller can never name a destination. It writes no mapping decision, creates no
Station, no Unit and no asset.

This is asserted from the catalog (STG-2, STG-3) rather than taken on trust, and the detection
pattern was proved to catch `INSERT INTO stations`, `UPDATE hoses` and `import_mapping_decisions`
before being accepted.

## Replay semantics

The **manifest fingerprint** hashes every filename with its SHA-256, sorted so file order cannot
change it. `import_runs_manifest_fingerprint_uq` then makes "one completed run per distinct source
content" a database property.

| Situation | Behaviour |
| --- | --- |
| Exact replay (same bytes) | refused by the unique index; nothing duplicated |
| Changed workbook | different fingerprint, so a distinct run — the prior review state is not overwritten |
| Double-click / retry after a dropped connection | one run survives; the loser is told why |
| Partial previous failure | the transaction rolled back, so there is nothing to clean up; retry freely |
| Abandoned preview | preview writes nothing, so there is no state to abandon |

The index is **partial on `completed_at`**, so a failed run never blocks a corrected retry of the
same sources.

## Abandoning a batch

`cng_abandon_import_run(p_import_run_id, p_reason)` marks every batch of one run `rolled_back`. It
is a **state change, never a delete** — import records are not destroyed — it is batch-scoped by a
required id, and it refuses a run that has canonically committed rows or that any mapping decision
references, so a ruling can never be orphaned. `service_role` only.

## What is still ahead

1. An owner-approved production staging commit. **Nothing has been written to production.**
2. Re-running the Prompt 20E workload analysis against the now-queryable rows.
3. Prompt 21 remains blocked until mapping review is complete.
