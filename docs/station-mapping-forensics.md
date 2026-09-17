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

## Prompt 25F — the 2,662 canonical installed SRVs are committed to production

`cng_irv_import_commit` was invoked **EXACTLY ONCE** after a final pre-commit guard matched every
approved value, including the fingerprint
`f4757c75a7513aa2ed8779ae5b4df29b1db686b3aaa05c995873be87168acb44`.
**COMMIT RETURN: `srvs_created` 2,662, `rows_linked` 2,662, fingerprint echoed.** Unambiguous; no
retry was needed and none was made. **`installed_relief_valves` is no longer empty.**

**CANONICAL STATE IS ZERO-DEFECT**: 2,662 rows, **`needs_station_mapping` on 2,662 and nothing
else**; `station_id` 0, `unit_id` 0, `compressor_id` 0, `storage_vessel_id` 0, `dispenser_id` 0;
0 rows carry `resolved_by`/`resolved_at`; 0 rows missing a Region.

**LINEAGE IS EXACTLY ONE-TO-ONE**: 2,662 staged rows linked / **0 unlinked**, 2,662 distinct
`committed_entity_id`, 2,662 distinct source keys, 0 orphan links, 0 SRVs without lineage, 0 key
mismatches, 0 hash mismatches, 0 cross-run links, and a **SINGLE `committed_at`** across all 2,662
(one transaction). **NOTHING WAS COLLAPSED BY A REPEATED HASH**: 2,489 distinct hashes across 2,662
distinct keys produced 2,662 DISTINCT canonical records (principle 16). Stage A's 402 structural
rows are untouched; total committed staging rows 3,343 = 402 + 279 + 2,662.

**TECHNICAL INTEGRITY — 30+ MACHINE COMPARISONS AGAINST THE SOURCE, 0 MISMATCHES** on serial, raw
serial, part number, manufacturer, size/type, IN port, OUT port, set-pressure raw/min/max/unit,
last and next dates, both raw date texts, notes, raw Station name, raw Region, `location_raw`,
`expected_parent_kind` and `source_status_raw`. **NOTHING FABRICATED**: 0 fabricated serials,
pressures, dates or notes; **0 model values anywhere**; **0 non-exact-precision rows carry a date**,
so Days-Left evidence can only come from an `exact_date`; 0 blank raw Station names; 0 rows missing
file/sheet/row provenance. **The `SS-4R3A` rule held EXACTLY in its one authorized context**: 48
rows carry it as `part_number`, **0 of them carry a serial**, and all 48 read
`serial_status = not_yet_assigned`.

**ONE E-CLASS OBSERVATION, MEASURED AND NOT CORRECTED**: the nested copy of the raw source cells
inside `source_raw->'source_raw'` is byte-identical for 165 rows and differs for the rest — and the
difference was characterised exactly rather than assumed: **2,662 of 2,662 differ ONLY by keys whose
original value was JSON null, with 0 values changed and 0 keys added.** `jsonb_strip_nulls` in the
proposal recurses, so 3,029 explicitly-empty source cells lost their KEY (not a value) in that
nested copy. No value was lost, every raw cell text survives in the typed `*_raw` columns (0
mismatches), and the staging row keeps the complete untouched original. Reported, not repaired: no
DML was authorized here and the evidence is intact.

**PROVENANCE IS COMPLETE**: historical staged statuses **1,599 / 262 / 801** exactly, all seven
pipeline reasons preserved on 2,662 rows, and `source_row_key` + `source_row_hash` on 2,662.
**THE SYNTHETIC IDENTIFIERS ARE PROVENANCE ONLY, PROVED**: 1,063 synthetic Station ids and 801
synthetic Unit ids, **1,063/1,063 matching `^[0-9a-f]{32}$`**, with **0 existing in `stations` and
0 in `units`** — and 0 canonical FKs populated anywhere, so none became one.

