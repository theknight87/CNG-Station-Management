# Stage A — the canonical Station and Unit hierarchy

*Prompt 21C. Migration 0046. **Built and verified locally; NOT deployed and NOT
committed to production.***

---

## 1. Why Stage A exists

Production holds one completed staging run,
`cdad1e5e-7faa-4f3b-9432-12a720f3dd64`, with 7,163 rows. `stations` and `units`
are both **0**. Nothing can be mapped to a hierarchy that does not exist, so
every asset-mapping question is blocked behind this one step. Stage A creates
that hierarchy and nothing else.

`stations_units` is the only staged family that states structure explicitly —
which Units belong to which Station — and it comes from a single sheet of a
single workbook. Asset workbooks *name* Stations without stating structure, so
they are not a source for creating one (CLAUDE.md §8).

## 2. What it does not do

It creates no station alias, no unit alias and no mapping decision. It resolves
no SRV, vessel, recovery tank, gas detector or hose. It imports no canonical
asset. It infers no Region and no Unit.

**Canal, Alex and Upper contribute zero rows to this source and therefore
receive zero Stations.** Their Stations are not manufactured from the asset
workbooks that mention them, and the absence is a finding, not a gap to fill.

Applying migration 0046 creates nothing at all. It installs three functions. The
hierarchy appears only when an operator calls `cng_stage_a_commit` with a
content-bound approval — a separate and separately authorized act.

## 3. Identity

| Entity | Identity | Enforced by |
| --- | --- | --- |
| Station | `(region_id, cng_normalize_name(station_name))` | `stations_region_norm_uq` |
| Unit | `(station_id, cng_normalize_name(unit_name))` | `units_station_norm_uq` |

Both were already database properties, so the pipeline **relies** on them rather
than re-implementing uniqueness in application code. `units_station_region_fk`
likewise already makes a Unit whose Region differs from its Station's
inexpressible.

Region is part of Station identity. Two Regions may hold the same name and stay
two Stations; no name is ever matched across Regions.

**Explicitly not identity, and used for nothing here:**

