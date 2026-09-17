# The 823 Station-unconfirmed rows — forensic analysis (Prompt 25A)

**Read-only.** No mapping decision, alias, Station, Unit, canonical asset,
`gas_detector_presence` row, staging change or migration was created. Production was
re-verified identical before and after.

## 1. What the 823 actually is

Population definition, using the existing approved semantics and inventing none: staged rows
whose `target_table` is one of the four NOT-NULL-`station_id` families, whose
`mapping_status` is `needs_station_mapping`, and which carry no active
`import_mapping_decisions` row.

**823 rows · 823 distinct source keys · 823 distinct 64-char hashes · 0 duplicates.**
All 823 have `station_id` NULL, `unit_id` NULL and a non-empty raw Station name and Region.

### A SCOPE CORRECTION THAT MATTERS

The 823 is **not** the whole Station-unconfirmed population. It is the four families that
were *Prompt-21 blockers*. Separately:

| Population | Rows | In the 823? |
| --- | --- | --- |
| Four blocker families, undecided | **823** | yes |
| **Installed SRVs, `needs_station_mapping`, undecided** | **1,599** | **no** |

Installed SRVs were never blockers because `installed_relief_valves.station_id` is nullable.
**0 installed SRV and 0 warehouse rows sit inside the 823** — so Phase 12/13's installed-SRV
line items are legitimately zero *within* the 823, and the 1,599 are reported separately
rather than silently folded in.

## 2. Reconciliation against Prompt 22D — one drift

| Measure | 22D | Recomputed | |
| --- | --- | --- | --- |
| Rows | 823 | **823** | ✓ |
| Region-aware identities | 247 | **247** | ✓ |
| Upper / Alex / Canal / Delta / West / East | 266/199/171/99/82/6 | **identical** | ✓ |
| Rows in zero-Station Regions | 631 | **636** | **DRIFT** |
| Cross-Region-only rows | 5 | **5** | ✓ |
| Rows matching a Unit name | 9 | **9** | ✓ |

**The 631 was wrong.** 266 + 199 + 171 = **636**, verified twice by independent queries
(636 rows / 195 identities in zero-Station Regions; 187 / 52 elsewhere; 636 + 187 = 823).
The 5-row gap is explained: the 5 cross-Region-only rows are **in Alex**, which is itself a
zero-Station Region, so they are a *subset* of the 636, and an earlier pass subtracted them
as though they were a separate category. Nothing in production changed; a reported figure was
arithmetically wrong and is corrected here.

Identity shape: 71 singleton identities, 176 multi-row, largest group 23, mean 3.33 rows.
Only 2 identities carry ≥10 rows. **Resolving one identity unlocks ~3 rows on average** —
there is no large lever hiding here.

## 3. Canonical coverage — verified exactly

East 42/56 · West 40/58 · Delta 75/74 · Canal 0/0 · Alex 0/0 · Upper 0/0.

## 4. THE DECISIVE RESULT: no autonomous mapping is available

Against same-Region canonical Stations, over all 823 rows:

| Test | Rows |
| --- | --- |
| Exact raw name match, same Region | **0** |
| Approved normalized identity match, same Region — exactly one candidate | **0** |
| Same-Region match with multiple candidates | **0** |
| No same-Region Station candidate | **823** |

The approved Stage B evidence rule — exactly one same-Region normalized Station — yields
**zero candidates in the entire 823**. The 281-row batch genuinely exhausted that class.
Bucket A is empty, and no row in the 823 may be mapped autonomously.

## 5. Cross-source search (Phase 5)

| Question | Identities |
| --- | --- |
| Appears as a Station in Stage A structural source, same Region | **0** |
| Appears as a Unit name in Stage A, same Region | 9 |
| Appears as a Station in Stage A, other Region | 1 |
| Overlaps the already-confirmed 281 | **0** |
| Also appears in installed/warehouse SRV source, same Region | 88 |

The 88 SRV corroborations prove the **name exists in that Region in another workbook**. They
do **not** connect it to a canonical Station, because those SRV rows are themselves
Station-unconfirmed. Corroboration of existence is not identification.

## 6. The 9 Unit-name identities — the strongest class, still not autonomous

9 rows / 9 identities (East 4, West 5), each matching exactly **one** Unit under exactly
**one** parent Station. **All 9 end in a digit.** Discovery-only test of decision D2
(`<base> <n>` is Unit *n* of Station `<base>`): for **9 of 9**, the identity minus its
trailing digit equals the normalized name of that Unit's parent Station — **0 mismatches**,
and **0** cases where the base names more than one Station. No contradiction found.