**WRITE FIREWALL — ONLY THE APPROVED SURFACE CHANGED**: regions 6, stations 157, units 188,
warehouse 0, decisions 281 (all-time `n_tup_ins` 281), aliases 0/0, storage vessels 100, recovery
tanks 91, gas detectors 62, hoses 26, compressors 0, dispensers 0, presence 0, staging 7,163, the
268 quarantine 268, 0 tables without RLS. No Station, Unit, equipment, alias or mapping decision
was created.

**AUDIT — EXACTLY ONE ROW**, 283 -> **284**: `import_executed` on
`installed_relief_valves`/`cdad1e5e…`, `actor_label = service_role:installed_srv_import` with
**`actor_id` NULL** (correct — these tables carry no `created_by` contract and no human attribution
was invented), `before_data` NULL, and `after_data` recording 2,662 created, 2,662 linked, the
canonical status and BOTH fingerprints.

**REPLAY IS CLOSED, PROVED READ-ONLY WITHOUT A SECOND COMMIT CALL**: the post-import preview reports
**eligible 0, already imported 2,662**, and the fingerprint has moved
`f4757c75… -> e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` (the empty-string
hash), so the approved constant now fails closed.

**A REAL AND EXPECTED CONSEQUENCE OF THE OWNER'S OPTION 1 — THE STATION-MAPPING WORKLOAD GREW.**
Against the canonical rows the exactly-one-same-Region-Station candidate set is now **1,054 rows /
127 identities** (Delta 558, East 283, West 213), not 215 / 27. This is NOT a drift and NOT a defect:
the 215 was always measured over the 1,599 historically-`needs_station_mapping` rows, and scoped that
way it reproduces **EXACTLY — 215 rows / 27 identities / Delta 118 / West 62 / East 35**. The extra
839 (801 historically `needs_equipment_mapping` + 38 historically `needs_unit_mapping`) are
candidates precisely because the conservative import correctly reset them, so they now qualify under
the same evidence rule instead of carrying a forbidden inference. 0 multi-candidate, 0 cross-Region,
0 already mapped, and 1,608 rows still have no same-Region candidate at all. **None was mapped.**

**THE 268 QUARANTINE IS UNCHANGED** — storage vessels 116, recovery tanks 76, gas detectors 54,
hoses 22 — with **0 overlap** with the 281 decisions, which remain 281 active with **0 asserting a
Unit**.

**Gate exit 0**: frontend 627, schema 274, authorization 624, 51 migrations from zero, upgrade replay
50 -> 51, report contract PASS; installed-SRV import suite 39/39, SRV mapping suite 15/15.
**One process note**: the first gate run aborted because the LOCAL PostgreSQL server was killed
mid-run (connection refused; disk had 28 GB free, so not exhaustion). That was infrastructure, not a
test result — it was never reported as a failure; the server was restarted and the gate re-run
clean.

**PRODUCTION**: 51 migrations · 6 / 157 / 188 · installed SRVs **2,662** (all
`needs_station_mapping`, all FKs NULL) · warehouse 0 · decisions 281 · aliases 0 · staging 7,163 ·
audit 284 · assets 100/91/62/26.

## Prompt 25G — full installed-SRV Station-mapping reconciliation (READ-ONLY preview)

Nothing was created, updated or deleted; no migration, no mapping decision, no alias. Production
was verified identical before and after.

**THE FULL SET REPRODUCES EXACTLY**: **1,054 rows / 127 identities** — Delta 558/66, East 283/32,
West 213/29 — derived from canonical `installed_relief_valves` using ONLY the approved rule (same
Region + raw Station evidence + deployed normalization + exactly one canonical Station). 0
multi-candidate, 0 already mapped, 0 active-decision conflicts.

**THE PARTITION IS EXACT AND DISJOINT AT BOTH LEVELS**: A = 215 rows / 27 identities (previously
reviewed), B = 839 rows / 100 identities (newly exposed). **0 identities appear in both**,
27 + 100 = 127 and 215 + 839 = 1,054. B's history is exactly as 25F reported: **801 historically
`needs_equipment_mapping` + 38 `needs_unit_mapping`**, with reasons led by *"station has exactly one
unit, so the unit is proven"* (801).