- the **job number** — 4 job numbers are reused across different Units in this
  very run, and 68 rows carry none. It is an attribute; its absence never blocks
  creating a Unit (principle #4).
- the compressor model, dispenser model, storage model, or any serial.
- similarity, suffix stripping, edit distance, or any other fuzzy rule.
- names appearing in **asset** sources.

## 4. Display names are never the comparison form

The normalized value is a comparison key. The stored `station_name` /
`unit_name` is the source's own text, taken verbatim from the row with the
lowest `(file, sheet, row)` for that identity.

That tie-break is deterministic **and is never exercised**: measured on this
run, **zero** Station identities and **zero** Unit identities carry more than one
distinct display spelling.

If that ever stops being true, `cng_stage_a_commit` **refuses**. Picking between
two spellings a human has not reconciled is the guess CLAUDE.md §8 exists to
prevent — and Prompt 21B's approval of the `/` rule was explicitly for
*comparison only*, so choosing which spelling to display was never approved.
This is asserted both ways (STAGEA-16a/16b).

## 5. The approval is bound to content, and fails closed

`cng_stage_a_commit(p_import_run_id, p_expected_manifest_fingerprint,
p_expected_preview_fingerprint)`.

Both fingerprints are **required** and are re-derived inside the commit's own
transaction. A NULL, a blank, or a stale value refuses. There is no
"approve the current state" path, because such an approval could drift between
preview and commit — precisely the failure mode migration 0041 was written to
close for mapping decisions.

- The **manifest fingerprint** binds the approval to the source workbook
  content.
- The **preview fingerprint** binds it to the exact proposal: every proposed
  entity's kind, Region, identity keys, display text and job number **plus the
  `source_row_hash` of the evidence behind it**. Change the evidence without
  changing the conclusion and the approval still lapses (STAGEA-13).

Preview, fingerprint and commit all read one function, `cng_stage_a_proposal`.
There is a single computation, so "what was approved" and "what was written"
cannot drift apart into two code paths.

### Gates, in order

1. an approval is actually presented (no NULL, no blank)
2. the run exists
3. the run is completed
4. the manifest fingerprint matches
5. the preview fingerprint matches
6. the run has not already been committed
7. every Region is a canonical Region
8. no identity carries two source spellings

## 6. Lineage

402 staging rows become 157 Stations and 188 Units. One row is **not** one
entity, and the schema does not pretend otherwise.

| Direction | How | Meaning |
| --- | --- | --- |
| entity → row | `stations`/`units` carry `import_batch_id`, `source_file`, `source_sheet`, `source_row` | the evidence for a canonical record is always reachable |
| row → entity | `import_staging_rows.committed_entity_id` + `committed_entity_kind` | the **finest** entity the row fed: its Unit where it names one, otherwise its Station |

Several rows may name one entity. On the real run: 340 rows link to a Unit, 62
(exactly the rows with no unit name) link to their Station.

`committed_entity_kind` is the one additive column in this migration. It is
nullable, so every existing row keeps its current meaning, and its CHECK is an
explicit allowlist so a later stage cannot widen it with free text.

A committed run can no longer be abandoned — the 0044 guard begins to bite the
moment lineage exists, so history is never quietly erased (STAGEA-35).

## 7. Authorization

EXECUTE on all three functions is `service_role` **only**. No browser role,
administrator included, can preview or commit the hierarchy — proved by
attempting it as `authenticated` and requiring `insufficient_privilege`
(STAGEASEC-5), not by reading a grant table.

No function takes an actor parameter, so the act cannot be attributed to someone
who did not perform it. The commit is `SECURITY DEFINER` with a pinned
`search_path`; the two read functions are deliberately **not** definer, so
nothing elevated is granted that the commit does not need.

The commit contains **no dynamic SQL** and names three literal targets:
`stations`, `units`, and the lineage columns of `import_staging_rows`. This is
re-derived from `pg_proc.prosrc`, not trusted from the migration comment
(STAGEA-30/31, STAGEASEC-10).

`authenticated` holds no write grant on `import_staging_rows`, so lineage cannot
be forged from a browser (STAGEASEC-6).

## 8. Verified at full scale, locally

A 402-row fixture was generated from the **structural skeleton** of the
production run — per-Station row counts, Unit counts and null counts — with
synthetic names. No Arabic identity string was transcribed by hand; that
transcription is itself the corruption risk this project exists to avoid, and
Arabic fidelity is proved separately by dedicated fixture rows (STAGEA-22) and
by the SEP-* normalization assertions.

Against that fixture, run through the real operator runner:

| | |
| --- | --- |
| source rows | 402 |
| Stations created | **157** |
| Units created | **188** |
| Stations with zero Units | **1** |
| staging rows linked | 402 (340 → Unit, 62 → Station) |
| Units whose Region ≠ their Station's | 0 |
| station aliases created | 0 |
| mapping decisions created | 0 |
| canonical assets created | 0 |

A drifted approval was refused, the authorized commit succeeded, and a replay
was refused — in that order, through the CLI, with the exit codes recorded.

## 9. Post-Stage-A asset match simulation (read-only, against production)

Run by inlining the proposal query; **nothing was deployed to production and
nothing was written**. Scope: the 1,104 `needs_station_mapping` rows across
Storage Vessels, Recovery Tanks, Gas Detectors and Hoses.

| Measure | Value |
| --- | --- |
| asset rows in scope | 1,104 |
| distinct raw source spellings | 329 |
| distinct normalized identities | 316 |
| **raw spellings gaining exactly one same-Region Station** | **78** |
| **normalized identities gaining exactly one** | **69** |
| **rows those cover** | **281** |
| **identities gaining more than one candidate** | **0** |
| identities gaining none | 247 (823 rows) |
| identities matching a Station only in a **different** Region | 1 |
| identities whose text matches a **Unit** name, not a Station | 15 |

**On the 78 vs 69 difference.** Prompt 21B's migration comment records 78; that
figure counts distinct **raw spellings**, and 78 raw spellings collapse to 69
normalized identities. Both are correct and they count different things. The
row coverage — 281 — and the zero multi-candidate count are identical under
either unit, so the STOP-listed facts hold. Measured both ways here so the
ambiguity cannot recur.

**Three things stay strictly distinct and none of them is a resolution:**

- a **Station** match is a candidate for `needs_station_mapping` only;
- the 15 identities whose text matches a **Unit** name are *not* Station matches
  and must never be resolved as one;
- the 1 identity matching only in another Region is **not** a match — Region is
  identity, and cross-Region matching is forbidden;
- `needs_equipment_mapping` (801 installed SRV rows) is a third, separate state
  that Stage A does not touch at all.

Every one of these remains an **explicit human decision** recorded through
`cng_admin_decide_staged_mapping`. Stage A proposes no mapping, writes no
decision, and auto-resolves nothing.

## 10. Status — COMMITTED TO PRODUCTION (Prompt 21D)

Migration 0046 was deployed in 21C-DEPLOY (45 → **46**, recorded once as
`20260917085835 stage_a_hierarchy`, file SHA-256
`478dd95c41bba156df4133304445e4a78ac7bd752d083e9a5eb82befde55bbc5`), proved
byte-exact by matching `pg_proc.prosrc` MD5 against the local approved build.

**The hierarchy is now committed.** `cng_stage_a_commit` was invoked **exactly
once** against the approved run with both approved fingerprints, immediately
after a final pre-commit guard re-ran the preview and matched every approved
value.

| | |
| --- | --- |
| import run | `cdad1e5e-7faa-4f3b-9432-12a720f3dd64` |
| manifest fingerprint | `764d3c0f…f091b8f` |
| preview fingerprint | `12941a1c0842a217dd5c7d52fcd416ec9282821704289d2977c671942eb5d90a` |
| **Stations created** | **157** |
| **Units created** | **188** |
| **staging rows linked** | **402** |

East 42/56 · West 40/58 · Delta 75/74 · Canal 0/0 · Alex 0/0 · Upper 0/0.

### What was verified after the commit

- **1** Station has zero Units — Delta, source row 352, exactly the approved one.
  **No Unit was invented for it.**
- All four reused job numbers (`2919ps003`, `CSKD0000459N-2`, `SC21006/030`,
  `SC21006/092`) are each held by **2 Units across 2 distinct Stations**. Nothing
  merged; job number is an attribute, never identity.
- **2** Units carry `job_number` NULL, exactly as approved. `job_number_raw`
  matches `job_number` on every row, so nothing was normalized away.
- Nothing was invented: 0 Stations carry a bay status or note, 0 Units carry a
  dispenser/hose/storage count or bay status, and 0 records are flagged
  `needs_review`. Missing stays missing.
- 0 duplicate Station identities, 0 duplicate Unit identities, 0 names spanning
  two Regions, 0 Units whose Region differs from their Station's.
- Every Station and every Unit carries its `import_batch_id`, file, sheet and
  row — 0 missing provenance, 0 without source support.

### Lineage, reconciled

All **402** structural rows are linked; **0** unlinked. The split is exactly what
0046 defines and nothing was forced into a one-row-one-entity shape:

| | |
| --- | --- |
| rows → a Unit (`committed_entity_kind = 'unit'`) | **340** |
| rows → their Station (`'station'`) | **62** |
| rows naming a Unit in source | 340 |
| rows with no Unit in source | 62 |

The two pairs agree exactly, so no row was classified against its own evidence:
0 rows are kind `unit` without a source unit name, and 0 are kind `station` with
one. 0 orphan lineage rows, 0 pointing at the wrong entity type, 0 linked rows
missing `committed_at`, and a **single** `committed_at` value across all 402 —
one transaction. All 188 Units are referenced by at least one row; the 62
Station-linked rows resolve to 32 Stations. **0** non-structural staging rows
were touched.

### The firewall held

`station_aliases` 0 · `unit_aliases` 0 · `import_mapping_decisions` 0 · all eight
canonical asset tables 0 · Canal, Alex and Upper 0 Stations / 0 Units · 0
Stations sourced from any batch other than the structural workbook.

### Replay

Not re-tested destructively. Gate 5's exact predicate now evaluates **true** with
402 satisfying rows, so a second call raises `unique_violation` before any write;
both identity unique constraints are present as a second barrier; and the refusal
path is already proved by local assertion STAGEA-27. The run is also now
un-abandonable, as the 0044 guard intends.

### Security, re-verified after the commit

46 migrations · 0 tables without RLS · Stage A EXECUTE: authenticated 0, anon 0,
service_role 3 · `cng_stage_a_commit` prosrc MD5 unchanged · `cng_normalize_name`
unchanged and still IMMUTABLE · `stations_region_norm_uq` still
`UNIQUE (region_id, normalized_name)` · `units_station_norm_uq` still
`UNIQUE (station_id, normalized_name)` · 0 browser write grants on
`import_staging_rows` · 0 anon grants on the hierarchy.

### Stage B is now unblocked, and still entirely a human decision

Re-measured against the real hierarchy: **78** raw spellings = **69** normalized
identities = **281** asset rows gain exactly one same-Region Station candidate;
**0** gain more than one; 1 identity (5 rows) matches only in another Region and
stays unmatched, because Region is identity.

Of the 281 — storage vessels 100, recovery tanks 91, gas detectors 64, hoses 26 —
240 sit under a Station with exactly one Unit, 38 under several, 3 under none.
**"One Unit under the candidate Station" is a narrowing, not a determination.**
Assigning those 240 by count is precisely the distribution rule CLAUDE.md
forbids. All 281 remain `needs_station_mapping`; every lifecycle count is
unchanged and `import_mapping_decisions` is still 0.
