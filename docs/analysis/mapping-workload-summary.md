# Pre-import mapping workload — analysis (Prompt 20H)

**Read-only.** No mapping decision written, no `mapping_status` changed, no decision-writing RPC
called, no Station/Unit/asset created, no staging row altered, no migration added, no schema object
changed. Supersedes the Prompt 20E version, which ran against an empty database.

Production: `cng-station-management`, ref `ypkggegquetvpsflkaxg`, **44 migrations**.

---

## 1. The staging run is verified against production

| | |
| --- | --- |
| `import_run_id` | `cdad1e5e-7faa-4f3b-9432-12a720f3dd64` |
| `manifest_fingerprint` | `764d3c0f…5f091b8f` — **matches the approved value** |
| `pipeline_version` | `0044-staging-commit` |
| `started_at` / `completed_at` | 2026-09-17 06:47:08Z / 2026-09-17 07:18:31Z |
| batch statuses | all `completed` |
| orphan rows / orphan issues | 0 / 0 |
| abandoned flag | not set |

Run-scoped **and** global counts agree exactly: **7 batches, 7,163 staging rows, 3,402 issues,
0 source conflicts, 0 mapping decisions.** Every family count, mapping-status count and issue-type
count reproduces the approved preview exactly, recomputed from the persisted rows — including the
four-family blocker total of **1,104** (Storage 433, Recovery 403, Detectors 219, Hoses 49).

Canonical firewall holds: `stations` 0, `units` 0, `compressors` 0, `dispensers` 0, and all five
asset tables 0. `regions` is 6 — the seed from migration 0013, not created by staging.

---

## 2. STOP — asset mapping cannot proceed yet

**This is a material sequencing finding, established from the schema, not assumed.**

`cng_admin_decide_staged_mapping(p_staging_row_id uuid, p_station_id uuid, p_unit_id uuid, …)`
takes a **canonical** Station id. `import_mapping_decisions` carries
`import_mapping_decisions_confirmed_station_id_fkey → stations` and `imd_unit_station_fk → units`.

`stations` = **0**. `units` = **0**.

So **no mapping decision can be recorded at all today** — any call would fail its foreign key,
because there is no canonical Station to confirm. The 1,104 blockers are not merely unreviewed;
they are **not yet actionable**.

The required order is therefore:

```
STAGE A   staged stations_units (402) + unit_attributes (325)
          → owner review / reconciliation
          → canonical Regions → Stations → Units

STAGE B   staged assets (the 1,104 blockers, plus 740 needs_unit and 801 needs_equipment)
          → map against the canonical hierarchy
          → canonical assets
```

Stage A is a prerequisite, not a parallel track. `docs/data-quality-report.md` §3 and CLAUDE.md §8
already say no single workbook is the Station master and that Canal, Alex and Upper have no
structural source — so Stage A is itself a review exercise, not a mechanical load.

---

## 3. The mapping workload, grouped

The 1,104 blocker rows carry **327 distinct raw Station identities** (`normalized.source_station_name_raw`).
None is NULL or blank. So the review unit is **327 identities, not 1,104 rows** — a 3.4× reduction.

The distribution is long-tailed, which matters for planning:

| | rows covered |
| --- | ---: |
| top 10 identities | 136 |
| top 25 identities | 244 |
| top 50 identities | 384 |
| all 327 | 1,104 |

**95 identities appear exactly once.** There is no small set of decisions that clears the backlog;
the tail is the work.

- Identities spanning more than one Region: **2** (`رشدي` Alex+West, `الداخلية` Alex+Upper) — these
  need owner judgment before any single-Station decision, because one raw name is being used in two
  Regions.
- Normalization collisions (distinct raw text folding to one value): **0**. No two raw names are
  being silently merged.

---

## 4. A deterministic normalization gap worth the owner's attention

Comparing the 327 blocker identities against the 157 Station names in the structural source
(`stations_units`) gives **0 exact matches** — on raw text *and* on `cng_normalize_name()` output.

The cause is precise, and it is not a data problem:

```
structural source :  أتــريب / بنــها 1   →  cng_normalize_name  →  "اتريب / بنها 1"
asset source      :  أتريب/بنها 1         →  cng_normalize_name  →  "اتريب/بنها 1"
```