This is internally consistent and clean. It is still **E2 / Bucket B**, not E1, because §8
states D2 "may **propose** an alias, and a human confirms it", and because digit-stripping is
a normalization rule the system does not have. Applying it autonomously would be inventing
one. These 9 are the best owner-confirmation candidates in the population.

## 7. Cross-Region firewall (Phase 9)

1 identity / 5 rows, source Region **Alex**, candidate Station in **West**, spanning 3
families, from `شهادات الفحص والمعايرة للمناطق .xlsx`. **Must not be mapped**: Region is part
of Station identity, Alex has no canonical Stations at all, and a West Station cannot host an
Alex asset. Bucket G.

Also measured: exactly **1** normalized name appears in two Regions inside the 823 (which is
why 247 region-aware identities reduce to 246 names), and **0** canonical Station names exist
in more than one Region today — so Region-scoped identity is currently unambiguous.

## 8. Zero-Station Regions — a real, previously unexamined source

Upper 266 rows / 85 identities · Alex 199 / 59 · Canal 171 / 51 (636 / 195).

**0 Stage A structural rows exist for these three Regions** — confirmed, which is why they
have no Stations.

**But 123 `unit_attributes` rows do** (Alex 45, Canal 38, Upper 40 — 123 distinct names),
carrying Region, a site name, compressor model (121), reported dispenser count (121) and
reported storage count (115). **79 of the 195 unresolved zero-Region identities — 233 rows —
appear by name in that source, in the same Region.**

**Its source file is `Station data base.xlsx` / Sheet1** — precisely the workbook CLAUDE.md §8
names as mixing station-level and unit-level naming in one column. That is not a guess; it is
demonstrated against the Regions where the answer is already known: of its 194 East/West/Delta
rows, **131 match a canonical Station name and 107 match a canonical Unit name** — sums to 238
over 194 rows, so many rows match at **both levels**. In the zero-Station Regions, 36 of 123
names end in a digit and 123 names collapse to 107 digit-stripped bases, 16 of which carry
multiple numbered rows.

**Conclusion: Z2, never Z1.** The file evidences that a *site* of that name exists in that
Region. It does not state whether a row is a Station or a Unit, and states no Station→Unit
parentage. Creating Stations from it row-by-row is exactly the duplicate-and-mis-level error
§8 exists to prevent. There is **no Z1 identity anywhere in the 823**.

## 9. Resolution buckets — all 823 rows, one bucket each

| Bucket | Rows | Identities |
| --- | --- | --- |
| A — existing Station, strong evidence | **0** | 0 |
| B — existing Station, owner confirmation required (the 9 D2 cases) | **9** | 9 |
| C — new Station structurally supported (Z1) | **0** | 0 |
| D — Station name corroborated, hierarchy/Unit unknown (Z2) | **258** | 86 |
| E — no sufficient Station evidence | **551** | 151 |
| F — conflict / multiple candidates | **0** | 0 |
| G — cross-Region-only, blocked | **5** | 1 |
| **Total** | **823** | **247** |

Rows sum to 823 and identities sum to 247, so no row *and* no identity spans two buckets.
B: East 4 / West 5. D: Alex 103, Upper 71, Canal 54, Delta 30. E: Upper 195, Canal 117, Alex
91, West 77, Delta 69, East 2.

## 10. Family impact — and a 77-row correction

| Family | Rows | Identities | Would create an asset | Recorded ABSENCE |
| --- | --- | --- | --- | --- |
| Storage vessels | 333 | 177 | 333 | 0 |
| Recovery tanks | 312 | 175 | 312 | 0 |
| Gas detectors | 155 | 155 | **78** | **77** |
| Hoses | 23 | **1** | 23 | 0 |
| **Total** | **823** | 247 | **746** | **77** |

**77 of the 823 carry `creates_detector_record = false`** — evidence that an area has *no*
detector. Even with Station confirmation they would create no device; they belong to
`gas_detector_presence`. So resolving all 823 unlocks at most **746** canonical assets, not
823. All 23 hose rows share a single Station identity.

## 11. Contradiction analysis

0 identities with multiple same-Region candidates · 0 canonical names spanning Regions ·
0 D2 base mismatches · 0 bases naming multiple Stations · 1 identity spanning two Regions
inside the 823 (a source-side observation, not a canonical conflict) · 0 job-number conflicts,
because **no job number exists in this population at all**.

## 12. Evidence inventory — what the 823 actually carries

