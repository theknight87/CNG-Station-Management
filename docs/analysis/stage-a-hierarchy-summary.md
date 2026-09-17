# Stage A — canonical Region → Station → Unit hierarchy (Prompt 21A design review)

**READ-ONLY.** No Station, Unit, alias, mapping decision or canonical asset was created. No
migration, no normalization change, no deployment. Every figure below is computed from the
persisted production staging run `cdad1e5e-7faa-4f3b-9432-12a720f3dd64`
(fingerprint `764d3c0f…5f091b8f`), and every query in the artifacts beside this file was
**executed against production** before being shipped.

---

## 1. What the structural sources actually are

`stations_units` — **402 rows**, one row per *asset line* (a dispenser/storage entry), not one per
Unit. That is why 103 `(region, station, unit)` triples repeat across 285 rows. Fields present on
all 402: `region`, `station_name`, `station_name_raw`, `unit_name`, `unit_job_number`,
`compressor_model`, `storage_model`, `storage_serial`, `dispenser_model`, `dispenser_serial`,
`dispenser_bay_label`.

`unit_attributes` — **325 rows**, operating attributes keyed to a Unit: `compressor_model`,
`recovery_tank_model`, `gas_detector_model`, `storage_model`, `dispenser_model`,
`total_running_hours`, `avg_hours_per_day`, `avg_gas_sales_per_day_raw`, `bay_status_raw`, and the
*reported* counts (`dispenser_count_reported_raw`, `hose_count_reported_raw`,
`storage_count_reported_raw`). These enrich a Unit; they do not establish one.

**Completeness, as found — nothing inferred:**

| | |
| --- | ---: |
| rows with NULL `region` | **0** |
| rows with NULL `station_name` | **0** |
| rows with NULL `unit_name` | **62** |
| rows with NULL `unit_job_number` | 68 |