**THE DECISIVE FINDING INVERTS THE INTUITION: THE NEWLY EXPOSED 839 ARE THE STRONGER EVIDENCE.**
All **839 rows / 100 identities match by BYTE-EXACT raw equality** with the canonical
`station_name`. The previously approved **215 rows / 27 identities match by NORMALIZATION ONLY** —
and not merely whitespace (only 8 become equal on space removal; lengths differ in both directions),
so the deployed Arabic/NFKC fold does real work there. That is within its approval, because it is
used for COMPARISON only and never to choose a canonical spelling (the 21C rule). **No mechanism
beyond deployed normalized-name equality is involved anywhere**: `station_aliases` holds 0 rows, 0
`normalized_name` drift on the target Stations, 0 Region mismatches, and no similarity, edit
distance, suffix rule or digit stripping exists in the derivation.

**THE DIGIT TRAP IS CLOSED BY MEASUREMENT**: the fold loses **0** digits (375 raw-with-digit rows
give 375 ident-with-digit), and the digit sequence of the raw name and the canonical Station name is
**IDENTICAL on all 1,054** — so the digits are Station identity, never a D2 Unit index. The fold is
idempotent on the whole set (0 exceptions).

**THE SYNTHETIC IDS CORROBORATE AND CONTRADICT NOTHING** (used as a detector, never as evidence):
215 rows carry no synthetic Station id (category 3); 839 carry one and **0 of them exist in
`stations`** (category 4, by construction). Crucially **0 synthetic-identity groups disagree**
— every synthetic Station identity resolves to exactly ONE newly derived canonical Station (100
consistent groups, 0 disagreeing rows), and **0 canonical Stations are reached from two different
synthetic identities**. Category 2 (disagreement) is **EMPTY**, so nothing needs quarantining on
this ground. Synthetic Unit ids were read as context only; `unit_id` stays NULL.

**RAW-SPELLING CONSISTENCY IS PERFECT**: 127 identities carry **127 distinct raw spellings — exactly
one each** (max 1 per identity), hitting **127 distinct Station targets**. 0 identities map to two
Stations, 0 Stations are reached from two identities, 0 identities span two Regions, 0 raw spellings
appear in two Regions, 0 identities carry mixed history. Group sizes run 3-13.

**SOURCE-ROW INTEGRITY IS CLEAN**: 1,054 rows / **1,054 distinct `source_row_key`**, 0 malformed
hashes, 965 distinct hashes (repeats legitimate where keys differ), 0 rows without lineage, 0 key
mismatches, 0 hash mismatches, 0 raw-Station drift, 0 raw-Region drift, 0 duplicate canonical rows
for a key.

**EXCLUSION MATRIX OVER ALL 2,662** (nothing hidden): qualified **1,054** · no same-Region candidate
**1,596** · cross-Region-only candidate **12** · multiple candidates **0** · historical-Station
disagreement **0** · Region contradiction **0** · raw-spelling ambiguity **0** · lineage mismatch
**0** · hash mismatch **0** · already mapped **0** · active decision conflict **0** · missing raw
Station **0** · missing Region **0**. Total 1,054 + 1,596 + 12 = 2,662.

**CLASSIFICATION: 127 of 127 identities and 1,054 of 1,054 rows are SAFE_CANDIDATE for
STATION-ONLY confirmation; 0 MANUAL_REVIEW_REQUIRED.** Two caveats are recorded rather than buried:
the 215 rest on the normalization fold while the 839 are byte-exact, so they are not the same
evidential strength; and all 2,662 rows share ONE `updated_at` (the single import instant), so a
row-version precondition cannot distinguish rows today although it still detects later staleness.