Present on all 823: `region`, `source_station_name_raw`, `serial_number`, `serial_status`,
`next_due_date`, and NULL `station_id` / `unit_id`. Partial: `last_calibration` 800,
`notes` 800, `region_raw` 668, `manufacturer`/`location_raw`/`compressor_context_raw` 645,
detector `area_type_raw`/`presence` 155, hose `test_pressure`/`working_pressure` 23.

**IDENTITY EVIDENCE: `region` + `source_station_name_raw` only.**
**CONTEXT ONLY:** manufacturer, compressor model, `location_raw` (equipment kind),
`area_type_raw` (area class), pressures, dates, serials.
**ABSENT ENTIRELY: no job number, no Station code, no Unit name/number/code, no address,
no customer/site identifier, no cross-reference field.** A full key census of `normalized`
found no such key on any of the 823 rows.

## 13. The safest next write scope is NOT in the 823

**215 installed-SRV rows / 27 identities have exactly ONE same-Region canonical Station
candidate** (Delta 118, West 62, East 35), with **0 multi-candidate rows** and 0 already
decided. This is the *identical* evidence class that justified the approved 281-row batch, and
it has never been worked because installed SRVs were not Prompt-21 blockers.

Ranked by evidence strength:

1. **Installed-SRV Station batch — 215 rows / 27 identities.** Same approved rule, same
   deployed Stage B mechanism, same Admin-gated commit. Would move 215 rows
   `needs_station_mapping → needs_unit_mapping`. Imports nothing by itself.
2. **The 9 D2 owner-confirmation cases.** Tiny, clean, fully evidenced bar the owner ruling.
   Needs an explicit confirmation step, not a rule change.
3. **Nothing else.** Buckets D, E and G require new evidence, not a cleverer rule.

## 14. What is missing, per bucket

- **D (258 rows / 86 identities):** a source stating, per site, whether the name is a Station
  or a Unit, and the Station→Unit parentage. `Station data base.xlsx` gives names and
  attributes but not level.
- **E (551 / 151):** any source connecting the name to a canonical Station, or a structural
  source for its Region.
- **G (5 / 1):** a source placing that name in Alex, or an owner ruling that the Alex rows
  belong to the West Station — which would still be a human decision, not an inference.
- **B (9 / 9):** an explicit owner confirmation of the D2 reading for those exact 9 names.

---

## Prompt 25B — the installed-SRV 215-row batch: STOPPED at a design finding

**Read-only.** No decision, alias, Station, Unit, asset, presence row, staging change or
migration was created. Production was re-verified identical.

### The candidate set reproduces exactly

Recomputed from scratch, not from previously reported ids: **215 rows / 27 identities**,
Delta 118 · West 62 · East 35, **0 multi-candidate**, 215 distinct source keys, 27 distinct
Station targets, 27 raw spellings (1:1 with identities). Re-run under the *exact deployed
semantics* (run-scoped, `outcome NOT IN (rejected, excluded, replayed)`, `stations.normalized_name`)
it is still **215** — and `stations.normalized_name` is confirmed identical to
`cng_normalize_name(station_name)` on all 157 Stations, so the two derivations cannot diverge.

Every firewall is clean: **0** overlap with the 281 decisions by key *or* by hash, **0** overlap
with the four-family 823, **0** Region mismatches, **0** identities spanning two Regions, **0**
identities pointing at two Stations, **0** canonical names in two Regions, **0** contradictions.
All 215 qualify on all twelve per-row checks.

**One difference from the 281 batch, reported rather than glossed:** the 215 carry **201 distinct
source hashes**, not 215. Seven groups (21 rows, largest 3) share a hash because their
`source_raw` is byte-identical — 7 distinct payloads across 21 genuinely different spreadsheet
rows, i.e. repeated valves (principle 16), and **no hash group straddles two identities**. The
0041 content binding is per `(source_row_key, hash)` and `source_row_key` is unique, so binding
still holds — but any fingerprint must key on the **key**, never assume hash uniqueness.

### Why it STOPPED: the schema forbids it, deliberately

`cng_stage_b_station_candidates` filters `target_table IN ('storage_vessels','recovery_tanks',
'gas_detectors','hoses')`, and the commit's `CASE target_table` has no installed-SRV branch. But
that is only the surface. **`import_mapping_decisions` itself carries two CHECK constraints:**

- `imd_target_ck` — `target_table = ANY (ARRAY['storage_vessels','recovery_tanks','gas_detectors','hoses'])`
- `imd_asset_type_ck` — pairs each of those four with its `asset_type`

