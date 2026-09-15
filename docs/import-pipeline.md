# Import Pipeline

How source workbooks become canonical records — and, just as importantly, what the pipeline
refuses to do.

`docs/import-mapping.md` says WHICH source column becomes which field. This document says HOW the
machinery works: provenance, idempotency, dry-run, issue severity, and the safe commit strategy
for Prompt 21.

> **Status: built and verified in dry-run (Prompt 6). No production import has been performed.**
> The final import of the six workbooks is Prompt 21.

---

## 1. Stages

```
Excel source (READ-ONLY)
  -> extraction          readers/workbook.ts    raw cells, no coercion
  -> raw preservation    source_raw JSONB       the entire row, verbatim
  -> normalization       normalize/*            text, dates, identifiers, regions
  -> classification      normalize/identifiers  serial vs owner-confirmed part number
  -> canonical matching  resolve/stations       confirmed aliases only; fuzzy PROPOSES
  -> validation          pipeline.ts            issues, never silent drops
  -> staging             import_staging_rows    the not-yet-committed candidate record
  -> mapping lifecycle   resolve/srvMapping     needs_station -> unit -> equipment -> resolved
  -> data-quality issues import_issues          blocking vs non-blocking
  -> dry-run             scripts/import/dry-run.ts
  -> import plan         the dry-run report
  -> controlled commit   PROMPT 21 — not built here
```

Every stage before "controlled commit" is implemented and exercised against the real workbooks.

## 2. Provenance

Every staged row carries enough to reconstruct its origin cell:

| Column | Meaning |
| --- | --- |
| `source_file`, `source_sheet`, `source_row` | 1-based, exactly as the workbook numbers it |
| `source_raw` | the **entire** row, verbatim, as JSONB |
| `import_batch_id`, `import_run_id` | which file+sheet, and which execution |
| `normalized` | the transformed candidate record — a SEPARATE column |
| `resolution` | how each value was reached: which rule, which alias, which proposal |

**Raw is never overwritten by normalized.** They live in different columns and stay
distinguishable forever. `source_raw['Serial Number']` remains the number `21586` while
`normalized.serial_number` is the string `"21586"`.

The source workbooks are opened read-only. `scripts/import/dry-run.ts` hashes all six before and
after every run and refuses to write a report if any byte changed.

## 3. Idempotency and replay

Identity is **(file, sheet, row)** — never a display name.

| | |
| --- | --- |
| `source_row_key` | `file::sheet::row`. Stable across runs. |
| `source_row_hash` | sha256 of the row content, with keys sorted so column order cannot change it, and types rendered so `21586` and `"21586"` hash differently. |

| Second run sees | Verdict |
| --- | --- |
| same key, same hash | **replay** — a commit must not create a second entity |
| same key, different hash | **changed** — the source file genuinely changed at that row |
| unknown key | **new** |

Verified on the real corpus: re-running over unchanged sources classified **7,163 of 7,163 rows as
replays**, with zero hash drift, and a single tampered row was correctly reported as changed rather
than replayed (`scripts/import/verify-idempotency.ts`).

## 4. Dry-run

A dry run performs **the same** parsing, normalization, matching and validation a commit would. It
differs in one way: it writes only to staging.

`committed_entity_id` and `committed_at` are NULL for every dry-run row, and a CHECK constraint
keeps them consistent — so "did this run create anything?" is answerable by a single query rather
than by trust.

The report includes rows read per file/sheet, rows by outcome, canonical entities proposed and
matched, unresolved station/unit/equipment counts, conflicts, date-shape counts, missing optional
values, replays, owner-confirmed rule applications, source conflicts, and the full unmatched-station
list. **Unresolved records are counted, never hidden to improve a success percentage.**

## 5. Issue severity

Severity is a property of the ISSUE, not of NULL-ness. NULL is valid data.

| | Meaning | Examples |
| --- | --- | --- |
| **Non-blocking** | the record is created; something optional is missing or unresolved | missing serial, missing job number, year-only date, invalid date, unmatched station for an installed SRV, unknown region on a non-owning field |
| **Blocking** | the record cannot safely create the intended entity | a row naming neither `Storage` nor `Recovery` (it selects no equipment table); an identifier already destroyed by scientific notation; a row that precedes any station block header |

