# Source Data Dictionary

Read-only analysis of the six supplied Excel workbooks. **No source file was modified**;
the archive was extracted to a scratch directory and every file set to read-only (`chmod 444`)
before parsing.

Analysis date: 2026-09-14. Row counts exclude fully blank rows.

Companion documents: [`import-mapping.md`](./import-mapping.md),
[`data-quality-report.md`](./data-quality-report.md).

---

## 0. File inventory

| # | File | Sheet | Header row | Data rows | Cols | In scope |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `Station data base.xlsx` | `Sheet1` | 1 | 325 | 17 | yes |
| 1 | `Station data base.xlsx` | `Sheet2` | — | 6 | — | no — stray lookup cells |
| 2 | `Assets DataBase - East, west and Delta Completed.xlsx` | `Sheet1` | 1 | 401 | 13 | yes |
| 3 | `Warehouse Relief Data.xlsx` | `رصيد المحطات` (station balance) | **5** | 2 662 | 15 | yes — installed SRVs |
| 3 | `Warehouse Relief Data.xlsx` | `رصيد المخزن` (warehouse balance) | **5** | 2 188 | 18 | yes — warehouse SRVs |
| 3 | `Warehouse Relief Data.xlsx` | `Repair Kit ` | — | 8 361 | 21 | **NO — excluded by instruction** |
| 3 | `Warehouse Relief Data.xlsx` | `Sheet2` | — | 12 | — | no — stray lookup cells |
| 4 | `شهادات الفحص والمعايرة للمناطق .xlsx` | `رصيد المحطات` | **5** | 1 199 | 10 real | yes — vessels |
| 4 | `شهادات الفحص والمعايرة للمناطق .xlsx` | `Sheet2` | — | 12 | — | no — stray lookup cells |
| 5 | `Gas detector.xlsx` | `Sheet1` | 1 | 316 | 8 | yes |
| 5 | `Gas detector.xlsx` | `Sheet2` | — | 2 | — | no — stray cells |
| 6 | `HOSES.xlsx` | `Sheet1` | 1 | 71 | 8 | yes |

Two structural warnings that apply before any column is read:

- **Files 3 and 4 have their header on row 5**, not row 1. Rows 1–4 hold a title banner and a
  stray `SIZE` label. An importer that assumes row 1 silently shifts every column.
- **File 4's sheet reports 1 628 columns** (`A1:BJP7496`) because of stray formatting. Only
  columns A–J carry data; the rest are empty and must be ignored by an explicit column limit.

---

## 1. `Station data base.xlsx` → Sheet1

