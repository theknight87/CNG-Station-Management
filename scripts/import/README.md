# Import pipeline scripts

The pipeline itself lives in `src/import/`. These are its entry points.

Architecture, provenance model, idempotency strategy, issue severity and the safe commit
strategy for Prompt 21 are documented in [`docs/import-pipeline.md`](../../docs/import-pipeline.md).

| Script | What it does |
| --- | --- |
| `dry-run.ts <sourceDir> [outFile]` | Runs the full pipeline and writes a factual report. Hashes all six workbooks before and after and refuses to write a report if any byte changed. Writes to NO canonical table. |
| `verify-idempotency.ts <sourceDir>` | Runs the pipeline twice over unchanged sources and proves every row is detected as a replay, then proves a changed row is not. |
| `verify-invariants.ts <sourceDir>` | Asserts the "must be 0" safety properties across every real source row. |

```
npx tsx scripts/import/dry-run.ts /path/to/workbooks
npx tsx scripts/import/verify-idempotency.ts /path/to/workbooks
npx tsx scripts/import/verify-invariants.ts /path/to/workbooks
```

The six workbooks are **not** in this repository. Point `<sourceDir>` at a directory holding
them under their exact delivered names (see `src/import/sources.ts`). They are opened read-only
and are never written to.

## Rules these scripts enforce

- Dry-run first. Nothing is committed until a human has reviewed the report; the commit step
  itself is Prompt 21 and is deliberately not built yet.
- A row is never discarded for a field-level problem. Row-level errors are collected and the run
  continues.
- Identifiers are read as raw strings and never numerically coerced.
- The whole source row is preserved in `source_raw` with its file, sheet and row number.
- Station and Unit mappings are never guessed. Unresolved records are retained with the correct
  `mapping_status` and surfaced in Admin → Data Quality.
- Excel `Days Left` columns are never imported.
- Logs carry counts and reasons, not workbook dumps, and never a secret of any kind.