**THE FORBIDDEN SHORTCUT IS AT ITS MOST TEMPTING HERE AND IS STILL FORBIDDEN**: **993 of the 1,054
sit under a Station with exactly ONE Unit** (9 under a Station with none). Every proposed transition
is therefore `station_id = confirmed Station`, **`unit_id = NULL`**, all equipment FKs NULL,
`mapping_status = needs_unit_mapping` — no Unit is populated even where only one exists.

**ANALYTICAL FINGERPRINTS (NOT approval tokens** — no deployed content-bound mapping mechanism
covers installed SRVs, so the 22B rule is not satisfied):
row-level `8e360445cd323557c73637f94cdfee89b21df1d63242abfdbf9bd286425b741d`,
identity-level `655b51768b44e10eebcf02fcf8e6cab3dee2de673056b4443be949c6bca2dc82`.

**FIREWALL**: 281 decisions untouched (all-time `n_tup_ins` 281, **0 asserting a Unit**, 0
conflicting with this set); the 268 quarantine unchanged (SV 116, RT 76, GD 54, hoses 22) with **0
overlap**.

**BROWSER DATA CONTRACT IS READY; BROWSER VERIFICATION IS OWNER-PENDING.** All **45** columns
`/manage/srvs/installed` selects exist in `v_installed_srv_management` (**0 missing**, so the 20B
failure mode is absent); the view returns **2,662** rows, all `needs_station_mapping`, with
`station_display` correctly falling back to the raw source name on all 2,662 and `parent_kind`/
`parent_id` NULL on all. Due buckets: valid 1,735 · **overdue 302** · unknown 329 · due_60 154 ·
due_7 95 · due_today 39 · due_15 6 · due_30 2, with **0** rows carrying a days-left figure at a
non-exact precision. The view is `security_invoker=true` and RLS is on. **AN AUTHORIZATION
CONSEQUENCE WORTH STATING**: `irv_select` routes a Station-unconfirmed row through
`cng_can_access_unmapped_srv()`, so all 2,662 are **admin/manager only** today (§10) — a regional
engineer or viewer sees zero until Stations are confirmed. `cng-station-management.pages.dev` is
still 403 at CONNECT from here, so this is DATABASE/API CONTRACT verification, not browser E2E.

**PRODUCTION UNCHANGED**: 51 migrations · 6/157/188 · installed SRVs 2,662 all
`needs_station_mapping` with 0/0/0 FKs · decisions 281 · aliases 0/0 · audit 284 · staging 7,163.
**PROOF NO ROW WAS TOUCHED**: every SRV's `updated_at` equals its `created_at` and both equal the
single import instant, which also equals the audit and lineage timestamps — 0 rows updated after
creation, 0 deleted, 0 mapping-audit rows. (`n_tup_upd` on the table reads 3: pre-import
rolled-back probe tuples, the same counter caveat 23B recorded; the row-version equality above is
the real evidence.)

## Prompt 25H — the Station-only installed-SRV batch (built, locally verified, NOT deployed)

**One additive migration, `0052_irv_station_batch.sql`** (SHA-256
`828dd03a852d40b21a7ec2796c2464458e9737adfa1cfbf74e4eb6f39dcef1ae`), adding three functions and
**NO table, column, enum, constraint or index**. It is NOT deployed and no production SRV was
mapped.

**IT REUSES THE EXISTING ARCHITECTURE RATHER THAN BUILDING A SECOND ONE.** Stage B is untouched and
`import_mapping_decisions` is not used: Stage B decides a Station on a STAGING row for the four
NOT-NULL-`station_id` families; this decides a Station on a CANONICAL installed SRV after import —
the division Prompt 25B established. The status derivation, the audit shape and the attribution
rule are those of the deployed `cng_admin_map_srv`, which is NOT modified and still works (T40).
What is new is ONE atomic server-side transaction instead of 1,054 client calls, each individually
abortable and collectively unverifiable.

