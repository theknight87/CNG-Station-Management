# Import Mapping

How each source column becomes a target column, and what is deliberately **not** imported.

Source detail: [`data-dictionary.md`](./data-dictionary.md).
Findings that drive the decisions here: [`data-quality-report.md`](./data-quality-report.md).

**Nothing has been imported.** This document is the specification to be reviewed before the
first importer runs.

---

## 0. Conventions applied to every mapping

| Rule | Implementation |
| --- | --- |
| Preserve the original (#6) | Every imported row stores `source_raw JSONB` (the whole row), plus `import_batch_id`, file name, sheet name, and 1-based row number. |
| Missing stays missing (#3, #14) | No default values, no zero-filling, no placeholder strings. |
| Identifiers are TEXT (#11) | Every serial, job number, part number and warehouse code is read with `data_only` raw typing and cast to text **without numeric formatting**. A value Excel stored as `int 21586` imports as `"21586"`; a float `1803.02075` imports as `"1803.02075"`. |
| Placeholders → NULL + flag | `-`, `N/A`, `______`, `__________` become `NULL` with `review_reason = 'placeholder_in_source'`. `0` is **never** treated as a placeholder. |
| Never guess (#8) | No fuzzy station matching. Unmatched names are retained and flagged. |
| Nothing discarded (#10) | Row-level errors are collected; the run continues. |
| Days Left | Never imported. Derived from `next_due_date − current_date`, and **only** where precision is `exact_date`. |
| Dates | Stored as `(value DATE NULL, precision date_precision, raw TEXT)` with precision `exact_date` / `year_only` / `unknown` / `invalid`. See §7. |
| Identifiers stay raw (#15) | No leading-zero padding, no stripping of decimal-looking characters, no "correcting" a value that looks like a part number. Wrong-looking values import verbatim and are flagged. |
| Repeats ≠ duplicates (#16) | Duplicate candidates are reported, never merged or dropped. |
| No global authority (#18) | Precedence is per field (§10). Undeclared conflicts are retained and flagged, not silently won by one file. |
| Missing ≠ incomplete (#19) | NULL fields never block creation and never mark an entity incomplete. |
| No default Unit (D7) | Unknown Unit → `unit_id NULL` + `needs_unit_mapping`. A Unit is never invented to hold assets. |
| Serial status (D4) | `assigned` / `not_yet_assigned` / `unknown`. Serials are never generated. |
| Status words (D6) | `منتهي`/`منتهية` in a date column → `source_status_raw`, date `invalid`. |
| Pressure | Stored as `(raw TEXT, min NUMERIC NULL, max NUMERIC NULL, unit TEXT NULL)`. Never converted. |

### Region normalization (deterministic, all values covered)

`East|east → East` · `WEST|West|west|غرب → West` · `DELTA|Delta → Delta` ·
`CANAL|Canal → Canal` · `Alex|ALEX → Alex` · `UPPER|Upper → Upper`

Raw value retained in `area_raw`. No observed value falls outside this table.

---

## 1. Import order

Each stage depends on the previous one. Stages 3–6 can run in any order.

```
1. region            seed the 6 canonical regions
2. station + unit    from file 2 (authoritative, 3 regions) then file 1 (all 6)
3. compressor / dispenser / storage_vessel / recovery_tank   from files 1, 2, 4
4. gas detector presence + records      from file 5
5. vessels (storage + recovery)         from file 4
6. SRVs (installed + warehouse)         from file 3
7. hoses                                from file 6
```

---

## 2. Stations and Units

### The grain problem

`Station data base.xlsx` is **unit-grain** (`شبرا 1`…`شبرا 4`), while
`Assets DataBase` is explicitly two-level (station `شبرا`, units `شبرا 1`…`شبرا 4`). For
single-unit stations the two names coincide. See
[data-quality-report.md §3](./data-quality-report.md#3-station-vs-unit-grain--the-central-mapping-problem).

### Mapping

**Stage 2a — from `Assets DataBase` (East, West, Delta only; authoritative for structure):**

| Source (file 2) | Target | Transform |
| --- | --- | --- |
| `Area` (forward-filled) | `station.region_id` | region alias table |
| `Station Name` (forward-filled) | `station.name` | trim; NFKC; **no** Arabic letter folding on the stored value |
| `Station Name` | `station.name_raw` | verbatim |
| — | `station.job_number` | not present at station level → `NULL` |
| `Unit Name` | `unit.name` / `unit.name_raw` | trim |
| `Unit Job No.` | `unit.job_number` **TEXT** | verbatim as text; `30157` → `"30157"`. 2 units have none → `NULL` (never blocks creation, principle #4) |

Yields **156 stations, 188 units**.

**Stage 2b — from `Station data base.xlsx` (all six regions):**

This file is **not** treated as a Station master: its name column mixes station-level and
unit-level naming, so one row does not equal one Station. Each row resolves through
`station_alias` (and `unit_alias` where applicable):

| Outcome | Action |
| --- | --- |
| A **confirmed alias** exists for (raw name, region, file) | attach this row's attributes to the canonical entity it names |
| Normalizer matches exactly one existing **unit** | write a **proposed** alias; **attach nothing yet**; queue for confirmation |
| Normalizer matches exactly one existing **station** with a single unit | proposed alias to that unit; queue for confirmation |
| Normalizer matches several candidates | proposed aliases for each candidate, `import_issue = 'ambiguous_station_identity'`; **no attachment** |
| Rule D1/D2 fires unambiguously | alias created with its `alias_source`; Station (and Unit, for D2) resolved or created as the rule proves |
| No match, region is Canal / Alex / Upper | create the **Station only**, `job_number = NULL`; **no Unit is invented** (decision D7). Unit-scoped attributes attach at Station level with `mapping_status = 'needs_unit_mapping'` |
| No match, region is East / West / Delta | as above, flagged `not_found_in_assets_database` — 12 such rows |

**Decisions D1 and D2 apply first.** A trailing governorate qualifier is stripped
(`ابنوب اسيوط` → `ابنوب`), and `<base> <n>` is read as Unit *n* of Station `<base>`
(`الخمائل 1` → Unit 1 of `الخمائل`, which has two Units). Each rule fires only when its target
resolves to exactly one Station in the Region; otherwise it proposes and raises an import issue.
Both record `alias_source`, so every rule-created alias is auditable and reversible as a set.

A **proposed** alias never attaches data and never creates an entity. Only a **confirmed** alias
resolves. This is what keeps the ~100–156 unmatched names per file (quality report §2) from
either silently merging into the wrong Station or silently multiplying into duplicates.

Creating a Station for an unmatched name is a last resort, used only where no candidate exists at
all; where candidates exist the row waits for human confirmation rather than duplicating a
Station that is probably already there.

This is how **Canal, Alex and Upper are imported in full** despite having no Unit/Job Number
source. Their stations and units exist, carry every attribute files 1, 3, 4, 5 provide, and hold
`job_number = NULL`. A missing Job Number never blocks creation.

### Attributes from `Station data base.xlsx` → `unit`

| Source col | Target | Notes |
| --- | --- | --- |
| `Bay Status` | `unit.bay_status` enum + `bay_status_raw` | 7 variants → `open` / `closed`; case-fold and `Open Area`→`open` are deterministic |
| `Compressor\n Model` | `compressor.model` | creates the unit's compressor record |
| `Total Running\n Hours` | `unit.total_running_hours` NUMERIC | |
| `Average \nHours / Day` | `unit.avg_hours_per_day` NUMERIC | derived in source; imported as reported |
| `Average Gas\n Sales / Day` | `unit.avg_gas_sales_per_day` NUMERIC + `_raw` TEXT | 3 text values → NULL + raw retained |
| `Dispenser \nModel` | `dispenser.model` | |
| `No. \nOf Dispensers` | `unit.dispenser_count_reported` INT + `_raw` | 36 non-numeric → NULL + raw |
| `No. \nOf Hoses` | `unit.hose_count_reported` INT + `_raw` | 47 non-numeric → NULL + raw. **A count, not hose records.** |
| `Recovery Tank \nModel` | `recovery_tank.model` | |
| `No.\nOf Storage` | `unit.storage_count_reported` INT + `_raw` | |
| `Storage\n Model` | `storage_vessel.model` | applies to the unit's vessels |
| `Gas Detector Model` | `gas_detector.model` | only where presence = installed |
| `Gas Detector Calibration Date` | `gas_detector.last_calibration_*` | date triple; 8 junk values → NULL + flag |
| `Notes` | `unit.notes` | |
| `#` | — | **not imported** (row counter) |

---

## 3. Dispensers and Storage Vessels (file 2)

Continuation rows are attached to the block's unit after forward-fill.

| Source | Target | Notes |
| --- | --- | --- |
| `Dispenser \nModel` | `dispenser.model` | |
| `DIS. Name` | `dispenser.bay_label` | `A-B`, `C-D`, … |
| `DIS. S/N` | `dispenser.serial_number` **TEXT** | `-` (6) and `N/A` (2) → NULL + flag; 195 int-typed → text |
| `No. \nOf Disps` | `unit.dispenser_count_reported` | reconcile with file 1; disagreement is a review item, not an overwrite |
| `Storage\n Model` | `storage_vessel.model` | |
| `Storsge S/N` *(typo)* | `storage_vessel.serial_number` **TEXT** | 38 int-typed → text |
| `No.\nOf Storage` | `unit.storage_count_reported` | |

A dispenser or vessel row with no serial is still imported (principle #5), with
`needs_review = true`.

---

## 4. Vessels — `شهادات الفحص والمعايرة للمناطق .xlsx` (file 4)

`Location` splits the sheet into **two different equipment tables**:

| `Location` | Rows | Target table |
| --- | --- | --- |
| `Storage` | 671 | `storage_vessel` |
| `Recovery` | 528 | `recovery_tank` |

| Source col | Target | Notes |
| --- | --- | --- |
| `Area` | region | alias table |
| `Station` | station/unit resolution | §2 matching; unmatched → retained + flagged |
| `Type OF Compressor` | `…​.compressor_context_raw` TEXT | descriptive only — **not** a foreign key to `compressor` |
| `Location` | table selection + `location_raw` | |
| `Manufacturer` | `…​.manufacturer` + `manufacturer_raw` | 30 spellings; **no auto-merge** (see quality report §5) |
| `Serial Number` | `…​.serial_number` TEXT | 452 int-typed → text; 67 missing → NULL + flag |
| `Last Calibration Date` | `last_calibration_*` triple | 1 malformed (`209/2021`) → NULL + raw + flag |
| `Next Calibration Date` | `next_due_date_*` triple | 79 empty → NULL (no Days Left) |
| `Number Of Days Left` | — | **NOT IMPORTED** |
| `Notes` | `notes` | |

---

## 5. Gas Detectors — `Gas detector.xlsx` (file 5)

Presence is modelled on the **unit**, and a detector record is created only when one exists.

| `Gas detector exist or not exist in Station` | Rows | `unit.gas_detector_presence` | `gas_detector` record |
| --- | --- | --- | --- |
| `Exist in the station` | 178 | `installed` | **created** |
| `Not exist in the station` | 138 | `not_installed` | **none — absence is never given a fake record** |
| *(unit absent from this file)* | — | `unknown` | none |

| Source col | Target | Notes |
| --- | --- | --- |
| `Area` | region | |
| ` Station` | unit resolution | leading space in header |
| ` Open Area / Close Area ` | `unit.area_type` + raw | `Close Area`/`Closed Area` → `closed` (deterministic) |
| `S/N` | `gas_detector.serial_number` TEXT | **3 float-typed values must be read without float formatting**: `1803.02075` stays `"1803.02075"` |
| `Last Calibration Date` | `last_calibration_*` | 2 × `منتهي` → NULL + raw + flag |
| `Next Calibration Date` | `next_due_date_*` | |
| `Notes` | `notes` | |

149 of the 178 installed detectors have **no serial**. They are imported and flagged, never
rejected (principle #5).

---

## 6. Safety Relief Valves — `Warehouse Relief Data.xlsx` (file 3)

Two sheets, two different things. **The `Repair Kit ` sheet is not read at all.**

### 6a. Installed SRVs — sheet `رصيد المحطات` → `installed_srv` (2 662 rows)

This sheet has **no Unit column** and no compressor/vessel/dispenser identifier. `Location`
carries only `Stage` (1 805) or `Storage` (857). Therefore:

| Source evidence | `mapping_status` | `unit_id` | equipment parent |
| --- | --- | --- | --- |
| Station resolves to a station with exactly one unit | `needs_equipment_mapping` | set | NULL |
| Station resolves only to a station with multiple units | `needs_unit_mapping` | NULL | NULL |
| Station name unmatched | *(not promoted)* → import staging + Data Quality queue | — | — |

**No SRV row is auto-assigned to a compressor, vessel or dispenser.** `Location = 'Stage'`
narrows the parent kind to *compressor* and `Location = 'Storage'` to *storage vessel*, and that
hint is stored in `expected_parent_kind` to drive the resolution UI — but it identifies no
specific record, so it never populates a parent FK. **No dispenser SRVs exist in this source.**

The importer is explicitly forbidden to:

- map an SRV to a Unit from Station-name similarity (only a **confirmed** alias resolves a Station)
- assign a `Stage` SRV to a specific Compressor, or a `Storage` SRV to a specific Storage Vessel
- distribute SRVs across Units, compressors or vessels by count, order or any balancing rule
- create a Dispenser SRV
- apply any bulk rule derived from `Location` or name similarity

Expected outcome: **`resolved` = 0.** Every installed SRV arrives unresolved and is worked
through Admin → Data Quality (§11).

| Source col | Target | Notes |
| --- | --- | --- |
| `Area` | region | |
| `Station` | `station_id` via §2 matching | 111 of 343 names unmatched — see quality report |
| `Location` | `expected_parent_kind` (`compressor` / `storage_vessel`) + `location_raw` | **hint only** |
| `Set Pressure` | pressure quad (raw/min/max/unit) | 87 range values; 2 unitless |
| `Manufacturer` | `manufacturer` + raw | |
| `Serial Number` | `serial_number` TEXT | 958 int-typed → text; 120 missing → NULL + flag |
| `Size Type` | `size_type` | |
| `IN` / `OUT` | `port_in` / `port_out` TEXT | fractional inch strings kept as text |
| `Last Calibration Date` | `last_calibration_*` triple | 166 year-only → precision `year` |
| `Next Calibration Date` | `next_due_date_*` triple | 166 year-only → **no notifications** |
| `Number Of Days Left` | — | **NOT IMPORTED** |
| `Next Calibration Month` | — | **NOT IMPORTED** (derived) |
| `Notes` | `notes` | |
| `Column1` | — | artefact |

### 6b. Warehouse SRVs — sheet `رصيد المخزن` → `warehouse_srv` (2 188 rows)

Stock items, **not** installed equipment. They belong to no Unit and must never appear in the
physical hierarchy. They do appear in SRV Management under a warehouse filter.

| Source col | Target | Notes |
| --- | --- | --- |
| `Serial Number` | `serial_number` TEXT | 2 187 distinct — the cleanest identifier available |
| `Availability Status` | `availability_status` enum (5 values) + raw | |
| `Set Pressure` | pressure quad | |
| `Manufacturer`, `Size Type`, `IN`, `OUT` | as above | |
| `Part Number` | `part_number` TEXT | 41 float-typed → text |
| `Last` / `Next Calibration Date` | date triples | 20 year-only |
| `Days Left` | — | **NOT IMPORTED** |
| `Warehouse Code` | `warehouse_code` TEXT | |
| `Warehouse Issue Date` | `issue_date_*` | 708 empty |
| `Area` / `Station` | `assigned_region_id` / `assigned_station_id` | **413/414 empty — unassigned stock, which is valid**, not a defect |
| `Calibration Location` | `calibration_location` | always `SAFE EGYPT` |
| `Notes` | `notes` | |

**Do not merge 6a and 6b on serial number.** A warehouse valve marked
`Sent to Station - Received` may be the same physical valve as an installed row, but proving it
requires serial equality *and* agreement on station and pressure. Candidates are reported, never
auto-merged (quality report §4).

---

## 7. Hoses — `HOSES.xlsx` (file 6)

| Source col | Target | Notes |
| --- | --- | --- |
| `Area` | region | `غرب` → West |
| `STATION` | station/unit resolution | 3 stations only |
| `DESC` | `description` | Arabic; 27 empty |
| `SN ` | `serial_number` TEXT | 70 int-typed → text |
| `WORKING  PRESSURE ` | working-pressure quad | `PSI` and `BAR` both present — **never converted** |
| `TEST PRESSURE` | test-pressure quad | |
| `CALBRATION DATE ` | `last_test_*` triple | |
| `NEXT CLIBRATION DATE` | `next_due_date_*` triple | |

Hoses attach to the resolved unit. Where the source does not say which dispenser a hose serves,
`dispenser_id` stays `NULL` — descriptions such as `خرطوم غاز C` suggest a bay letter but
mapping that to a dispenser's `A-B`/`C-D` label is **not deterministic** and is left to review.

**71 hose records exist, for 3 stations in West.** No hose record is created for any other
region. `Station data base.xlsx` hose *counts* remain a reported attribute of the unit and are
never expanded into synthetic hose rows.

---

## 8. Field-level source precedence

No workbook wins globally. Precedence is declared per field, only where evidence supports it.

| Field | Preferred source | Basis |
| --- | --- | --- |
| Station→Unit structure, Unit Name | `Assets DataBase` | only source stating both levels (East/West/Delta) |
| Unit Job Number | `Assets DataBase` | only source carrying it |
| Gas detector presence / serial / calibration | `Gas detector.xlsx` | dedicated source; file 1 has model only |
| Vessel serial and calibration dates | `شهادات الفحص والمعايرة` | certificate source of record |
| SRV attributes and calibration | `Warehouse Relief Data` | dedicated SRV register |
| Hose asset records | `HOSES.xlsx` | only hose asset source (file 1 gives counts, not records) |
| Running hours, gas sales, bay status | `Station data base.xlsx` | only source |
| Equipment models (compressor, dispenser, storage, recovery) | *(none declared)* | files 1 and 2 overlap; spellings differ — see below |

Where no precedence is declared and two sources disagree, **both values are retained**, the
record is flagged `conflict`, and it stays visible in Data Quality until resolved. A declared
precedence never overwrites a human resolution on re-import.

## 9. Identifier handling (TEXT, always)

| Rule | Applies to |
| --- | --- |
| Read the raw cell; cast to TEXT with **no numeric formatting** | all serials, job numbers, part numbers, warehouse codes |
| **Never** pad a missing leading zero | 958 SRV / 452 vessel / 1 170 warehouse int-typed serials |
| **Never** strip decimal-looking characters | the 3 float-typed gas-detector serials (`1803.02075`) and 41 float part numbers |
| Relocate a **confirmed** part number | `SS-4R3A` (48 rows) is confirmed a part number (D4): `serial_raw` keeps it verbatim, `part_number` receives it, `serial_number = NULL`, `serial_status = 'not_yet_assigned'`. **These rows are not duplicate serials** — the duplicate counts must be recomputed. |
| **Never** "correct" any other wrong-looking value | preserve raw, flag `suspected_part_number_in_serial_column`, await a decision |
| **Never** treat repeats as duplicates without evidence | 38 duplicate SRV serials / 224 rows; 94 vessel serials — reported as candidates only |

A lost leading zero is **not recoverable** from the source and is not guessed. The dry-run
asserts that no identifier column produced a float or scientific-notation string; a failure
aborts the run.

## 10. Date precision at import

Every date column produces `(value, precision, raw)`:

| Source shape | Precision | `value` | Alerts |
| --- | --- | --- | --- |
| Real Excel date | `exact_date` | set | yes |
| Text `d/m/y`, `d-m-y` (format asserted per column) | `exact_date` | set | yes |
| Year only — `2021` int **or** `'2022'` text (332 cells) | `year_only` | **NULL** | **no** |
| Empty | `unknown` | NULL | no |
| `منتهية`, `منتهي`, `شهادة المنشأ`, `209/2021`, `16/8/3033`, `______` | `invalid` | NULL | no |

Only `exact_date` feeds Days Left, Due Today, 7/15/30/60-day alerts and Overdue. Year-only values
stay visible as source information and are **never** expanded to 1 January. `منتهية` ("expired")
is a genuine compliance signal but is imported as `invalid` with its raw text until an engineer
confirms how it should be represented — it is not silently converted into a date or a status.

## 11. Post-import: the mapping queue

Import ends with unresolved records, by design. They are worked in Admin → Data Quality:

| Queue | Population |
| --- | --- |
| SRV unit mapping | installed SRVs at multi-Unit Stations |
| SRV equipment mapping | installed SRVs at single-Unit Stations |
| Station alias confirmation | proposed aliases from every file |
| Unit mapping | Unit-scoped assets in Stations with no known Unit structure (Canal/Alex/Upper) — gates the SRV queue there |
| Serial assignment | SRVs with `serial_status = 'not_yet_assigned'` awaiting their future unique serial (D4) |
| Duplicate candidates | recomputed after D4 removes the part-number clusters from the serial duplicates |
| Invalid / year-only dates | 332 year-only cells plus the invalid set |
| Flagged identifiers | `SS-4R3A`-type values, placeholder serials |
| Missing serials | 149 gas detectors, 120 SRVs, 67 vessels |

Nothing in this queue blocks the rest of the system: the assets exist, appear in their global
management modules, and carry every value the source proved.

## 12. Recalculating operational figures

Figures in `data-quality-report.md` — notably **456 of 1 120 vessel certificates (41 %) overdue**
— are *analytical findings about the source files*, not verified operational truth. They must be
recalculated after date normalization, canonical Station reconciliation, duplicate review, and
final import verification.

**No analytical count from the source analysis is hardcoded anywhere in the application**, its
seeds, or its fixtures. Every operational figure the UI shows is computed from imported data at
read time.

## 13. Explicitly not imported

| Item | Reason |
| --- | --- |
| `Repair Kit ` sheet (8 361 rows) | Out of scope by instruction |
| `Number Of Days Left` / `Days Left` (3 columns) | Stale snapshot; derived at read time (#12, #13) |
| `Next Calibration Month` | Derived from the next calibration date |
| `#` (file 1 col A) | Row counter, not an identifier |
| `Column1` (files 3a, 3b) | Empty artefact column |
| `Sheet2` in files 1, 3, 4, 5 | Stray lookup cells, no records |
| Columns K–BJP of file 4 | Empty; formatting artefact |

---

## 14. Dry-run report (required before any write)

The importer must run in dry-run first and print, per file:

1. header row detected and the full column mapping it inferred
2. rows read / rows mapped / rows flagged, with reasons grouped by count
3. every distinct value that was normalized, and the rule that did it
4. counts per `mapping_status` for SRVs
5. every value that would become NULL because it was a placeholder
6. date-shape counts: real date / text date / year-only / junk
7. the unmatched-station list in full
8. identifier columns asserted **non-numeric** — a failure here aborts the run

No writes occur until a human has reviewed that report.
