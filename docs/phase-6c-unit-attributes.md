# Phase 6c — `unit_attributes` rows from `Station data base.xlsx` (analysis, READ-ONLY)

Measured against production on 2026-09-23. **Nothing was written**; this is the ruling packet.

## Source and target

325 staged rows, 0 committed. Every row carries only a raw name (`source_name_raw`), a Region and
attributes. Values present (non-empty rows): bay status 317, compressor model 315, recovery tank model
313, avg hours/day 307, dispenser model 301, dispenser count 300, hose count 300, total running hours
299, storage count 282, storage model 279, gas detector model 201, avg gas sales/day 172, notes 16.

The canonical targets that exist today are `units.{dispenser,hose,storage}_count_reported(+_raw)`,
`units.bay_status(+_raw)`, `stations.bay_status(+_raw)` and `notes`. **All of them are empty on all
188 Units and 157 Stations**, so there is no conflict to resolve. Models, running hours and gas sales
have **no canonical column**; they stay in staging unless a schema change is approved.

The payload `station_id`/`unit_id` values are the dry run's synthetic keys (the Prompt 25C finding) and
are **not** used. Matching below is by exact normalized name within the same Region only.

## Classes (each row in exactly one)

| Class | Rows | Evidence | Proposed ruling |
| --- | --- | --- | --- |
| **U1** name = exactly one Unit, no Station of that name | **52** (East 26, West 26) | Unit identity match; every one sits under a multi-Unit Station | Attach the count/bay attributes to that Unit. Strongest class. |
| **SU** name = a Station **and** its only Unit (the same name) | **51** (East 29, West 22) | Single-Unit Station whose Unit carries the Station's name | Attach to the Unit (Unit-level columns). This is the naming that §8 warns about, but here both levels point at the same physical Unit. |
| **SU2** name = a Station **and** a Unit, Station has 2+ Units | **4** (West) | The name is ambiguous between the Station and one of its Units | Owner decides per row. Default: hold. |
| **S1** name = a Station only | **76** (Delta 73, West 3) | Station identity. 73 have exactly one Unit, 2 have several, 1 has none | Attach **bay status** at Station level only. Unit-level counts are **held**: putting them on the only Unit is the one-Unit inference §4 forbids. |
| **N1** no same-Region match | **11** (Delta) | Nothing matches | Hold, and raise an unmatched-name import issue. |
| **Z** Region with no canonical Stations | **123** (Alex 45, Canal 38, Upper 40) | These are the only structural evidence for these Regions | Hold. They prove a site exists, not its level (the §8 mixed-level problem). Creating Stations from them needs a separate D-ruling. |
| **X** no name and no Region | **8** | Blank rows | Hold. Nothing can be attached. |

Total: 52 + 51 + 4 + 76 + 11 + 123 + 8 = **325**.

## Rulings the owner needs to give

1. **U1 (52)** — approve attaching counts and bay status to the named Unit? *(Recommended: yes.)*
2. **SU (51)** — approve treating a single-Unit Station whose Unit shares its name as naming that Unit?
   *(Recommended: yes; it is the same physical Unit either way.)*
3. **S1 (76)** — approve bay status at Station level only, holding the counts? *(Recommended: yes.)*
4. **SU2 (4)** — hold, or rule row by row.
5. **Z (123)** — do not act now. Needs a decision on how Stations for Alex/Canal/Upper are created.
6. **Models and running hours** — no column exists. Keep in staging, or approve a schema addition?

On approval, the build follows the Stage A/B pattern: a deployed preview function with a content-bound
fingerprint (run twice), a separate owner approval of that fingerprint, one commit, then reconciliation.

## Owner rulings (2026-09-23) and 6c-1 build

| Class | Ruling | Result |
| --- | --- | --- |
| U1 (52) | approved | attach to the named Unit |
| SU (51) | approved | attach to the Unit that shares the Station's name |
| SU2 (4) | Units are numbered: "X" is the first Unit, "X 2" the second | "X" attaches to Unit "X"; every case is Station X with Units "X" and "X 2", and the source has a separate "X 2" row (a U1 row) |
| X (8) | remove | marked `outcome = rejected` with a reason; never deleted, `source_raw` intact |
| S1, N1 | examples requested | see below; still held |
| Z (123) | build the Stations from all sheets; leave unknown values empty | review workbook produced; see below |