`cng_normalize_name()` **already strips tatweel** (ـ, U+0640) — 49 structural names contain it and
none survives normalization. The only residual difference is **whitespace around the `/`
separator**.

Measured, as a hypothesis only — **no rule was applied and no candidate was recorded**: folding
whitespace around `/` in addition to what normalization already does would give

- **63** identities exactly **one** structural candidate (**214** rows),
- **0** identities more than one candidate — no new ambiguity,
- **264** identities still no candidate (**890** rows).

Collapsing whitespace around a fixed separator is deterministic, so it is the kind of normalization
data principle #7 permits. It is a **code change to normalization** and is therefore **not made
here**; it is recorded as a candidate for a future prompt, and it would need the usual proof that it
changes nothing else.

The 264 identities with no structural candidate are expected: CLAUDE.md §8 records that Canal, Alex
and Upper have no structural source at all.

---

## 5. Preparation categories, from the persisted data

Categories are assigned from evidence, not from similarity. Because `stations` is empty, **no
identity can currently be in a "deterministic canonical match" category** — a canonical Station is
what the category would have to point at.

| Category | Identities | Rows | Note |
| --- | ---: | ---: | --- |
| **A. Blocked on Stage A** — canonical Station does not exist yet | **327** | **1,104** | applies to every identity today |
| *of which:* would gain one structural candidate after the §4 normalization | 63 | 214 | candidate, not a decision |
| *of which:* no structural candidate even then | 264 | 890 | mostly Canal / Alex / Upper |
| **E. Ambiguous identity** — one raw name used in two Regions | 2 | 17 | `رشدي`, `الداخلية` |
| **F. Source-data-quality, unrelated to mapping** | — | 3,402 issues | 0 blocking; see below |

Issues are all `open`, severity **warning 2,633 / info 769, zero error**: `unmatched_station` 2,435,
`year_only_date` 372, `missing_serial` 339, `not_found_in_assets_database` 142, `placeholder_value`
48, `invalid_date` 37, `ambiguous_station_identity` 20, `missing_job_number` 6,
`suspected_part_number_in_serial_column` 3.

The owner-confirmed rulings are intact and were **not** extended: `ابنوب` = `ابنوب اسيوط` remains
the single exact alias (`owner_confirmed_station_aliases` = 1 row), and `SS-4R3A` applied to 48 rows
in its one authorized context and nowhere else. No alias was created — `station_aliases` = 0.

---

## 6. Batch-mapping capability: still insufficient

Re-verified against the real workload. `cng_admin_decide_staged_mapping` still takes **one**
`p_staging_row_id`, and the Admin → Data Quality screen still holds one open row with no
multi-select. With 327 identities averaging 3.4 rows each, one-row-at-a-time means ~1,104 individual
confirmations for work the owner would naturally express as 327 rulings.

A batch path is therefore worth building — but **after Stage A**, since there is nothing to map
until canonical Stations exist. Minimum safe design, unchanged from the Prompt 20E assessment and
now sized against real data:

1. **Preview RPC** returning the exact rows a proposed batch covers, each with its current
   `source_row_hash` and status. Read-only, admin-only, RLS-bounded, and it must state the row count
   before anything is written.
2. **Commit RPC** taking the candidate Station (and optional Unit) plus the **explicit list of
   staging row ids and the hash observed for each at preview**. Per row the hash is re-derived
   server-side; a mismatch means that row is **rejected and reported**, never silently decided.
3. **Exact-match only**, scoped to one `import_run_id`, with no fuzzy input accepted anywhere.
4. **One batch identity** on every decision written, so the ruling is auditable as one human act and
   supersedable through the established model.
5. Atomic, replay-safe, `SECURITY DEFINER` with pinned `search_path`, actor derived server-side.

Acceptance test: it must be **incapable of mapping a row the owner did not see**.

---

## 7. Artifacts

- `mapping-review-queue.csv` — one row per distinct raw Station identity (327), impact-ordered.
- `mapping-unresolved-detail.csv` — column contract retained; row-level detail is deferred because
  the actionable unit today is the identity group, and per-row traceability is directly queryable
  from `import_staging_rows` by `source_row_key`.

The CSVs are analysis outputs. **They must never be consumed as mapping decisions.** UTF-8, no
secrets.
