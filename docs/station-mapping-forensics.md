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