plus `asset_type NOT NULL`. An installed-SRV decision row is therefore **inexpressible**, three
times over. This is not an oversight: **migration 0039 created that table to resolve rows that
cannot exist canonically without a Station**, i.e. the four families whose `station_id` is NOT NULL.

**`installed_relief_valves.station_id` is NULLABLE**, and `irv_status_shape_ck` explicitly permits
`needs_station_mapping` with Station and Unit NULL, with `irv_unmatched_station_evidence_ck`
requiring only the raw source name — which all 1,599 carry. **A Station-unconfirmed installed SRV
is a first-class canonical record.** Nothing about these 215 is blocked.

**PHASE 3 ANSWER: DOES NOT GENERALISE** — and extending it would relax a constraint that encodes a
real architectural boundary, on a table holding 281 live decisions.

### The designed path already exists

`cng_admin_map_srv(p_srv_id, p_station_id, p_unit_id, p_parent_kind, p_parent_id,
p_expected_updated_at, p_reason)` is **deployed**, admin-gated, SECURITY DEFINER, row-version
guarded and audited, and derives `needs_unit_mapping` exactly when `p_unit_id IS NULL` — the
precise outcome this batch wants. It operates on **canonical** SRVs, which is where §4 and §9 put
this workflow ("appears in Global SRV Management labelled *Needs Station Mapping*").

So the architecture is a division, not a gap:

| Family | `station_id` | Where Station is decided |
| --- | --- | --- |
| The four blocker families | NOT NULL | **at staging**, via `import_mapping_decisions` (Stage B) |
| Installed SRVs | **nullable** | **after import**, via `cng_admin_map_srv` (Admin → Data Quality) |

Extending Stage B to installed SRVs would build a *second* Station-mapping path for a family that
already has one — the duplication this prompt's own Phase 13 forbids.

### Migration decision

**MIGRATION REQUIRED = YES for the route this prompt assumes** (widen `imd_target_ck`,
`imd_asset_type_ck`, the candidates filter and the commit `CASE`). **It was deliberately not
built**, because the finding is that the route is the wrong shape and the change relaxes a
guard rather than adding one. That is an owner decision, not mine to pre-empt.

**MIGRATION REQUIRED = NO for the recommended route**, which needs no mapping migration at all —
only a canonical installed-SRV import path, which does not exist yet (**0 functions insert into
`installed_relief_valves`**; 0049 covers the four families only).

### Analytical preview fingerprint — NOT an approval token

Computed read-only over the exact proposed set, sorted by `source_row_key`, binding import run,
source key, source hash, source Region, target Station id, target Region and expected status:

```
71fd788940ab5d4322c0b78fa9853eb68536eb5a754c45236849dc65dda6dcf8
```

Per the Prompt 22B rule, an approval token must come from a **deployed** function. No deployed
function covers installed SRVs, so this is an **analytical** value and **cannot serve as an
approval token** until whatever computes it is deployed.

### Field firewall

**IDENTITY EVIDENCE:** `region`/`region_raw`/`Area`, `source_station_name_raw`/`Station`.
**CONTEXT ONLY:** `location_raw`/`Location` (**Stage 122 / Storage 93**), `expected_parent_kind`
(**compressor 122 / storage_vessel 93**, derived from it), manufacturer, part number, serial,
set pressure, size type, `IN`/`OUT` ports, dates, notes, and `Number Of Days Left` (principle 12).
**0 of 215** carry a station, unit, compressor, storage-vessel or dispenser id, and **no
unit-bearing field of any kind exists.** `expected_parent_kind` must never populate a foreign key.

### After Station confirmation

215 rows would read `needs_unit_mapping` — **and nothing would become importable that is not
importable now**, because the canonical table accepts `needs_station_mapping` today. Canonical
installed-SRV import remains blocked only by the absence of an import path, and full resolution
still requires Unit evidence (none exists) and then equipment evidence (D3, permanently manual).

---

## Prompt 25C — canonical installed-SRV import: STOPPED at Phase 2

**Read-only.** No migration created, nothing deployed, no canonical SRV imported, no decision,
alias, Station, Unit or equipment created. Production re-verified identical.

### Phase 1 reconciles exactly

Run `cdad1e5e-7faa-4f3b-9432-12a720f3dd64`, manifest `764d3c0f…f5091b8f`.
**2,662 staged installed SRVs = 1,599 + 262 + 801**, 2,662 distinct source keys, 0 malformed
hashes, 0 already committed, 0 lineage markers, canonical `installed_relief_valves` **0**, all
`outcome = ready_unresolved`, one run, one file/sheet. 2,489 distinct hashes (173 legitimate
byte-identical repeats — the 25B condition at full scale). **0 active decisions on any installed
SRV, ever.**