**THE EVIDENCE RULE IS THE APPROVED ONE, AND THE MECHANISM IS RECORDED PER ROW**: same Region, raw
Station evidence present, exactly one canonical Station, by `byte_exact` (raw equals
`stations.station_name` byte for byte) or `normalized` (the deployed `cng_normalize_name` folds both
to one value). No alias (the table is empty), no similarity, no edit distance, no suffix or digit
stripping, no cross-Region substitution. The candidates function takes NO candidate list and trusts
no prior analysis — it recomputes from canonical rows, import lineage and staged source evidence.

**UNIT IS STRUCTURALLY UNWRITABLE.** The UPDATE names `station_id` and `mapping_status` only;
`unit_id`, `compressor_id`, `storage_vessel_id` and `dispenser_id` are not in it (T8, with T8b
proving the detector fires on a violating column list). **993 of the 1,054 sit under a Station with
exactly ONE Unit and NONE receives it** (T11/T11b). `resolved_by`/`resolved_at` stay NULL because
`needs_unit_mapping` is not a resolution.

**AUTHORIZATION — THIS IS A HUMAN DECISION, NOT AN OPERATOR ACTION.** Unlike the 0051 import
(`service_role`, records with no `created_by` contract), the actor is derived server-side from the
verified Clerk subject via `cng_require_admin()`; EXECUTE is `authenticated` only, with the ADMIN
CHECK as the gate; **`service_role` and `anon` hold NO execute** (T37b/T37c) so this can never be
attributed to a machine identity; no function takes an actor parameter (T37). Viewer, Engineer,
Manager, a deactivated Admin and a session with no verified subject are each refused BY ATTACK
(T33b/T33c/T34/T35/T36). Commit is SECURITY DEFINER with pinned `search_path`; both read paths are
STABLE and NOT definer; no dynamic SQL (T37d/T37e/T37f).

**THE FINGERPRINT BINDS EVERYTHING THAT COULD DRIFT** — per SRV: id, source key and hash, Region,
raw and normalized evidence, the evidence mechanism, the complete current state (status plus the
three NULL FK markers), the target Station and its Region, the row version, and the expected
resulting status; plus the identity-level grouping. It is re-derived inside the commit's own
transaction.

**LOCAL DESTRUCTIVE MATRIX: 64 / 64 PASS, exit 0** (`supabase/tests/irv_station_batch_matrix.sql`),
at full scale over a 2,662-row fixture. Preview exact: **1,054 eligible / 127 identities · 839
byte-exact (100 identities) · 215 normalization-only (27) · 127 distinct target Stations · 1,596
no-candidate · 12 cross-Region-only · 0 multi-candidate**, and 1,054 + 1,596 + 12 = 2,662. The
authorized run mapped 1,054 with `unit_id` and all equipment NULL on every one; a mid-transaction
rollback left ZERO mapped and ZERO audit rows; replay was refused with both the old and the current
fingerprint. **Nine independent drift scenarios each invalidate the approved fingerprint**: changed
source hash, changed lineage key, lineage removed, changed raw Station, changed Region, the target
Station renamed, one row already Station-mapped, one row version changed, and a qualifying row
leaving the set.

**ONE TEST PREMISE WAS WRONG IN A USEFUL WAY.** "A new competing same-Region candidate" cannot be
constructed: `stations_region_norm_uq` forbids two Stations sharing a normalized name in one Region.
The case was reframed as proof by attempted insert — same-Region ambiguity is UNREACHABLE, not
merely unhandled (the Prompt 22A finding, restated) — plus a check that a same-name Station in
ANOTHER Region never changes the set.

**AUDIT**: one `audit_logs` batch row attributed to the active Admin (never `service_role`), plus
**1,054 `asset_mapping_audit` rows in the shape `cng_admin_map_srv` writes**, all carrying one
`bulk_batch_id` with `is_bulk` true, one actor, the true before/after and NO unit or parent. Every
mapped SRV has exactly one audit row. `asset_mapping_audit` has carried `is_bulk`/`bulk_batch_id`
since 0001, so no table was invented for this.

