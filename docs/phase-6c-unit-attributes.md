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

## 6d committed (2026-09-23)

Owner approval "Approve 6d 2dcdae0c…4ade0f9, 183 compressors". Guard matched; commit ran once: 183 compressors created,
one per Unit, 0 on the wrong Unit/Station/Region, all `resolved`, 0 invented serial/manufacturer/job number, model stored
exactly as written. بيلا / كفر الشيخ: GALLILEO, 1694 running hours. One audit row. Replay blocked (0 left).
6e (Unit names) is still awaiting its own approval.

## 6e committed and الدولفين corrected (2026-09-23)

Owner approval "Approve 6e df490a28…c6a993627, 79 units". Guard matched; commit ran once: 79 Units renamed, 79 audit
rows (old and new name each). Owner ruling on the leftover: the West Station "الدولفن" is spelled "الدولفين", like its
Units; the Station name was corrected with one audit row (`service_role:owner_ruling`). After both: 0 Units left to
rename, 0 Stations not following the naming rule, 0 one-Unit Stations whose Unit name differs from the Station.
Counts unchanged: 157 Stations, 189 Units, 183 compressors.

## 6g committed (2026-09-24): Stations and Units for Alex, Canal, Upper and the 11 East sites

Owner: "accept the proposals" for `deliverables/phase-6c-zero-station-regions-review.xlsx`
(sha256 `2ef74f49…97c26b5`). Migration `20260924100000_owner_station_rulings_6g.sql` (deployed; the three function
bodies' MD5s match the tested build). Suite `owner_station_rulings_6g.sql`: 16 assertions.

- `owner_station_rulings` holds the rulings as data: one row per source spelling, with its other spelling, Station,
  Unit and workbook row. They were generated from the file by `scripts/import/6g_rulings_sql.py`, never retyped, and
  the loaded rows reproduce the generator's md5 (`59c4d26c…`, 269 rows).
- **7 proposals held, not created**: workbook rows 23, 24, 61–64 and 201. The trailing-number rule misread a number
  that belongs to the name (`الكيلو 21- 1`, `شل اوت محور التعمير ك/1/21`, `الروافع 1&2`) and would have produced
  Stations ending in `-`, `/` or `&`. They need the owner's Station name.
- The 11 N1 names became East rulings, generated in SQL from their own staging rows (the same trailing-number rule).
- Preview, run twice with identical results: `8296e0a7…c760678b`, 280 rulings, **207 Stations** (Alex 64, Canal 47,
  Upper 86, East 10) and **72 Units**, 0 existing, 0 spelling conflicts. Committed once.

Reconciliation: Stations 157 → **364**, Units 189 → **261**; 0 duplicate identities, 0 Units in another Region,
0 names ending in a separator, 169 new Stations with no Unit (none named one; D7), replay blocked, one audit row,
0 aliases and 0 mapping decisions written. Station names use the proposal's folded spelling (e.g. ة → ه), with every
source spelling kept in `source_raw` and in the rulings.

**Unlocked for the next batch (read-only count):** 630 of the 823 staged vessels, recovery tanks and detectors now
match exactly one Station through the rulings (0 match more than one; 65 of them are detector-absence rows, which
create no asset), and 1,058 of the 1,608 Station-less installed SRVs.

## 6g follow-up: the 7 held rows (owner rulings 2026-09-24)

Rows 23, 24 → Station `الكيلو 21`, Units `الكيلو 21 - 1` / `الكيلو 21 - 2` (the owner wrote the second as "الكيلو21 - 2"; stored
with the same spacing as the first). Rows 61–64 → Station `محور التعمير`, Unit 1 or 2 as each name's own number says.
Row 201 (`الروافع 1&2`) → Station `الروافع`, no Unit (the name covers both). Generated by
`scripts/import/6g_held_rulings_sql.py`, loaded byte-exact (md5 `4bc3df7e…`). Preview `fdc7d413…` twice, committed once:
1 Station and 2 Units created (the other two Stations already existed).

## 6h committed (2026-09-24): linking to the ruled Stations

Owner: "yes prepare the linking batch and approve automatically". Migration `20260924120000_ruling_linking_6h.sql`
(deployed; all five bodies' MD5s match the tested build). Suite `ruling_linking_6h.sql`: 19 assertions.

A record links only when its own source Station name equals a ruled spelling in the same Region and every ruling for
that name agrees on one Station and at most one Unit. The Unit is set only when the ruling names one; equipment parents
are never set. Preview `d2790d07…101dc5f7` twice, identical; committed once:

- **569 staged assets imported**: storage vessels 248, recovery tanks 265, gas detectors 56. 151 of them carry their
  Unit (`resolved`), the rest `needs_unit_mapping`. 67 detector-absence rows were skipped (no device invented).
- **1,061 installed SRVs** got their Station: 312 with their Unit (`needs_equipment_mapping`), 749 Station only.

Reconciliation: assets 489 / 447 / 144 / 48, 1,128 in all, each with lineage; 0 Units under another Station; 0 SRVs with
a Station in another Region; 0 equipment parents set; 0 absence rows imported; replay 0; one audit row listing every id.
**Still unlinked:** 187 staged rows and 547 installed SRVs whose names match no ruling.

## 6i committed (2026-09-24): the unlinked-names review

Owner: "accept the proposals" for `deliverables/unlinked-stations-review.xlsx` (sha256 `a57b1b93…`; 122 names,
724 records, built by `scripts/import/unlinked_review_xlsx.py` from md5-verified production exports).

- Migration `20260924140000_ruling_target_region_6i.sql` (deployed byte-exact): `owner_station_rulings.target_region_id`
  lets a ruling name a Station in another Region (the N1 sites' assets were staged as Delta; the owner ruled them East).
  The record then takes its Station's Region; the source Region stays in `source_raw` / `source_region_raw`.
  Suite `ruling_target_region_6i.sql`: 4 assertions.
- **81 rulings** loaded byte-exact (`scripts/import/6i_rulings_sql.py`, md5 `1010f7a7…`). **33 names had no suggestion**
  and stay unlinked. **8 suggestions held** because they name a different place: rows 13 (السادات 2 → 3), 19 (شبين الكوم,
  5 Stations), 45 (العبور), 65 (موبيل العاشر → موبيل المعادي), 72 (البراجيل القديمة → الجديدة), 105/107/108 (فويل أب vs
  فويل اب الدائرى).
- Preview `e27ea36d…dcea1056` twice, identical; committed once: **92 assets** (40 with their Unit) and **392 installed SRVs**
  (315 with their Unit). 30 assets and 7 SRVs moved from Delta to East under the ruling.

Reconciliation: 1,220 assets, all with lineage; 0 SRVs whose Station is in another Region; 0 SRVs whose Unit is under another
Station; replay 0. **Still unlinked:** 88 staged rows and 155 installed SRVs.

## Remaining-names review (2026-09-24)

`deliverables/remaining-stations-review.xlsx` (41 names, 240 records) was produced; the owner chose to leave them unlinked
for now.

## 6j committed (2026-09-24): Station-database attributes and compressors for the held rows

Owner: apply the one-Unit rule (a Station with one Unit has that Unit named as the Station; 6c-2/SU2) to Stations with no
Unit yet. Migration `20260924160000_station_db_attributes_6j.sql` (deployed byte-exact). Suite: 13 assertions.
Preview `e622be11…ce20be84` twice, identical; committed once:
130 rows attached (38 to the Unit their name gives, 1 to a Station's only Unit, 91 to a Unit **created** named as its
Station), 128 compressors created (6d rules). 4 rows held (no Station, or a multi-Unit Station the name does not resolve).

Reconciliation: Stations 365, Units 354, compressors 311; 0 Units in another Region; 0 compressors under another Station;
0 Units with two compressors; 0 created Units misnamed; replay 0. Stations still without a Unit: Alex 19, Canal 12,
Upper 44, East 3 (no Station-database row describes them).

## 6k committed (2026-09-24): a Unit for every Station without one

Owner: "yes apply the rule". Migration `20260924180000_one_unit_stations_6k.sql` (deployed byte-exact; suite 5).
Preview `b838dd31…951119af` twice, identical; committed once: 78 Units, each named as its Station (Alex 19, Canal 12,
Upper 44, East 3). No attribute, compressor or asset was attached. Every Station now has at least one Unit; 307 of 365
have exactly one.

## 6l committed (2026-09-24): records at one-Unit Stations linked to that Unit

Owner ruling, asked explicitly because CLAUDE.md §4 forbids this inference otherwise: "أيوه، اربطهم كلهم". Migration
`20260924200000_one_unit_asset_link_6l.sql` (deployed byte-exact; suite 6). Preview `c02f65ed…7239eedf` twice, identical;
committed once: **2,623 records** - storage vessels 350, recovery tanks 357, gas detectors 135, hoses 48 (now `resolved`)
and installed SRVs 1,733 (now `needs_equipment_mapping`; no equipment parent set). Each carries a mapping note naming the
ruling; one audit row lists every id.

State after: storage vessels 449 resolved / 84 need a Unit; recovery tanks 423 / 54; gas detectors 161 / 1; hoses 48 / 0;
installed SRVs 2,362 need equipment / 146 need a Unit / 155 need a Station. 0 Units under another Station; replay 0.
Records still without a Unit sit at Stations with several Units.

## Phase 6m — installed SRVs on the only equipment of their kind (owner ruling 2026-09-24)

The owner ruled that an installed SRV at `needs_equipment_mapping` whose source Location is Stage belongs to its Unit's
compressor when the Unit has exactly one, and one whose Location is Storage belongs to its Unit's storage vessel when
the Unit has exactly one. Units with two or more vessels (216 SRVs) and Units with no compressor or vessel (442 SRVs)
were held by the owner's choice. Migrations `20260924220000_single_equipment_srv_link_6m.sql` and
`20260924230000_6m_owner_attribution.sql`. The first commit attempt was refused by the "exactly one active admin"
guard, because production also holds an E2E test admin. The follow-up attributes the ruling to the first active
administrator, the owner account. Nothing was written by the refused attempt.

Production: preview `f4e33360…af375c2` twice identical, committed once. 1,703 resolved (1,385 compressor, 318
storage vessel), `resolved_by` = the owner. Reconciled: 0 parents in another Unit, replay 0. Installed SRVs now:
resolved 1,703, needs equipment 659, needs Unit 146, needs Station 155.

## Phase 6n — serial / set-pressure changes from the 24/9/2026 station snapshot (owner ruling 2026-09-24)

Owner: "any change in serial or pressure, take the file's value". The snapshot (`رصيد المحطات`) was normalized with the
import pipeline's own functions (`scripts/import/6n_normalize.ts`) and paired to the system
(`scripts/import/6n_snapshot_update.py`) only where unambiguous:

- **pressure change (11):** same Region/Station/Location and serial, different set pressure (all 3976 → 4000 PSI).
- **serial change (97):** same Region/Station/Location and pressure, exactly one unmatched valve on each side. This means
  a different valve now sits there, so its calibration dates were taken from the snapshot too.

Not changed: 7 pairs where the snapshot has no serial (taking it would erase a recorded serial), 29 in groups with
several unmatched valves on each side (which one is which is unknown), and 337 snapshot-only / 317 system-only valves
(new or removed — not covered by the ruling). Migration `20260925000000_srv_snapshot_update_6n.sql`; the payload
travelled compact (md5 `bf63da95…` both ends) and rebuilt to md5 `d3662533…` identically locally and in production.
Preview `710b880a…aef339f4` identical twice, committed once: 108 updated, one audit row holding every old value,
reconciled 108/108. Replay is refused because every row now already holds its snapshot value.

**6n second batch (owner ruling "سيبهم فاضيين"):** the 7 valves whose snapshot row has no serial now have no serial
(`serial_status = unknown`; the old serial is in the audit row). Their calibration dates were **kept**: the snapshot
row carries none, and clearing them would silently stop their alerts. Preview `b0d84328…f602b00a` twice identical,
committed once, 7 updated, reconciled 7/7. The rest (30 file / 29 system valves in ambiguous groups, 300 file-only,
281 system-only) went to the owner as `srv-snapshot-leftovers.xlsx` for information only; nothing was changed for them.

## Phase 6o — the 24/9/2026 station snapshot becomes the installed-SRV reference (owner ruling 2026-09-24)

Owner: "take the file; the serial identifies the valve in the end" (a vessel or compressor can carry 2, 3 or 6 valves
of one pressure with different serials). So after 6n every snapshot valve still unmatched is **added** and every system
valve still unmatched is **archived** (`archived_at`, reason in `review_reason`; nothing deleted). Migration
`20260925010000_srv_snapshot_add_archive_6o.sql`, scripts `scripts/import/6o_normalize.ts` (the pipeline's own
normalizers) and `scripts/import/6o_snapshot_add_archive.py`.

Station of an added valve is never guessed: the Station already recorded on active valves with the same Region and
normalized source name, else the one canonical Station of that name in the Region, else NULL (`needs_station_mapping`).
Unit only when all those valves carry the same one. The additions went first (the archive would have removed the
evidence), in four content-bound chunks (payload md5 checked both ends): 82 + 82 + 82 + 77 = **323 added**; then
**303 archived**. Then the owner's 6l and 6m rulings were re-run on the new rows: 8 got their one-Unit Station's Unit,
166 got the only compressor/vessel of their Unit.

**Held (7):** seven serials sit under East / عزبة مختار in the system and under Delta / عزبة مختار in the snapshot. By
the serial rule they are the same valves, so they were neither archived nor re-added; the Region question goes to the
owner.

Result: **2,683 active installed SRVs = the snapshot's 2,683 rows**; resolved 1,703, needs equipment 663, needs Unit
143, needs Station 174. 0 parents in another Unit, 0 Units under another Station.

## Phase 6p — a valve is its serial (owner ruling 2026-09-24)

Migration `20260925020000_srv_serial_identity_6p.sql`.

- **Split (97):** the records 6n rewrote with a different serial became two valves. A new active record, an exact copy
  of the current one under a new id, carries the new serial. The original record got its pre-6n serial, pressure and
  dates back (read server-side from the 6n audit row) and was archived, so each valve keeps its own history. The 7
  records whose serial 6n emptied were not split.
- **Move (7):** عزبة مختار's 7 valves are East in the system and Delta in the snapshot; the owner said follow the file.
  They are now in Delta with no Station (`needs_station_mapping`, raw name kept), because the canonical Station of that
  name exists only in East. Whether the Station itself belongs in Delta is still the owner's question.

Preview `c90ec403…1b237dce` twice identical, committed once. Result: 2,683 active (unchanged); 97 new + 97 archived;
7 moved; replay proposes 0. Active: resolved 1,699, needs equipment 660, needs Unit 143, needs Station 181.

## Phase 6q — عزبة مختار moves to Delta (owner ruling 2026-09-24)

Migration `20260925030000_station_region_move_6q.sql` adds a generic, content-bound Station Region move. Every child
table carries `(station_id, region_id)` under NON-deferrable composite FKs, so the Station and all rows under it move
in one statement (data-modifying CTEs), then active SRVs in the new Region waiting for a Station with the same
normalized raw name are linked to it. Production: preview `161f085b…fc95de34c` twice identical, committed once:
Station + 1 Unit + 1 compressor + 1 gas detector moved (4 rows), 7 SRVs relinked. The owner's 6l and 6m rulings were
then re-run: 7 got the Station's one Unit, 4 Stage valves got its one compressor (3 Storage valves wait, the Unit has
no storage vessel). Replay refused; 0 Units in another Region than their Station.

Installed SRVs now: resolved 1,703, needs equipment 663, needs Unit 143, needs Station 174 (2,683 active).