### Phase 2 — THE DISCREPANCY, and why it is blocking

The staged `mapping_status` is **not a canonical state**. Two independent problems:

**1. The FKs it implies do not exist.** The 1,063 non-`needs_station_mapping` rows carry
`station_id` (1,063) and `unit_id` (801) inside their `normalized` payload — but every one is a
**32-character hex synthetic key from the dry run**, matching `^[0-9a-f]{32}$`, not a UUID.
**0 of 1,063 exist in `stations`; 0 of 801 exist in `units`; 0 payloads mention any real canonical
id anywhere.** They are pipeline-internal identifiers minted before Stage A created the hierarchy.

**2. The status was derived from an inference this project has since permanently forbidden.**
Reading `resolution->>'mapping'` verbatim:

| Staged status | Pipeline's own stated reason | Rows |
| --- | --- | --- |
| `needs_equipment_mapping` | **"station has exactly one unit, so the unit is proven; the parent equipment is not named by the source"** | **801** |
| `needs_unit_mapping` | "station has 2 units; the source names none" | 194 |
| `needs_unit_mapping` | "station has 4 units; the source names none" | 37 |
| `needs_unit_mapping` | "station has 3 units; the source names none" | 22 |
| `needs_unit_mapping` | "station has no known unit structure" | 9 |
| `needs_station_mapping` | "station name not resolved by any confirmed alias or canonical name" | 1,583 |
| `needs_station_mapping` | "station evidence is ambiguous; held for human confirmation" | 16 |

**All 801 `needs_equipment_mapping` rows got their Unit from "the Station has exactly one Unit."**
That is precisely the reasoning §4 bans and that Prompts 21D, 22C and 22D each refused in turn —
*"'One Unit under the candidate Station' is a NARROWING, NOT A DETERMINATION"* and *"a fact about
the HIERARCHY, not about the ASSET."* Measured against the real hierarchy the premise does hold for
all 801, which is exactly why it is seductive and exactly why it stays forbidden: the Station's Unit
count is not evidence about the valve.

The 262 are no better founded: their Station came from pipeline-era name resolution with no human
decision, and **224 of 262 name a Station that is not in the canonical hierarchy at all**.

### Proved by rejected insert, not by reading the constraint

Against a local database at 50 migrations, inserting each shape with the FKs actually available:

| Shape | Result |
| --- | --- |
| `needs_station_mapping`, all FKs NULL (the 1,599) | **ACCEPTED** |
| `needs_unit_mapping`, no `station_id` (the 262) | **REJECTED** — `irv_status_shape_ck` |
| `needs_equipment_mapping`, no Station/Unit (the 801) | **REJECTED** — `irv_status_shape_ck` |

Final table state: 1 row. So **1,063 of 2,662 cannot be imported at their staged status**, and the
only way to force them would be to fabricate an FK or to honour the forbidden one-Unit inference.

### What this means

Phase 2's conceptual model (A 1,599 / B 262 / C 801) is **not achievable**, and the prompt's own
instruction applies: *do not blindly force the labels; if any discrepancy exists, STOP.*

**Part A is sound and unaffected**: the 1,599 import cleanly with Station, Unit and equipment NULL,
keeping `source_station_name_raw`, and `cng_admin_map_srv` takes them forward. **The 215 rows of
Prompt 25B are inside that 1,599** and would be Station-confirmable through the existing SRV
workflow with no Stage B and no constraint change — the 25B recommendation is intact.

**The open question is the other 1,063, and it is the owner's to answer**, because every route
changes what the record asserts:

1. **Import all 2,662 as `needs_station_mapping`** with NULL FKs, preserving the staged status and
   the pipeline's reason in provenance. Truthful about canonical state, loses no evidence, and puts
   every Station/Unit/equipment step behind a human decision. *Recommended.*
2. **Import only the 1,599** and hold the 1,063 until their Stations are decided. Smaller, but
   leaves 40% of the family unstored for no gain, since option 1 stores them just as honestly.
3. **Honour the staged statuses** — requires fabricating FKs and adopting the one-Unit inference.
   **Not available**; it is what §4 forbids.

No migration was written, because writing the import function would mean choosing between these on
the owner's behalf, and the choice is a data-principle ruling rather than an implementation detail.

## Prompt 25D — Conservative canonical installed-SRV import (built and locally verified; NOT deployed)