**FIXTURE LIMITS STATED PLAINLY**: it carries 157 Stations and **189** Units (production has 188) and
its Region split is synthetic (Delta 583 / East 284 / West 187 against production's 558/283/213),
because it is generated from the structural skeleton with synthetic ASCII names — **no Arabic
identity string was hand-transcribed**. Its normalization-only class folds on CASE and `/` spacing
while production's folds on Arabic diacritics and letter variants; the MECHANISM under test (deployed
normalizer equality versus byte equality) is identical, and the Arabic behaviour is proved separately
by the production recomputation below.

**PRODUCTION RECOMPUTATION (READ-ONLY, by inlining the identical derivation) RECONCILES EXACTLY**:
**1,054 / 127 · 839 byte-exact (100 identities) · 215 normalization-only (27) · 127 targets · 1,596
no-candidate · 12 cross-Region-only · 0 multi-candidate · 993 under one-Unit Stations · Delta 558 /
East 283 / West 213**.

**TWO FINGERPRINTS, KEPT STRICTLY APART, AND NEITHER IS AN EXECUTABLE TOKEN**:
(A) LOCAL FIXTURE `cce64d1d4a813440490a05c2d9fd4ee691ff6d9880705e251ba8abbb9ee5c609` — fixture-
specific and not stable across rebuilds, because it binds SRV UUIDs, which is correct behaviour;
(B) PRODUCTION ANALYTICAL `d5a60e87ea600e7e15f29b9cad95d2668f1c500c12b0bc118322616f964f9f8d`.
**A true production content-bound preview REQUIRES 0052 TO BE DEPLOYED FIRST**, because the 22B rule
is that an executable fingerprint must come from the DEPLOYED function.

**THE REMAINING 1,608, CLASSIFIED (read-only, none resolved)**: **1,596** carry a name no Station in
their Region holds; **12** match only in another Region — and they are a SINGLE identity, Alex rows
whose name matches a West Station. Region is identity, so they stay unmapped; **cross-Region mapping
is NOT approved and NOT proposed.**

**POST-MAPPING VISIBILITY, DERIVED FROM THE DEPLOYED POLICY (nothing changed)**: `irv_select` reads
`CASE WHEN station_id IS NOT NULL THEN cng_can_read_region(region_id) ELSE cng_can_access_unmapped_srv() END`.
Today, with `station_id` NULL, the second branch is `cng_is_manager_or_admin()` — **Admin and Manager
only; Engineer and Viewer see nothing**. After Station confirmation those 1,054 rows move to the
first branch: Admin true, Manager true, **Engineer and Viewer become Region-scoped via
`cng_has_region_grant`**. So **Station mapping ALONE is sufficient for Region-scoped access — no Unit
is required and no RLS change is needed.** The practical effect today is nil: production holds 1
active Admin and **0 Region grants**.

**Gate exit 0**: frontend 627, schema 274, authorization 624, 52 migrations from zero, upgrade replay
51 -> 52, report contract PASS; installed-SRV import suite 39/39, SRV mapping suite 15/15, new batch
matrix 64/64. Schema and authorization counts are unchanged because the batch tests ship as their own
suite rather than inside `schema_scenarios.sql`. Migrations 0044-0051 byte-identical.

**PRODUCTION UNCHANGED**: 51 migrations, 0 batch functions deployed, 2,662 SRVs all
`needs_station_mapping` with 0/0/0 FKs, **one distinct `updated_at` and 0 rows modified since
creation**, decisions 281, audit 284, `asset_mapping_audit` 0, aliases 0, staging 7,163,
stations 157, units 188, the 268 quarantine intact, 0 tables without RLS.

## Prompt 25I — migration 0052 deployed; production content-bound preview verified; NO commit

Production went **51 -> 52**, recorded once (`20260917234508 irv_station_batch`), file SHA-256
`828dd03a852d40b21a7ec2796c2464458e9737adfa1cfbf74e4eb6f39dcef1ae` recomputed immediately before
transmission and matching approved commit `4abd269` byte for byte. **One naming note**: the prompt
referred to `0052_installed_srv_station_batch.sql`; the approved file is `0052_irv_station_batch.sql`.
The hash and the commit identify it, and both match, so it is the reviewed file.

