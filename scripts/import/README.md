# Source data importers

Importers live here. They are not implemented yet (Phase 7).

Rules they must follow, from `CLAUDE.md`:

- Every importer runs **dry-run first** and prints a report: rows read, rows mapped,
  rows flagged for review with the reason, rows landing in each `mapping_status`, and
  every value that was normalized and by which rule.
- Nothing is written until a dry-run has been reviewed by a human.
- Valid rows are never discarded for a field-level problem; a row-level error is
  collected and the run continues.
- Identifiers and serial numbers are read as raw strings — never numerically coerced.
- The original row is preserved in `source_raw`, with its file, sheet and row number.
- Station and Unit mappings are never guessed. Unresolved records are retained with the
  appropriate `mapping_status` and surfaced in Admin → Data Quality.
- Excel `Days Left` columns are never imported.