An unknown Station for an installed SRV is explicitly **non-blocking**: the SRV stages as
`needs_station_mapping` and keeps its raw station name. It is never deleted, and `import_issues` is
never the only place it exists.

## 6. Station and Unit resolution

Resolution requires an **explicit, stored mapping**:

1. an owner-confirmed equivalence (exact value match, enumerated list)
2. a **confirmed** alias
3. an exact canonical name

Nothing else resolves. Similarity produces a **proposal** carrying its score and method;
a proposal attaches no data and creates no entity. `MatchProposal.autoAccepted` is typed as the
literal `false`, so no code path can flip it.

There is no suffix rule, no governorate-stripping rule, no number-stripping rule, and no confidence
threshold that promotes a proposal. A **rejected** alias is never re-proposed.

`Station data base.xlsx` is unit-grain and is **not** treated as a Station master: its rows resolve
against the structure from `Assets DataBase`, and where they do not resolve they stage as
`proposal_only`, which attaches nothing.

## 7. Owner-confirmed rules

Two, both exact-value lists mirroring their database tables. Neither is a pattern.

| Rule | Effect | Explicitly NOT authorized |
| --- | --- | --- |
| `ابنوب اسيوط` = `ابنوب` | that exact pair resolves without review | generic governorate-suffix stripping |
| `SS-4R3A` is a part number | `part_number = SS-4R3A`, `serial_number = NULL`, `serial_status = not_yet_assigned`, raw cell preserved | reclassifying any other value, however similar its shape |

Every application is counted in the report, per rule, with its source file and sheet.

## 8. The installed-SRV lifecycle

The source has no Unit column and no equipment identifier, so **no installed SRV can arrive
`resolved`** — and none did.

| Evidence | Status | `station_id` | `unit_id` | equipment |
| --- | --- | --- | --- | --- |
| station unconfirmed | `needs_station_mapping` | NULL | NULL | NULL |
| station confirmed, 0 or several units | `needs_unit_mapping` | set | NULL | NULL |
| station confirmed, exactly one unit | `needs_equipment_mapping` | set | set | NULL |
| a human confirms the parent (D3) | `resolved` | set | set | exactly one |
| sources disagree | `conflict` | evidence preserved | | |

`Location` = `Stage` or `Storage` sets `expected_parent_kind` — a **hint that narrows the choices
offered to an engineer**. It never populates a foreign key. `expectedParentKindFromLocation`
returns a KIND; no function in the module returns an equipment record.

## 9. Field-level source precedence

No workbook wins globally. Where two sources disagree on one field of one entity and
`import-mapping.md` §8 declares no precedence, both raw values are stored in
`import_source_conflicts` with their provenance and **neither is selected**. A `selected_side`
requires either a named precedence rule or a human — enforced by a CHECK constraint.

## 10. Authorization

Import is a privileged administrative operation. `import_runs`, `import_staging_rows` and
`import_source_conflicts` are readable by **admin and manager only** — not engineers, not viewers,
not anon. Staging holds unresolved raw source text, and raw source text is never an authorization
boundary.

There is **no INSERT grant** on any of them: staging is written server-side by the pipeline, never
through the API. There is no DELETE. Resolving a conflict is a column-level UPDATE for admins only,
so a resolver cannot rewrite the evidence being resolved.

## 11. Safe commit strategy for Prompt 21

The commit step is deliberately NOT built yet. When it is, it should:

1. run a dry run first and require a human to review the report
2. read `import_staging_rows` for that run — never re-parse the workbooks, so what is reviewed is
   exactly what is committed
3. skip every row whose outcome is `replayed`, `proposal_only`, `rejected` or `excluded`
4. write canonical rows inside one transaction per batch, setting `committed_entity_id` and
   `committed_at` on the staging row in the same transaction
5. never write a value the staging row does not carry, and never resolve a mapping the pipeline
   left unresolved
6. leave `needs_*_mapping` records exactly as staged — they are resolved by humans in
   Admin -> Data Quality, which is a product feature, not a migration script
7. re-run `scripts/import/verify-invariants.ts` afterwards