**Owner decision implemented (Option 1).** All 2,662 staged installed SRVs are eligible for
canonical import, and every one is created conservatively: `station_id = NULL`, `unit_id = NULL`,
`compressor_id` / `storage_vessel_id` / `dispenser_id` all NULL, `mapping_status =
'needs_station_mapping'`. The historical staged statuses (1,599 / 262 / 801) are **preserved as
provenance and never applied as canonical truth**, because the 801 `needs_equipment_mapping` and
262 `needs_unit_mapping` labels descend from the one-Unit inference §4 permanently forbids.

**One additive migration, `0051_installed_srv_import.sql`** (SHA-256
`f63f8bffc0aa4d498052cdbbf632d83eed810e0b9c8f2e63291c7a8446973fee`), adding three functions and
NO table, column, constraint, enum, index, grant-widening or policy. It follows the 0049 shape
exactly, so no second import architecture exists:

- `cng_irv_import_proposal(uuid)` — SQL, STABLE, pinned `search_path`. Eligibility classes
  `D_ALREADY_IMPORTED`, `C_INVALID_EVIDENCE`, `A_READY_UNRESOLVED`.
- `cng_irv_import_preview(uuid)` — SQL, STABLE. 26 columns plus a content-bound fingerprint.
- `cng_irv_import_commit(uuid, text, text, integer, text)` — plpgsql, SECURITY DEFINER, pinned
  `search_path`, `service_role` ONLY (`REVOKE ALL FROM PUBLIC, anon, authenticated`).

**THE CONSERVATIVE STATUS IS STRUCTURAL, NOT DEFAULTED.** The single literal INSERT into
`installed_relief_valves` does not name `station_id`, `unit_id`, `compressor_id`,
`storage_vessel_id` or `dispenser_id` at all — there is no column for a fabricated parent to be
written into — and a sixth gate additionally refuses the whole transaction if any eligible row's
payload proposes a Station, Unit, equipment parent or a non-conservative status.

**HISTORY IS KEPT, NEVER PROMOTED.** Each payload carries a `historical` object recording
`staged_mapping_status`, the pipeline's own resolution reason, and the synthetic station/unit
identifiers **as TEXT**, alongside `source_row_key`, `source_row_hash`, `import_run_id`, the
file/sheet/row provenance and the untouched `source_raw`. T8b/T8c assert those synthetic
identifiers are stored as provenance and that **no synthetic id ever became a canonical FK**;
T9c asserts the one-Unit inference is recorded as evidence and never applied.

**LOCAL VERIFICATION AT FULL SCALE.** A disposable fixture reproducing production's structure
(157 Stations / 188 Units; 2,662 staged installed-SRV rows; regions Alex 390 / East 563 / West 454
/ Canal 323 / Delta 634 / Upper 298; historical statuses 1,599 / 262 / 801; 2,489 distinct hashes
across 2,662 distinct keys, i.e. 173 legitimately repeated hashes).

Preview before import: **eligible 2,662 · excluded 0 · already imported 0 · invalid evidence 0 ·
proposed needs_station 2,662 · needs_unit 0 · needs_equipment 0 · resolved 0 · rows with a
station/unit/equipment FK 0 / 0 / 0 · distinct source keys 2,662 · distinct hashes 2,489 ·
repeated-hash groups 173 · duplicate keys 0 · serial present 2,494 · exact-date next test 2,333 ·
regions 6 · canonical now 0**, local fingerprint `a06db530…65948774`.

**The 39-case destructive matrix passes 39 / 39, exit 0** — including wrong run, wrong manifest,
stale preview fingerprint and wrong expected row count all refused with SQLSTATE 23514; a
mid-transaction rollback leaving ZERO rows and ZERO lineage; **no Station, Unit, alias, mapping
decision, equipment record, warehouse SRV or Repair Kit row created**; exactly one audit row; and
replay refused because the fingerprint has moved to the empty-set hash
`e3b0c442…7852b855` with all 2,662 rows now `D_ALREADY_IMPORTED`. Lineage reconciles exactly:
2,662 SRVs across 2,662 distinct source keys, a single `committed_at` (one transaction).

**POST-IMPORT MAPPING SIMULATION — 15 / 15 PASS.** Against the 2,662 canonical rows, the
Station-only candidate set reproduces **215 rows / 27 identities, Delta 118 / West 62 / East 35,
0 multi-candidate, 0 cross-Region** — identical to the Prompt 25A/25B figures, now measured on
canonical records rather than staging. The already-deployed `cng_admin_map_srv` then drives the
full lifecycle with manually supplied canonical ids: Station only → `needs_unit_mapping`
(Unit NULL, equipment NULL, Region taken from the Station); explicit Unit →
`needs_equipment_mapping`; explicit compressor → `resolved` with exactly one parent and
server-derived attribution. Its guards hold: a Station-less mapping (23514), equipment before a
Unit (23514) and a stale row-version precondition (40001) are each refused, and the source
evidence is untouched by all three mappings.