A missing Job Number never blocks creation (principle #4), so those 68 are not an obstacle.

---

## 2. Proposed canonical hierarchy — deterministic

| | Count |
| --- | ---: |
| Regions | **6** (already seeded; Stage A creates none) |
| **Stations** | **157** |
| **Units** | **188** |

| Region | Stations | Units |
| --- | ---: | ---: |
| Delta | 75 | 74 |
| East | 42 | 56 |
| West | 40 | 58 |
| Canal / Alex / Upper | 0 | 0 |

**156 Stations are fully deterministic.** One Station has only rows whose `unit_name` is NULL, so
it would be created **with no Units** — which CLAUDE.md principle #19 and decision D7 explicitly
call a valid record, not an incomplete one. No Unit is invented for it.

**No Unit is proposed without a named Unit in the source.** The 62 NULL-`unit_name` rows contribute
Station evidence only.

**Conflict checks — all clean:**

| Check | Result |
| --- | --- |
| same Station name in more than one Region | **0** |
| same `(region, station, unit)` with conflicting job number | **0** |
| same `(region, station, unit)` with conflicting compressor model | **0** |
| one job number reused across different Units | **4** — flag, not a blocker |

So **none of the Phase-8 STOP conditions fired**: there is no conflicting Region assignment, and
every named Unit links to exactly one `(region, station)`.

---

## 3. Region coverage — the real limit on Stage A

The structural source covers **East, West and Delta only**, exactly as CLAUDE.md §8 records.

| Region | structural Stations | asset identities | asset rows | A: Station exists | B: asset-only | C: other-Region candidate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| East | 42 | 5 | 6 | 0 | 5 (6 rows) | 0 |
| West | 40 | 31 | 164 | 9 (82 rows) | 22 (82 rows) | 0 |
| Delta | 75 | 95 | 298 | 69 (199 rows) | 26 (99 rows) | 0 |
| Canal | **0** | 51 | 171 | 0 | 51 (171 rows) | 0 |
| Alex | **0** | 61 | 199 | 0 | 60 (194 rows) | 1 (5 rows) |
| Upper | **0** | 86 | 266 | 0 | 86 (266 rows) | 0 |
| **Total** | **157** | **327** | **1,104** | **78 (281 rows)** | **249 (818 rows)** | **1 (5 rows)** |

**249 asset identities covering 818 rows have no structural Station at all.** Stage A cannot create
them, and **they must not be created from asset names** — an asset row is evidence that a Station
was *referenced*, not evidence of its canonical identity, Region or Unit structure. Those 818 rows
need owner-supplied structure or a further source.

---

## 4. Separator normalization — proof, Region-aware

Proposed comparison rule: after the existing `cng_normalize_name()` (which **already strips
tatweel**), collapse whitespace around `/` so `A / B`, `A/ B`, `A /B` and `A/B` compare equal.

```
أتــريب / بنــها 1        →  current: "اتريب / بنها 1"   →  proposed: "اتريب/بنها 1"
أشــكر / فاقــوس 3        →  current: "اشكر / فاقوس 3"   →  proposed: "اشكر/فاقوس 3"
إكــراش / ديــرب نجــم   →  current: "اكراش / ديرب نجم" →  proposed: "اكراش/ديرب نجم"
```

| # | Question | Result |
| --- | --- | --- |
| 1 | structural identities whose comparison form changes | **53** |
| 2 | asset identities gaining exactly ONE candidate, **Region-aware** | **78** |
| 3 | asset rows covered, Region-aware | **281** |
| 4 | asset identities gaining MORE than one candidate | **0 — no new ambiguity** |
| 5 | **same-Region collisions** (two distinct Stations folding together) | **0** (baseline is also 0) |
| 6 | cross-Region collisions | **0** |

**No same-Region collision is introduced.** Collapsing whitespace around a fixed separator is
deterministic, so principle #7 permits it — but it is a **normalization code change and was not
made**.

*Correction to Prompt 20H:* that report gave 63 identities / 214 rows. That measurement folded the
raw text and ignored Region. The Region-aware figure computed here — **78 identities / 281 rows** —
supersedes it. One identity matches a structural Station **in a different Region** (Alex, 5 rows);
it is Category C and must never be matched automatically.

---

## 5. Owner review queue for Stage A

Grouped, not row-by-row. Total owner decisions to unblock Stage A: **small.**

| # | Category | Items | Rows | Decision required |
| --- | --- | ---: | ---: | --- |
| 1 | **Deterministic Station creation** | 156 Stations | 402 | approve the set; no per-Station judgement |
| 2 | **Deterministic Unit creation** | 188 Units | — | approve the set |
| 3 | **Station with no Units** | 1 | — | confirm a Station with zero Units is correct |
| 4 | **Job number reused across Units** | 4 | — | confirm the reuse is real; identity is unaffected |
| 5 | **Separator normalization rule** | 1 ruling | 281 | approve or decline the §4 rule |
| 6 | **Cross-Region asset identity** (`رشدي` Alex+West, `الداخلية` Alex+Upper) | 2 | 17 | one raw name used in two Regions — never auto-resolved |
| 7 | **Other-Region candidate** (Category C, Alex) | 1 | 5 | confirm or reject; never automatic |
| 8 | **No structural Station** (Canal / Alex / Upper, plus B in East/West/Delta) | 249 | 818 | Stage B work; needs structure the current sources do not contain |

Rows 1–5 are what Stage A itself needs. Rows 6–8 belong to asset mapping and are listed so the
scale is visible.

**`ابنوب` = `ابنوب اسيوط` remains the only approved Station alias and was not extended.** No alias
was created (`station_aliases` = 0). Duplicate structural rows are **aggregated, never merged as
identities** — 402 rows collapse to 157 Stations because the workbook repeats a Unit per asset
line, which the grouping proves, not assumes.

---

## 6. Proposed Stage A import architecture (design only)

Reuse the Prompt 20F shape; it already solves most of this.

**Creates automatically (deterministic, no judgement):** Stations from distinct
`(region, station_name)`, and Units from distinct `(region, station_name, unit_name)` where
`unit_name` is non-NULL. Attributes copied through verbatim; **a missing value stays NULL**.

**Requires owner approval before the run:** the §4 normalization rule; the no-Units Station; the
4 job-number reuses. Approvals are recorded the way the project already records rulings — as
**rows**, in the existing `import_mapping_decisions`-style shape, admin-only, written by a
`SECURITY DEFINER` function that derives the actor server-side. No approval is inferred from a
flag or a config value.

**Never creates:** a Station or Unit from an asset row, a Unit for a Station that names none
(decision D7), a Region (all 6 are seeded), or any value the source does not contain.

| Property | Mechanism |
| --- | --- |
| preview-first | a read-only RPC returning the exact 157/188 it would create, with per-row evidence counts |
| scoped | every statement filtered to `import_run_id = cdad1e5e-…` |
| content-bound | each staged row's `source_row_hash` re-derived **server-side**; a mismatch fails the run (0041 precedent) |
| atomic | one function, one transaction — a partial hierarchy cannot exist |
| replay-safe | partial unique index on `(import_run_id)` for completed Stage A runs, mirroring `import_runs_manifest_fingerprint_uq` |
| idempotent | a second run over identical content is refused, not re-applied |
| fail-closed | any stale hash, any missing approval, any unexpected count → abort, write nothing |
| rollback | one transaction; abandonment is a **state**, never a delete, mirroring `cng_abandon_import_run` |
| lineage | `import_staging_rows.committed_entity_id` / `committed_at` link each source row to the entity it produced |
| Region proof | taken from the staged `region` field, which is non-NULL on all 402 rows — never inferred from a name |
| RLS | canonical writes stay `service_role`-only through the definer function; no browser gains authority |

---

## 7. Predicted effect on the 1,104 asset blockers

Simulated read-only against the proposed 157-Station hierarchy. **Station match and Unit match are
kept strictly separate: a known Station does not make an asset resolved.**

| Outcome after Stage A | Identities | Rows |
| --- | ---: | ---: |
| Station becomes exactly matchable (Region-aware, Category A) | 78 | **281** |
| Station still needs review — no structural Station exists (Category B) | 249 | **818** |
| Station candidate exists only in another Region (Category C) | 1 | **5** |
| **Total** | **327** | **1,104** |

Of the 281 that gain a Station, **none becomes resolved**: each then moves to **Unit mapping**, and
the four families additionally carry their own `needs_unit_mapping` / `needs_equipment_mapping`
lifecycle. The 281 figure depends on the §4 rule being approved; **without it the number is 0**,
because zero asset identities match any structural name today.

---

## 8. Artifacts

| File | What it is |
| --- | --- |
| `stage-a-hierarchy-summary.md` | this document |
| `stage-a-region-coverage.csv` | the §3 table, machine-derived, no Arabic to mistranscribe |
| `stage-a-station-review.sql` | regenerates the full 157-Station queue verbatim from production |
| `stage-a-unit-review.sql` | regenerates the full 188-Unit queue verbatim from production |

Both queries were **executed against production** and reconcile exactly: 157 Station rows covering
all 402 source rows (156 deterministic + 1 no-Units), and 188 Unit rows with 0 job-number conflicts.

Arabic Station and Unit identities are deliberately **not transcribed into CSV by hand** — retyping
identity text is precisely the corruption risk this exercise exists to eliminate. Run the queries to
obtain them byte-exact.