**DEPLOYMENT PROVED BYTE-EXACT.** All three bodies were hashed FROM THE APPROVED FILE BEFORE
deploying and compared to `pg_proc.prosrc` after: candidates `45c3d2fcf5aea0bda591015b233d855d`
(3654), preview `72fc98d8d00635c349cb95a4493ace18` (4471), commit
`107b62f57ab5d242c14cc248b18f02ae` (5806) — all identical. **NOTHING ELSE MOVED**:
`cng_admin_map_srv` `cb66c7f9…`, `cng_require_admin` `ff29bdea…`, `cng_normalize_name` `3c4d8a93…`
and `cng_irv_import_commit` `f19350d3…` are bit-identical.

**THE MIGRATION EXECUTES NO DML.** Machine-scanned with bodies and `--` lines stripped: **15
statements** — 3 `CREATE OR REPLACE FUNCTION`, 3 `COMMENT`, 3 `GRANT EXECUTE`, 6 `REVOKE` — and
ZERO INSERT/UPDATE/DELETE/TRUNCATE/ALTER/DROP/POLICY/INDEX/CONSTRAINT/CREATE TYPE, no
`quote_ident`. (A naive `;` split reports 16 because one semicolon sits inside the commit's COMMENT
string literal, at `'subject; it takes no actor parameter…'`; the corrected count is 15 — the same
artefact class corrected in 24C.) Schema shape unchanged: 33 tables, 241 constraints, 70 policies,
0 tables without RLS.

**DEPLOYED SECURITY IS EXACTLY AS APPROVED**: commit SECURITY DEFINER and VOLATILE, calling
`cng_require_admin()`; both read paths SECURITY INVOKER and STABLE, so they cannot write and RLS
bounds them; `search_path` pinned on all three; EXECUTE **anon 0 / PUBLIC 0 / service_role 0 /
authenticated 3** — so the batch can never be run or attributed by a machine identity; **0 actor
parameters** on any of the three; no dynamic SQL.

**DEPLOYMENT WROTE NOTHING**: Station FKs 0, ONE distinct `updated_at` with 0 rows modified since
creation, `asset_mapping_audit` 0, `audit_logs` 284, decisions 281, aliases 0.

**PRODUCTION PREVIEW FROM THE DEPLOYED FUNCTION — FINGERPRINT
`d5a60e87ea600e7e15f29b9cad95d2668f1c500c12b0bc118322616f964f9f8d`.** This is now an EXECUTABLE
token under the 22B rule, and it is **EXACTLY the value 25H computed analytically**, which confirms
that inline reproduction was faithful.

eligible **1,054** / identities **127** · byte-exact **839** (100 identities) · normalization-only
**215** (27) · **127 distinct target Stations** · Delta 558 / East 283 / West 213 · no-candidate
**1,596** · cross-Region-only **12** · multi-candidate **0** · every other exclusion class 0 ·
**rows_that_would_get_a_unit 0** · canonical total 2,662. Sum 1,054 + 1,596 + 12 = 2,662.
**A SECOND RUN RETURNED A BYTE-IDENTICAL ROW** — every count and the fingerprint unchanged.

**EVIDENCE-CLASS SUBSETS ARE NOT SERVER-SUPPORTED, AND NO SUBSET FINGERPRINT IS OFFERED.** The
deployed `cng_irv_station_batch_candidates()` and `cng_irv_station_batch_preview()` take **NO
ARGUMENTS**, and the commit takes only `(fingerprint, row count, identity count, reason)` — **0
class/mechanism/subset/selector parameters exist**. So 0052 binds the FULL 1,054-row set only. A
BYTE_EXACT_ONLY (839/100) or NORMALIZATION_ONLY (215/27) fingerprint could only be produced by
filtering client-side, which is NOT executable and is not presented. **0052 was not altered and no
migration 0053 was created.**