**Grain: one row per UNIT, not per Station.** See
[data-quality-report.md §3](./data-quality-report.md#3-station-vs-unit-grain--the-central-mapping-problem).
This is the most consequential finding in the analysis.

317 of 325 rows carry a name; 8 rows are blank-but-formatted trailing rows.

| Col | Header (raw) | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `#` | int | — | Row counter, not an identifier. Do not import as a key. |
| B | `Station Name` | str 317, empty 8 | 315 | Arabic. **Unit-grain** (e.g. `شبرا 1`…`شبرا 4`). |
| C | `Area` | str 317, empty 8 | **7** | `East`, `WEST`, `Upper`, `UPPER`, `Alex`, `CANAL`, `Delta` — 7 variants of 6 regions. |
| D | `Bay Status` | str 317, empty 8 | **7** | `OPEN` 147, `CLOSED` 109, `Closed Area` 29, `Open Area` 25, `open` 5, `Close Area` 1, `closed` 1. |
| E | `Compressor\n Model` | str 315, empty 10 | 25 | |
| F | `Total Running\n Hours` | int 290, float 9, empty 26 | 285 | Numeric metric, safe to import as numeric. |
| G | `Average \nHours / Day` | float 71, int 236, empty 18 | 88 | Derived metric; recompute rather than trust. |
| H | `Average Gas\n Sales / Day` | int 169, str 3, empty 153 | 86 | 3 text values in a numeric column. |
| I | `Dispenser \nModel` | str 300, int 1, empty 24 | 23 | 1 numeric-typed model value. |
| J | `No. \nOf Dispensers` | int 264, **str 36**, empty 25 | 9 | 36 non-numeric counts. |
| K | `No. \nOf Hoses` | int 253, **str 47**, empty 25 | 11 | 47 non-numeric counts. |
| L | `Recovery Tank \nModel` | str 313, empty 12 | 26 | |
| M | `No.\nOf Storage` | int 281, str 1, empty 43 | 15 | |
| N | `Storage\n Model` | str 279, empty 46 | 23 | |
| O | `Gas Detector Model` | str 201, empty 124 | 30 | |
| P | `Gas Detector Calibration Date` | **datetime 68, str 49 (d/m/y), str 8 (other), empty 200** | 48 | Mixed real dates and text. Junk values `______`, `__________`, `منتهى` (expired). Contains `16/8/3033` — implausible year. |
| Q | `Notes` | str 16, empty 309 | 4 | |

Header names contain embedded newlines (`Compressor\n Model`). Match on normalized headers.

---

## 2. `Assets DataBase - East, west and Delta Completed.xlsx` → Sheet1

**Grain: block-structured.** `Area`, `Station Name`, `Unit Name` are written **once per block**
and left blank on continuation rows, which carry additional dispenser/storage serials. Reading
row-by-row without forward-fill yields 398 rows with no Area.

Reconstructed by forward-fill: **188 units across 156 stations in 3 regions.**

| Col | Header (raw) | Type profile | Notes |
| --- | --- | --- | --- |
| A | `Area` | str 3, empty 398 | Written once per region block: `East`, `WEST`, `DELTA`. |
| B | `Station Name` | str 157, empty 244 | **Station-grain** (e.g. `شبرا`). Forward-fill required. |
| C | `Unit Name` | str 188, empty 213 | **Unit-grain** (e.g. `شبرا 1`). 183 distinct. |
| D | `Compressor\n Model` | str 188 | One per unit. 30 distinct. |
| E | `Unit Job No.` | **str 157, int 30**, empty 214 | 186 present, **2 missing**. Mixed formats: `2826ps001`, `MC 1138`, `SC21006-013`, `2888 / 2891`, and 30 stored as **integers** (`30157`, `212115`). |
| F | `Dispenser \nModel` | str 173 | |
| G | `No. \nOf Disps` | int 135, str 31 | |
| H | `DIS. Name` | str 356 | Bay pairs: `A-B`, `C-D`, `E-F`, `G-H`. |
| I | `DIS. S/N` | **int 195**, str 158, empty 48 | 341 distinct. Includes placeholders `-` (6×) and `N/A` (2×). |
| J | `No.\nOf Storage` | int 160, str 1 | |
| K | `Storage\n Model` | str 160 | |
| L | `Storsge S/N` *(sic — typo in source)* | str 212, **int 38**, empty 151 | 250 distinct. |

Region coverage: `DELTA` 74 units, `WEST` 58, `East` 56. **Canal, Alex and Upper are absent
from this file** — their Units and Job Numbers are simply not available here and must come from
the other files with `job_number` left `NULL`.

---

## 3. `Warehouse Relief Data.xlsx`

### 3a. Sheet `رصيد المحطات` — installed / station relief valves (2 662 rows)

Header on **row 5**. Row 4 holds a stray `SIZE` label above the IN/OUT pair.

| Col | Header | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `Area` | str 2 662 | 6 | All six canonical regions, clean spelling. |
| B | `Station` | str 2 662 | **343** | Arabic. More names than the 315 in file 1 — some are unit-level (`ابو رواش 1`, `ابو رواش 2`). |
| C | `Location` | str 2 662 | **2** | **`Stage` 1 805, `Storage` 857.** See below — this does *not* identify the SRV's parent equipment in the three-way sense. |
| D | `Set Pressure` | str 2 625, int 2, empty 35 | 80 | `275 BAR`, `5500 PSI`, `17.7 BAR`, and ranges such as `(275-344) BAR` (87 rows). |
| E | `Manufacturer` | str 2 640, empty 22 | 9 | |
| F | `Serial Number` | str 1 584, **int 958**, empty 120 | 2 318 | |
| G | `Size Type` | str 2 636, empty 26 | 4 | `Male` etc. |
| H | `IN` | str 2 633, empty 29 | 6 | Fractional inch strings (`3/4"`, `1/4"`). |
| I | `OUT` | str 2 636, empty 26 | 5 | |
| J | `Last Calibration Date` | **datetime 2 294, year-only 166, str d/m/y 39, str other 16, empty 147** | 111 | |
| K | `Next Calibration Date` | **datetime 2 309, year-only 166, str d/m/y 24, str other 16, empty 147** | 115 | |
| L | `Number Of Days Left` | int | 91 | **Do not import.** Includes `-44257` where the date is year-only. |
| M | `Next Calibration Month` | str/int | — | Derived from column K; do not import. |
| N | `Notes` | str | — | |
| O | `Column1` | empty | — | Artefact column. |

**`Location` semantics.** The two values are `Stage` (a compressor stage relief valve) and
`Storage` (a storage-vessel relief valve). This means:

- No row in this sheet identifies a **dispenser** SRV.
- `Stage` tells us the parent is a *compressor* but **not which compressor**, and no compressor
  serial or unit column exists in this sheet.
- There is **no Unit column at all**.

Consequently **no row in this sheet can be resolved to a specific parent equipment record from
this file alone.** This is exactly the case the `mapping_status` model in
[`architecture.md`](./architecture.md) was revised to handle.

### 3b. Sheet `رصيد المخزن` — warehouse relief valves (2 188 rows)

Header on **row 5**. These are stock items, not installed equipment.

| Col | Header | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `Set Pressure` | str 2 188 | 76 | |
| B | `Manufacturer` | str 2 188 | 10 | |
| C | `Availability Status` | str 2 188 | **5** | `Sent to Station - Received` 973, `Sent to Station - Not Received` 510, `Available in Store UC` 388, `Available Calibrated` 310, `Available New` 7. |
| D | `Serial Number` | str 1 017, **int 1 170**, empty 1 | **2 187 — effectively unique** | Best identifier in the whole dataset. |
| E | `Size Type` | str | 4 | |
| F | `IN` | str | 4 | |
| G | `OUT` | str | 3 | |
| H | `Part Number` | str 2 124, **float 41**, int 2, empty 21 | 89 | 41 float-typed part numbers. |
| I | `Last Calibration Date` | datetime 1 854, year-only 20, empty 314 | 98 | Year-only values `2009`–`2021`. |
| J | `Next Calibration Date` | datetime 1 854, year-only 20, empty 314 | 98 | |
| K | `Days Left` | int | 99 | **Do not import.** |
| L | `Warehouse Code` | str 2 187, empty 1 | 186 | e.g. `acc 794`. |
| M | `Warehouse Issue Date` | datetime 1 480, empty 708 | 100 | |
| N | `Area` | str 1 775, **empty 413** | 6 | Empty where the valve has not been assigned out. |
| O | `Station` | str 1 774, **empty 414** | 303 | |
| P | `Calibration Location` | str 2 144, empty 44 | **1** | Always `SAFE EGYPT`. |
| Q | `Notes` | str 140, empty 2 048 | 8 | |

### 3c. Sheet `Repair Kit ` — **EXCLUDED**

8 361 rows × 21 columns. Out of scope by instruction. Not analyzed, not mapped, not imported.

---

## 4. `شهادات الفحص والمعايرة للمناطق .xlsx` → `رصيد المحطات` (1 199 rows)

"Inspection and calibration certificates by region". Header on **row 5**; only columns A–J are real.

| Col | Header | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `Area` | str 1 199 | 6 | East 247, Delta 243, Upper 226, West 196, Alex 154, Canal 133. **All six regions present.** |
| B | `Station` | str 1 199 | 317 | Arabic. |
| C | `Type OF Compressor` | str 1 034, empty 165 | 25 | e.g. `Fornovo (3)`. Context, not a foreign key. |
| D | `Location` | str 1 199 | **2** | **`Storage` 671, `Recovery` 528.** |
| E | `Manufacturer` | str 1 187, empty 12 | **30** | Heavy spelling inconsistency — see quality report. |
| F | `Serial Number` | str 680, **int 452**, empty 67 | 1 036 | |
| G | `Last Calibration Date` | datetime 1 119, str 1, empty 79 | 93 | One malformed value `209/2021`. |
| H | `Next Calibration Date` | datetime 1 120, empty 79 | 90 | |
| I | `Number Of Days Left` | int 1 199 | 91 | **Do not import.** |
| J | `Notes` | str 30, empty 1 169 | 3 | |

**`Location` distinguishes two different physical equipment entities**, as instructed:
`Storage` → storage vessel (child of a Unit, may parent an SRV);
`Recovery` → recovery tank (child of a Unit, **not** an SRV parent in the hierarchy).
These must not be merged into one table.

---

## 5. `Gas detector.xlsx` → Sheet1 (316 rows)

| Col | Header | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `Area` | str 316 | 6 | Clean canonical spelling. |
| B | ` Station` *(leading space)* | str 316 | 315 | Unit-grain names (`الماظة 1`). |
| C | ` Open Area / Close Area ` | str 316 | **3** | `Open Area` 176, `Close Area` 110, `Closed Area` 30. |
| D | `Gas detector exist or not exist in Station` | str 316 | **2** | `Exist in the station` **178**, `Not exist in the station` **138**. |
| E | `S/N` | str 24, **float 3**, int 2, empty 287 | 29 | Only 29 serials for 178 declared-existing detectors. Floats `1803.02075` — Excel numeric coercion of a dotted serial. |
| F | `Last Calibration Date` | datetime 115, str 2 (`منتهي`), empty 199 | 39 | |
| G | `Next Calibration Date` | datetime 115, str 2 (`منتهي`), empty 199 | 40 | |
| H | `Notes` | str 14, empty 302 | 3 | |

**Absence is data.** The 138 `Not exist in the station` rows are positive evidence of absence.
Per instruction, no Gas Detector record is created for them; the *unit* carries a
`gas_detector_presence` of `not_installed`. The tri-state is
`installed` (178) / `not_installed` (138) / `unknown` (units absent from this file entirely).

---

## 6. `HOSES.xlsx` → Sheet1 (71 rows)

| Col | Header | Type profile | Distinct | Notes |
| --- | --- | --- | --- | --- |
| A | `Area` | str 71 | **1** | **`غرب` only** (Arabic for West). |
| B | `STATION` | str 71 | **3** | `فيصل توتال` 26, `التعاون - رمسيس` 23, `فيصل التعاون` 22. |
| C | `DESC` | str 44, **empty 27** | 22 | Arabic hose descriptions (`خرطوم غاز C`, `وصلة فنت D`). |
| D | `SN ` | **int 70**, empty 1 | 70 | All numeric-typed. |
| E | `WORKING  PRESSURE ` | str 70, empty 1 | 4 | `1000 PSI` 27, `240 BAR` 25, `5000 PSI` 11, `8 BAR` 7. **Mixed units.** |
| F | `TEST PRESSURE` | str 70, empty 1 | 4 | `1500 PSI`, `360 BAR`, `7500 PSI`, `12 BAR`. |
| G | `CALBRATION DATE ` *(sic)* | datetime 70, empty 1 | 3 | |
| H | `NEXT CLIBRATION DATE` *(sic)* | datetime 70, empty 1 | 3 | |

**Coverage is 3 stations in one region.** The other five regions have no hose data. Per
instruction, nothing is fabricated for them — hose records simply do not exist, which is
distinct from a hose count of zero. Note that `Station data base.xlsx` column K
(`No. Of Hoses`) gives *counts* for many stations; a count is not an asset record and the two
must not be conflated.

---

## 7. Cross-cutting value domains

### Region / Area

| Raw value | Occurrences | Canonical | Deterministic? |
| --- | --- | --- | --- |
| `East` | files 1,3,4,5 | East | yes |
| `WEST`, `West` | files 1,3,4,5 | West | yes |
| `غرب` | file 6 (71 rows) | West | yes — documented alias |
| `Delta`, `DELTA` | files 1,2,3,4,5 | Delta | yes |
| `CANAL`, `Canal` | files 1,3,4,5 | Canal | yes |
| `Alex` | files 1,3,4,5 | Alex | yes |
| `Upper`, `UPPER` | files 1,3,4,5 | Upper | yes |

All observed region values normalize deterministically under the documented alias table
(case-folding plus `غرب` → West). **No region value requires a guess.** The raw value is still
preserved per data principle #6.

### Pressure

Three shapes occur and must be preserved verbatim alongside any parse:

| Shape | Example | Parse |
| --- | --- | --- |
| Scalar + unit | `275 BAR`, `5500 PSI`, `17.7 BAR` | numeric + unit, deterministic |
| Range + unit | `(275-344) BAR` (87 rows) | min + max + unit; **no single scalar** |
| Bare number | 2 rows in file 3a | numeric, **unit unknown** → leave unit NULL |

**PSI and BAR are never converted into one another.** Conversion is a display-layer concern and
requires a stated source unit.

### Dates

Six shapes occur. See [data-quality-report.md §6](./data-quality-report.md#6-dates).

| Shape | Example | Handling |
| --- | --- | --- |
| Real Excel date | `2026-08-08` | normalize; precision `day` |
| Text `d/m/y` | `15/12/2025`, `19/1/2026` | normalize; precision `day` |
| Text `d-m-y` | `16-6-2025` | normalize; precision `day` |
| **Year only** | `2021` (int), `'2022'` (str) | **precision `year`; no exact date invented; excluded from notifications** |
| Arabic status text | `منتهية` / `منتهي` (expired), `شهادة المنشأ` (certificate of origin) | not a date — keep raw, flag for review |
| Junk / malformed | `______`, `209/2021`, `16/8/3033` | not a date — keep raw, flag for review |

### `Days Left` columns — all three are excluded from import

`Number Of Days Left` (files 3a, 4) and `Days Left` (file 3b) are stored snapshots. They are
cached spreadsheet values, correct only as of the last save, and they degrade to nonsense where
the date is year-only — file 3a contains **`-44257`** on a row whose next calibration is the
string `2022`. Days Left is derived at read time from `next_due_date − current_date`, and is
`NULL` when no exact due date exists.