**THE 281 EXISTING PRODUCTION DECISIONS WERE AUDITED AND ARE CLEAN** (Phase 8 / 14, read-only):
all 281 sit on `needs_station_mapping` staged rows, 0 carry a payload Station or Unit, 0 assert a
Unit, and 0 overlap the 268 inference-tainted `resolved` four-family staged rows. **Nothing was
altered.** A latent trap IS reported, not fixed: those 268 `resolved` staged rows (SV 116, RT 76,
GD 54, hoses 22) carry 0 source unit fields and are 268/268 under one-Unit Stations — a future
four-family import must not take their `resolved` label as truth.

**PRODUCTION IS UNCHANGED AND 0051 IS NOT DEPLOYED**: 50 migrations, 6 / 157 / 188,
`installed_relief_valves` 0, warehouse 0, decisions 281 (all-time `n_tup_ins` 281), aliases 0,
staging 7,163, audit 283, canonical assets 100 / 91 / 62 / 26, `cng_irv_import*` functions
deployed **0**, 0 tables without RLS.

**Gate exit 0**: frontend 627, schema 274, authorization 624, 51 migrations from zero, upgrade
replay 50 → 51 (the replay base was advanced from 49 to 50 to match the deployed production
count). Migrations 0044–0050 verified byte-identical to their recorded hashes.

## Prompt 25E — Migration 0051 deployed; production preview verified; NO canonical import

Production went **50 -> 51**, recorded once (`20260917221254 installed_srv_import`), file SHA-256
`f63f8bffc0aa4d498052cdbbf632d83eed810e0b9c8f2e63291c7a8446973fee` recomputed immediately before
transmission and matching approved commit `c91ca6e` byte for byte. Migrations 0044-0050 were
verified byte-identical first.

**DEPLOYMENT PROVED BYTE-EXACT.** All three bodies were hashed FROM THE APPROVED FILE BEFORE
deploying and compared to `pg_proc.prosrc` after: `cng_irv_import_proposal`
`9e25e8836ba0c125f2f0041d029c4f10` (4755), `cng_irv_import_preview`
`074d2bc4d3f053e3d50dbcecf7c7117a` (3112), `cng_irv_import_commit`
`f19350d30dc8a46f26f348a4a2098a99` (7384) — all identical. **NOTHING ELSE MOVED**:
`cng_normalize_name` `3c4d8a93…`, `cng_require_admin` `ff29bdea…`,
`cng_stage_b_station_commit` `b040117a…`, `cng_asset_import_commit` `e759bebb…`,
`cng_stage_a_commit` and `cng_admin_map_srv` are all bit-identical.

**THE MIGRATION EXECUTES NO DML.** Machine-scanned with function bodies and `--` lines stripped:
exactly 15 statements — 3 `CREATE OR REPLACE FUNCTION`, 3 `COMMENT`, 3 `GRANT EXECUTE`, 6 `REVOKE`
— and **ZERO** INSERT/UPDATE/DELETE/TRUNCATE/ALTER/DROP/POLICY/INDEX/CONSTRAINT/CREATE TYPE. No
dynamic SQL (`EXECUTE` appears only in the three `GRANT EXECUTE` tokens; no `quote_ident`).

**DEPLOYED SECURITY AS APPROVED**: commit SECURITY DEFINER and VOLATILE; both read paths INVOKER
and STABLE, so they cannot write and RLS still bounds them; `search_path` pinned on all three;
EXECUTE **anon 0 / authenticated 0 / PUBLIC 0 / service_role 3** — no browser canonical-import path.
Schema shape unchanged: 33 tables, 1,178 columns, 241 constraints, 164 indexes, 27 enums, 70
policies, 0 tables without RLS. **No constraint weakened**: `irv_status_shape_ck` is verbatim, and
`station_id` is still NOT NULL on all four blocker families (nullable on installed SRVs, as
designed).

**PRODUCTION PREVIEW (deployed function, real staging, zero writes).** Run
`cdad1e5e-7faa-4f3b-9432-12a720f3dd64`, manifest
`764d3c0fbe09f3ac95b27ce235f0fb08cfd92711e2a4ec56defb227b5f091b8f`.

