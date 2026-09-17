# Stage B, step one — batch Station mapping

*Prompt 22A. Migration 0047. **Built and verified locally; NOT deployed and NO
production mapping decision written.***

---

## 1. What this confirms, and what it does not

Stage A committed 157 Stations and 188 Units. 281 staged asset rows now resolve,
by exact Region-aware normalized name, to exactly one canonical Station each.
This records that as **Station-only** confirmations, in one transaction, bound to
the exact preview an owner read.

It writes no Unit and no equipment parent of any kind. It creates no alias,
imports no canonical asset, and touches no staging row outside the approved set.

## 2. It reuses the existing architecture

No parallel mapping system was invented. `import_mapping_decisions` (0039) with
its content binding (0041) already holds exactly this shape: one decision per
source row, keyed by `source_row_key`, bound to the `source_row_hash` the decider
actually read, superseding rather than overwriting, with
`imd_one_active_per_source_row` making "exactly one active decision" a database
property. The batch writes the same rows the single-row path writes.

**The resulting status is not a new rule either.** `cng_admin_decide_staged_mapping`
already derives it and the batch uses the identical expression:

| Family | Before | After Station-only confirmation |
| --- | --- | --- |
| Storage Vessels | `needs_station_mapping` | `needs_unit_mapping` |
| Recovery Tanks | `needs_station_mapping` | `needs_unit_mapping` |
| Gas Detectors | `needs_station_mapping` | `needs_unit_mapping` |
| Hoses | `needs_station_mapping` | `needs_unit_mapping` |

All four behave identically because all four carry the same
`station_id NOT NULL` / `unit_id NULL` shape. This is the lifecycle CLAUDE.md §4
states; no step was added or skipped to make a batch convenient. Station
confirmation is **not** Unit confirmation and **not** equipment resolution.

## 3. One deliberate deviation from the prompt, and why

Prompt 22A asked for a `service_role`-only function. **The schema forbids it.**

`import_mapping_decisions.decided_by` is `NOT NULL REFERENCES app_users(id)`,
because CLAUDE.md §9 requires every mapping change to record who made it and §10
forbids a forgeable actor column. `service_role` carries no Clerk subject, so a
`service_role` batch could satisfy that column only by

- accepting an actor parameter — which Prompt 22A itself forbids, or
- making the column nullable — which would create unattributed human rulings.

So the actor is derived server-side from the verified Clerk subject via
`cng_require_admin()`, exactly as the single-row path has since 0039, and EXECUTE
is granted to `authenticated` only, where **the admin check, not the grant, is
the gate**. Every non-admin role is refused, proved by attack (STAGEBSEC-4..9).

Stage A differs precisely because a Station carries no `created_by`: creating the
hierarchy is an operator action with no human ruling to attribute, so it could be
— and remains — `service_role` only (STAGEBSEC-14).

## 4. The candidate set is derived, never supplied

A candidate is a staged row of one of the four pre-import families, still
`needs_station_mapping`, whose normalized source Station name matches **exactly
one** canonical Station **in its own Region**.

Everything else is excluded by construction:

| Excluded | Why |
| --- | --- |
| no same-Region match | nothing to confirm; never fuzzy-matched |
| match only in another Region | Region is identity (§8); a cross-Region match is not a match |
| already past `needs_station_mapping` | this step is done for that row |
| already carrying an active decision | one active decision per source row |
| installed SRVs | their canonical `station_id` is nullable; they map in the canonical table |

There is no similarity, suffix stripping, edit distance or alias lookup.
`cng_normalize_name` is the only comparison, and it is the same deployed function
Stage A used.

**Same-Region ambiguity is unreachable, not merely unhandled**: two Stations in
one Region cannot share a normalized name, because `stations_region_norm_uq`
forbids it. Proved by attempting the duplicate (STAGEB-36), so the `exactly one`
test can only ever exclude a row for having *zero* matches.

## 5. Review is grouped; the commit is not

An owner reads **69 Region-aware Station identities**, not 281 rows. Each group
carries every raw source spelling that folded into it, the exact staging row ids,
their `source_row_hash` evidence, the family split and the current lifecycle
states. Grouping is a review convenience — **the commit stays bound to every
individual row**.

Each group is classified `DETERMINISTIC STATION CANDIDATE` or `OWNER REVIEW`, and
anything with a pre-existing decision or mixed lifecycle states is separated out
rather than folded into the batch.

## 6. The approval is content-bound and fails closed

`cng_stage_b_station_commit(run, expected_manifest_fp, expected_preview_fp, reason)`.
Both fingerprints are required and re-derived inside the transaction; NULL, blank
or stale refuses.

The preview fingerprint folds in, **per candidate row**: staging row id, Region
id, Station id, Station normalized identity, Station display name,
`source_row_hash`, `mapping_status`, and whether a decision already exists. So a
single comparison covers every drift the prompt lists:

| Drift | Caught by |
| --- | --- |
| source row changed | `source_row_hash` |
| canonical Station changed, renamed or deleted | station id + name + normalized identity |
| Region changed | region id |
| normalization result changed | normalized identity |
| row `mapping_status` changed | status |
| a decision appeared after preview | `has_active_decision`, plus an explicit second gate |
| candidate became ambiguous | set membership — the row leaves the set |
| candidate disappeared | set membership |

## 7. Verified at full scale, locally

Against a 1,104-row fixture over the real Stage A hierarchy (157/188), driven
through the deployed functions:

| | |
| --- | --- |
| preview | **69 groups / 281 rows**, 69 deterministic, 0 owner-review |
| families | storage vessels 100 · recovery tanks 91 · gas detectors 64 · hoses 26 |
| decisions written | **281** across **69** Stations |
| Unit ids written | **0** |
| equipment ids written | **0** (structurally impossible — §8) |
| Region mismatches | 0 |
| `reviewed_source_row_hash` mismatches | 0 |
| other-Region rows decided | 0 |
| remaining undecided blockers | **823** |
| Stations / Units after | 157 / 188, unchanged |
| aliases / canonical assets after | 0 / 0 |
| audit rows | 281, one per decision |

**Atomicity was proved, not assumed**: the batch was run inside an explicit
transaction that wrote 281 decisions and was then rolled back — **0 persisted**.

**Replay was refused** on a second identical commit, at the fingerprint gate
(because `has_active_decision` had flipped), leaving 281 unchanged. The
already-decided gate and `imd_one_active_per_source_row` stand behind it.

Nine refusal scenarios were each proved to leave **zero** decisions behind:
missing, blank and wrong fingerprints; a wrong manifest; a changed source hash; a
moved lifecycle status; a renamed canonical Station; and a changed Region.

## 8. Equipment inference is structurally impossible

`import_mapping_decisions` has no `compressor_id`, `dispenser_id`,
`storage_vessel_id`, `recovery_tank_id`, `gas_detector_id` or `hose_id` column at
all. STAGEB-21 asserts that from `information_schema`, so equipment parentage
cannot be recorded here even by mistake — it is not merely omitted from the code.

The commit contains no dynamic SQL and names two literal targets,
`import_mapping_decisions` and `audit_logs`, re-derived from `pg_proc.prosrc`.

## 9. The remaining 823 rows / 247 identities

Read-only analysis. **No fuzzy match is proposed, no Station is created from an
asset name, and no alias is extended.**

| Region | Rows | Identities | Canonical Stations in that Region |
| --- | --- | --- | --- |
| Upper | 266 | 85 | **0** |
| Alex | 199 | 59 | **0** |
| Canal | 171 | 51 | **0** |
| Delta | 99 | 25 | 75 |
| West | 82 | 22 | 40 |
| East | 6 | 5 | 42 |

Families: storage vessels 333 · recovery tanks 312 · gas detectors 155 · hoses 23.

| Reason no candidate exists | Rows |
| --- | --- |
| **Region has zero canonical Stations** — no structural source covers it | **631** |
| no canonical Station carries this name in that Region | 178 |
| name matches a **Unit** name, not a Station name | 9 |
| name matches a Station only in **another Region** | 5 |

All 823 rows carry a raw source Station name, so nothing is lost — the evidence
is present and the canonical counterpart is not.

**631 of the 823 — more than three quarters — are not a mapping problem at all.**
Alex, Canal and Upper have no structural source, so Stage A correctly created no
Stations there. These rows need a source that states those Stations' structure;
inventing Stations from asset names is exactly what CLAUDE.md §8 forbids. The
open `unmatched_station` import issues (2,435 across all families) already record
this.

## 10. Status

**NOT DEPLOYED. NO PRODUCTION MAPPING DECISION WRITTEN.** Production remains at
46 migrations with `import_mapping_decisions` = 0, `station_aliases` = 0, all
canonical asset tables 0, and the hierarchy at 157/188.

Migration 0047 must be deployed before the preview or commit functions exist in
production. The production preview in §11 was computed **read-only by inlining
the identical derivation** (`docs/analysis/stage-b-station-preview.sql`), which
was validated as byte-identical to the deployed functions — same counts, same
fingerprint — against a local database that has 0047.

## 11. Production read-only preview

| | |
| --- | --- |
| import run | `cdad1e5e-7faa-4f3b-9432-12a720f3dd64` |
| manifest fingerprint | `764d3c0f…f091b8f` |
| **preview fingerprint** | **`a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769`** |
| candidate groups | **69**, all `DETERMINISTIC STATION CANDIDATE` |
| candidate rows | **281** |
| owner-review groups | **0** |
| rows already decided | 0 |
| families | 100 / 91 / 64 / 26 |
| distinct raw spellings | 78 |
| group size | 1 to 32 rows |

By Region: **Delta 60 groups / 199 rows**, **West 9 groups / 82 rows**. East
contributes no candidates — its staged asset names do not match its canonical
Station names, and that is a finding, not something to resolve by loosening the
comparison.

The fingerprint must be **re-derived by the deployed function** at approval time.
It is stable as long as no staging row, Station, Region or lifecycle status
changes; it is not a value to carry across a schema change.