U1, SU and SU2 are one evidence test: the row's name equals exactly one Unit name in the same Region.
Migration `20260923180000_unit_attributes_6c.sql` (deployed as `unit_attributes_6c`, prosrc MD5s: proposal
`9d071ec4…`, preview `5c12b888…`, commit `9e6154ea…`, identical to the tested local build). Suite
`supabase/tests/unit_attributes_6c.sql`: 29 assertions. It checks that S1 is **not** pushed down to its only Unit,
that the same name in West is not used for an East row, that no value is overwritten, and that replay is refused.

**Deployed preview (run twice, identical):** fingerprint
`1999534744d7e8f8c993bf8a587af1bf1be90ecd22fe896aa498a7890003a8d0`. 107 rows → 107 distinct Units
(East 55, West 52), 8 blank rows to reject, 1 row whose count is not a plain number (kept as raw text, number
empty), 0 bay-status values unrecognised. **Not committed:** it needs a separate owner approval of this fingerprint.

## Examples for S1 (76 rows) — name is a Station only

| Row | Source name | Station's Units | Why it is held |
| --- | --- | --- | --- |
| Delta 252 | وطنيــة / الســادات 1 | 1 Unit: "مدينة السادات بجوار الجامعة" | Delta Units are named by address, so the row names the Station, not the Unit |
| Delta 243 | شــعلان / قويســنا 2 | 1 Unit: "شارع مصر اسكندرية الزراعى - قويسنا …" | same |
| Delta 279 | بيلا/كفر الشيخ | **0 Units** | nothing to attach counts to |
| West 63 | الهرم | 1 Unit: "الهرم 1" | the row says "الهرم", the Unit is "الهرم 1" |
| West 111 and 112 | فويل اب الدائرى (twice) | 2 Units: "…الدائرى 1", "…الدائرى 2" | two rows, two Units, but no row says which is which |

73 of the 76 are Delta Stations with exactly one Unit. **Options:** (a) put bay status on the Station and counts on
its single Unit (this is the one-Unit rule CLAUDE.md §4 forbids unless you rule it explicitly for this workbook);
(b) Station bay status only (recommended); (c) hold everything.

## N1 (11 rows) — Delta names with no Station anywhere in the hierarchy

الخانكة · العبور المنطقة الصناعية · بهتيم · الحلمية أبو حماد · عزبة مختار · العاشر من رمضان 1 · العاشر من رمضان 2 ·
العاشر من رمضان (A1) · الزاهد · موبيل-العاشر الجديدة · آل حكيم العاشر.
These are sites the structural workbook (`Assets DataBase`) does not list. **Options:** create them as new Delta
Stations the same way as Z (below), or hold.

## Z — Stations for Alex, Canal and Upper

Every name for these Regions in all four workbooks was collected: 276 names, 1,770 rows. The same site is spelled
differently from sheet to sheet (e.g. `محرم بك 1` / `محرم بيك 1` / `محرم بك1`, `الادبيه` / `الادبيه - السويس`), so the
Stations cannot be created automatically without guessing. `deliverables/phase-6c-zero-station-regions-review.xlsx`
lists every name with the files it appears in, a proposed Station and Unit (spelling folded, governorate suffix
removed, trailing number read as the Unit), and yellow columns for the owner's Station and Unit. Once it is filled in,
the Stations and Units are created from it with the same preview → approve → commit steps. Unknown values stay empty.

## 6c-1 committed (2026-09-23)

Owner approval: "Approve 6c 19995347…0003a8d0, 107 rows". Pre-commit guard re-ran the deployed preview and matched
(same fingerprint, 107 rows / 107 Units, 8 blank, 0 Units already holding values). `cng_6c_unit_attribute_commit` ran
**once**: 107 Units updated, 107 rows linked, 8 blank rows rejected.

Reconciliation, all zero-defect: 107 Units now hold values and every one is linked from exactly one row; one commit
timestamp; 0 wrong Region; 0 rows whose name differs from the Unit's; 0 stored values differing from the source text;
0 numbers stored from a non-integer cell. 8 rows rejected (not deleted). 210 rows still held (S1 76, N1 11, Z 123), so
325 = 107 + 8 + 210. Stations 157 and Units 188 unchanged, 0 Station values written. Audit: one new row
(`service_role:unit_attributes_6c`), 617 in total. Replay blocked: the preview now shows 0 rows to attach
(fingerprint `4add961e…`).