**PREVIEW FINGERPRINT
`f4757c75a7513aa2ed8779ae5b4df29b1db686b3aaa05c995873be87168acb44`.**

eligible **2,662** · excluded 0 · already imported 0 · invalid evidence 0 · invalid hashes 0 ·
proposed `needs_station_mapping` **2,662** · needs_unit 0 · needs_equipment 0 · resolved 0 ·
**station FK 0 / unit FK 0 / equipment FK 0** · distinct source keys **2,662** · duplicate keys 0 ·
distinct hashes 2,489 · serial 2,494 · exact-date next 2,333 · regions 6 · canonical SRVs now 0.
Region distribution East 563, Delta 634, West 454, Alex 390, Canal 323, Upper 298 = 2,662.

**FINGERPRINT REPRODUCIBLE**: a second read-only run returned the identical fingerprint and the
identical 2,662-row eligible set.

**ONE NUMBER DIFFERS FROM THE 25D LOCAL REPORT, AND THE LOCAL ONE WAS THE FIXTURE'S**:
`repeated_hash_groups` is **85** in production (258 rows), not the 173 the local fixture produced.
Both are consistent with 2,662 keys and 2,489 distinct hashes — 173 is the EXCESS ROW count, which
the fixture happened to spread over 173 pairs while production concentrates it into 85 larger
groups. The production figure is the real one and is reported as such.

**HISTORICAL PROVENANCE IS CARRIED, NEVER PROMOTED**: staged statuses **1,599 / 262 / 801** exactly.
The pipeline's own reasons are preserved verbatim and reconcile to 2,662: *station name not
resolved by any confirmed alias or canonical name* 1,583 · *station has exactly one unit, so the
unit is proven; the parent equipment is not named by the source* **801** · *station has 2 units;
the source names none* 194 · *3 units* 22 · *4 units* 37 · *station evidence is ambiguous* 16 ·
*station has no known unit structure* 9. **The 801 reason is the forbidden one-Unit inference,
recorded as evidence and not acted on.**

**THE SYNTHETIC IDENTIFIERS ARE PROVENANCE, PROVED**: 1,063 carry a `synthetic_station_id` and 801
a `synthetic_unit_id`; **1,063 of 1,063 match `^[0-9a-f]{32}$`** (not UUIDs); **0 exist in
`stations` and 0 in `units`**; and **0 payloads carry any `canonical_station_id`,
`canonical_unit_id` or `canonical_equipment_id` key at all**.

**FIELD FIDELITY**: model values **0** anywhere; `non_exact_last_with_date` **0** and
`non_exact_next_with_date` **0**, so a date exists only at `exact_date` precision;
`location_raw` and `expected_parent_kind` present on 2,662 as hints and on 0 foreign keys;
part number 48 (the one authorized `SS-4R3A` context).

**THE 215 ANALYTICAL SET IS UNCHANGED**: 215 rows / 27 identities, Delta 118 / West 62 / East 35,
0 multi-candidate, 0 cross-Region, 0 already decided. No mapping was written.

**THE 268 QUARANTINE IS RECONFIRMED AND RECORDED**: 268 four-family staged rows carry the
historical `resolved` status that rests on the forbidden one-Unit inference — storage vessels 116,
recovery tanks 76, gas detectors 54, hoses 22. **0 of them overlap the 281 production decisions**,
and the 281 are clean: 281 active, **0 asserting a Unit**, 0 with a wrong resulting status, 0 with
a wrong previous status. Nothing was repaired, decided or imported.

**FIREWALL AFTER THE PREVIEW — ZERO WRITE**: 51 migrations · 6 / 157 / 188 ·
`installed_relief_valves` **0** · warehouse 0 · decisions 281 (all-time `n_tup_ins` 281) ·
aliases 0/0 · staging 7,163 with **0 installed-SRV rows committed** · audit **283** with **0**
`service_role:installed_srv_import` rows · assets 100/91/62/26 · compressors, dispensers and
presence 0 · 0 tables without RLS. (`installed_relief_valves` shows an all-time `n_tup_ins` of 15 —
historical ROLLED-BACK probe tuples from the Prompt 25C rejected-insert proofs; the live count is 0
and the preview's delta is zero, the same caveat 23B recorded for other families.)

**Gate exit 0**: frontend 627, schema 274, authorization 624, 51 migrations from zero, upgrade
replay 50 -> 51. Installed-SRV import suite 39/39, SRV mapping suite 15/15, both exit 0.

**`cng_irv_import_commit` was NOT invoked in any execution context.** The fingerprint above is a
CANDIDATE approval token; it is not approved here.