**CONTENT BINDING VERIFIED IN THE DEPLOYED BODY**: all fifteen per-SRV fields are present in the
fingerprint expression — srv id, source key, source hash, Region, raw Station, normalized Station,
evidence mechanism, current status, the three explicit NULL-FK markers, target Station, target
Station Region, row version and expected resulting status — plus identity-level grouping by
(Region, normalized identity). The commit re-derives BOTH the preview and the candidate set inside
its own transaction. **No caller can submit a candidate list or a target Station list**: there is no
array or list parameter anywhere.

**THE 993 ONE-UNIT TRAP, RECOMPUTED AND STILL REFUSED**: eligible rows by target-Station Unit count
are **1 Unit: 993 · 2 Units: 41 · 3 Units: 6 · 4 Units: 5 · 0 Units: 9** (= 1,054). The deployed
preview reports `rows_that_would_get_a_unit = 0`, and the commit's UPDATE names neither `unit_id`
nor any equipment column, so no Unit is expressible for any of them.

**THE 12 CROSS-REGION ROWS ARE FIREWALLED**: 12 rows, **1 identity**, source Region **Alex**, with
the same-named Station existing **only in West**. They carry `target_station_id` NULL and
`evidence_mechanism` NULL, are classified `X_CROSS_REGION_ONLY`, and are therefore absent from the
eligible set and from the fingerprint, which is built only from eligible rows. No alias was created,
no Region altered, no West Station substituted.

**RLS CONSEQUENCE (read-only, nothing changed)**: `irv_select` is
`CASE WHEN station_id IS NOT NULL THEN cng_can_read_region(region_id) ELSE cng_can_access_unmapped_srv() END`.
Today every one of the 2,662 takes the second branch (`cng_is_manager_or_admin()`): **Admin yes,
Manager yes, Engineer no, Viewer no**. After a hypothetical Station-only mapping the 1,054 take the
first branch: Admin yes, Manager yes, **Engineer and Viewer Region-scoped via
`cng_has_region_grant`** — Station mapping alone suffices, no Unit and no RLS change needed.
**CURRENT STATE, so this is not confused with present visibility: 1 active Admin and 0 Region
grants**, so today nobody but that Admin sees anything either way.

**BROWSER/API CONTRACT READY, BROWSER E2E STILL OWNER-PENDING**: all **45** columns
`/manage/srvs/installed` selects exist in `v_installed_srv_management` (0 missing); the view returns
**2,662** rows with `station_display` falling back to the raw source name on all 2,662, and
`parent_kind`/`parent_id`/`unit_id` NULL on all. Due buckets: valid 1,735 · overdue 302 · unknown
329 · due_60 154 · due_7 95 · due_today 39 · due_15 6 · due_30 2.

**Gate exit 0**: frontend 627, schema 274, authorization 624, 52 migrations from zero, upgrade
replay "nothing pending", report contract PASS; batch matrix **64/64**, installed-SRV import suite
**39/39**, single-SRV mapping suite **15/15**. **One process note**: the first gate run failed
because of a bug I introduced in `scripts/verify-all.sh` — an unmatched `0053_*.sql` glob ran the
loop once on the literal pattern. That was my script, not the product; it now reports "nothing
pending" via a `nullglob` guard, and the gate was re-run clean. Migrations 0044-0052 match the
reviewed bytes.

**PRODUCTION AFTER ALL PREVIEWS**: 52 migrations · 6 / 157 / 188 · installed SRVs **2,662** all
`needs_station_mapping` with Station/Unit/equipment FKs **0/0/0** · ONE distinct `updated_at` and 0
rows modified since creation · decisions 281 · `audit_logs` **284** · `asset_mapping_audit` **0** ·
aliases 0 · staging 7,163 · the 268 quarantine intact · 0 tables without RLS.
**`cng_irv_station_batch_commit` was NOT invoked in any execution context.**