## 6c-2: S1 rulings (2026-09-23), deployed, awaiting fingerprint approval

Owner rulings: a Station with one Unit is that Unit (address-style Unit names are ignored); بيلا/كفر الشيخ has a Unit with
the Station's name (compressor Galileo); فويل اب الدائرى has Units 1 and 2; bay status belongs to the Unit (enclosure),
never the Station; Unit naming is "X" for a one-Unit Station and "X 1", "X 2", "X 3"… when there are several.

Migration `20260923200000_unit_attributes_6c2.sql` (deployed as `unit_attributes_6c2`; prosrc MD5s proposal `4bf7f66d…`,
preview `4118f134…`, commit `89f9bbf1…`, identical to the tested build). Suite `unit_attributes_6c2.sql`: 19 assertions.

**Deployed preview (run twice, identical):** `45ff448e0b189a520c15a6e4f7aa9fe02bd517d78e5e9c07d5de510ca1d3985a`.
All 76 S1 rows: 73 go to their Station's only Unit (Delta 72 and West الهرم), 1 creates the Unit بيلا / كفر الشيخ,
2 go to فويل اب الدائرى 1 and 2 in row order. 1 count is not a plain number (kept raw). 0 Station values.

## N1: the 11 names are East sites

The owner confirms the 11 rows labelled Delta belong to East. None of them exists as a Station or Unit in East either
(checked by exact name), so they need new East Stations. This is done with Z, from the review workbook.

## Unit names that do not follow the owner's naming rule

Measured against the rule "one Unit = X; several = X 1, X 2, …": East 42/42 follow it. West: 33 of 40 follow it,
1 one-Unit Station has a Unit named otherwise (e.g. الهرم → Unit "الهرم 1"), and 6 two-Unit Stations are named "X" and "X 2"
instead of "X 1" and "X 2". Delta: all 74 one-Unit Stations have address-style Unit names. **81 Units could be renamed**
to the rule, with the old name kept in provenance. Not done; it needs an owner decision.

## 6c-2 committed (2026-09-23)

Owner approval: "Approve 6c-2 45ff448e…ca1d3985a, 76 rows". Guard re-ran the preview and matched. Commit ran **once**:
1 Unit created (بيلا / كفر الشيخ, under its own Station), 76 Units updated, 76 rows linked.

Reconciliation, all zero-defect: Units 188 → 189, Stations 157; 183 Units now carry workbook values (107 + 76), each linked
from exactly one row; 0 wrong Region; 0 rows linked outside their Station; 0 stored values differing from the source text;
0 Station values. فويل اب الدائرى 1 = OPEN, 3 dispensers; 2 = OPEN, no dispenser count (as in the source). One audit row.
Replay blocked (0 rows left). Still held: 134 = Z 123 + N1 11 (both wait for the review workbook).

## 6d compressors and 6e Unit names: deployed, awaiting fingerprint approval

Owner: "yes import compressors and rename the units". Migration `20260923210000_compressors_and_unit_names_6d.sql`
(deployed as `compressors_and_unit_names_6d`; all six prosrc MD5s identical to the tested build). Suite
`compressors_unit_names_6d.sql`: 19 assertions.

**6d preview (run twice, identical):** `2dcdae0c5c38762161d4c7f9b6c28eeff32ba4fb98bf4f49cddc2bdbc4ade0f9`.
183 compressors, one per Unit linked in 6c-1/6c-2 (East 55, West 55, Delta 73); all 183 carry a model (as written, e.g.
"GALLILEO" is not corrected), 182 total running hours. No serial, manufacturer or job number. `mapping_status = resolved`.

**6e preview (run twice, identical):** `df490a289fffbfcee8e76b9ff033e8494e9f273414939a2b226c523c6a993627`.
79 Units renamed: 75 one-Unit Stations get the Station's name (74 Delta address names, and West "الهرم 1" → "الهرم"),
4 West Units "X" beside "X 2" become "X 1" (الخمايل, الصفوة, المحور المركزى, دائرى الهرم). One audit row per rename with old
and new name. Earlier estimate of 81 counted differently; the exact figure is 79 + 1 left over:
**West Station "الدولفن" has Units "الدولفين 1…4"**. The Station and its Units are spelled differently (ين vs ن), so it is
not renamed; the owner decides which spelling is right.
