# Data Quality Report

Findings from the read-only analysis of the six source workbooks (2026-09-14).
**No source file was modified. Nothing has been imported.**

Column-level detail: [`data-dictionary.md`](./data-dictionary.md).
Resulting decisions: [`import-mapping.md`](./import-mapping.md).

---

## 1. Summary

| Severity | Finding | Section |
| --- | --- | --- |
| **Blocker** | `Station data base.xlsx` is unit-grain; `Assets DataBase` is station+unit-grain. The two cannot be joined without a decision. | §3 |
| **Blocker** | No SRV row in any source identifies its parent equipment record. 2 662 installed SRVs are unresolvable from the sources alone. | §4 |
| **High** | 100–156 station names per file do not match the station master, even after Arabic normalization. | §2 |
| **High** | 332 date cells are year-only; 3 `Days Left` columns are stale snapshots, one reading `-44257`. | §6, §7 |
| **High** | Identifiers stored as Excel numbers in 6 columns; 3 gas-detector serials stored as **floats**. | §8 |
| **Medium** | 38 duplicate SRV serials spanning 224 rows; 94 duplicate vessel serials. | §9 |
| **Medium** | Manufacturer and model spelling inconsistent throughout (31 vessel manufacturers, 30 gas-detector models). | §5 |
| **Medium** | 149 of 178 installed gas detectors have no serial; 120 SRVs and 67 vessels likewise. | §10 |
| **Low** | 2 units lack a Job Number; 3 regions have no Job Number source at all. | §11 |
| **Low** | Wrong-column data: `Gas Detector Model` contains `OPEN AREA`; `Dispenser Model` contains `0`. | §5 |

Every finding below is **retained-and-flagged**, never dropped and never guessed.

---

## 2. Unmatched stations

Station names were compared across files after deterministic Arabic normalization (NFKC, strip
tatweel and diacritics, fold `أإآ→ا`, `ى→ي`, `ة→ه`, collapse whitespace). Using
`Station data base.xlsx` (315 distinct names) as the master:

| Source | Distinct names | Not matching the master | Rate |
| --- | --- | --- | --- |
| `Gas detector.xlsx` | 315 | **100** | 32 % |
| `Warehouse Relief Data` (stations) | 343 | **111** | 32 % |
| `شهادات الفحص والمعايرة` (vessels) | 317 | **156** | 49 % |
| `HOSES.xlsx` | 3 | 1 | — |

Three distinct causes, none of them safely automatable:

**(a) Governorate qualifier added or dropped.**
`ابنوب` vs `ابنوب اسيوط` · `ابو القمصان` vs `ابو القمصان - بورسعيد` · `ابو تيج- اسيوط` vs
`ابوتيج` vs `ابو تيج اسيوط`. Three files spell the same station three ways, with the separator
varying between space, hyphen and none.

**(b) Unit number appended.** The relief-valve sheet has `ابو رواش 1` and `ابو رواش 2` where the
master has `ابو رواش`. These are *unit* names in a column labelled `Station` — see §3.

**(c) Genuinely different or renamed sites.** `الجولي فيل` vs `الاقصر (جولي فيل)`,
`البراجيل القديمه`, `الخمائل` vs `الخمائل 1`/`الخمائل 2`.

Cause (b) is indistinguishable from cause (c) by string shape alone: `الخمائل 1` could be
unit 1 of `الخمائل`, or a separate station. **Auto-matching would silently attach safety
equipment to the wrong physical asset.** Per data principle #8 these rows are imported into
staging with their raw name and surfaced in Admin → Data Quality for human confirmation.

> **Decision needed:** whether the governorate qualifier is decorative (making `ابنوب` and
> `ابنوب اسيوط` the same site). If confirmed by an engineer, a suffix-stripping rule becomes
> deterministic and clears a large share of category (a) at once.

---

## 3. Station vs Unit grain — the central mapping problem

`Station data base.xlsx` labels column B `Station Name`, but the values are **units**:

```
Station data base.xlsx : شبرا 1, شبرا 2, شبرا 3, شبرا 4   (4 rows)
Assets DataBase        : station شبرا  →  units شبرا 1, شبرا 2, شبرا 3, شبرا 4
```

Checked across the 194 master rows in East/West/Delta:

| Match target in `Assets DataBase` | Rows |
| --- | --- |
| Matches a **Unit** name | 107 |
| Matches a **Station** name | 130 |
| Matches neither | 12 |

The totals overlap because single-unit stations have identical station and unit names
(`الاستاد`, `النزهة`) — which is precisely why the ambiguity is invisible at a glance.

Consequences:

- The 325-row "station database" describes roughly **315 units**, not 315 stations.
- Any count of "stations" taken from that file is inflated wherever a station has several units.
- 27 stations have more than one unit (maximum 4), so this affects a substantial minority.
- For a multi-unit station, an attribute in the master row (running hours, compressor model)
  belongs to **that unit**, not to the station.

The import treats the master file as unit-grain and derives stations from `Assets DataBase`
where available (§2 of the mapping document). For Canal, Alex and Upper — which have no
`Assets DataBase` coverage — each master row becomes a station with **one** unit of the same
name, flagged `unit_structure_unknown_no_assets_source`. If such a station in fact has several
units, that is discoverable later and correctable; inventing units now would not be.

---

## 4. Uncertain Relief Valve equipment mapping

**This is the most significant structural finding, and it validates the mapping-status model.**

The installed-SRV sheet (`رصيد المحطات`, 2 662 rows) contains **no Unit column and no
compressor, vessel, or dispenser identifier.** Its only placement evidence is:

| Column | Values |
| --- | --- |
| `Area` | 6 canonical regions, clean |
| `Station` | 343 names, 111 unmatched (§2) |
| `Location` | **`Stage` 1 805, `Storage` 857** — and nothing else |

`Stage` denotes a compressor-stage relief valve; `Storage` denotes a storage-vessel relief
valve. So:

1. **Not one row can name its parent equipment record.** `Stage` narrows the parent *kind* to
   compressor, but a unit may have several compressors and the sheet distinguishes none of them.
2. **No dispenser SRVs exist in this source at all**, though the hierarchy permits them.
3. With no Unit column, even unit placement is unavailable except by inference from the station
   name — and where a station has multiple units, that inference is unavailable too.

Resulting `mapping_status` distribution at import (exact figures depend on how many of the 111
unmatched station names resolve):

| Status | Expected population |
| --- | --- |
| `resolved` | **0** — no source evidence can produce one |
| `needs_equipment_mapping` | rows whose station resolves to a single-unit station |
| `needs_unit_mapping` | rows whose station resolves only to a multi-unit station |
| *(staging, not promoted)* | rows whose station name is unmatched |

Had the strict "exactly one equipment parent, always" constraint from the original design
survived, **every one of these 2 662 safety-critical records would have been rejected at
import.** The revised model stores all of them with their proven station, keeps them searchable
and due-date-tracked in Global SRV Management, and queues them for engineer resolution.

`Location` is retained as `expected_parent_kind` to pre-filter the resolution UI — a hint that
narrows the choice, never a value that populates a parent foreign key.

---

## 5. Inconsistent manufacturer and model spelling

**Vessel manufacturers — 31 distinct strings, containing obvious near-duplicates:**

| Probable same entity | Variants observed |
| --- | --- |
| Worthington | `Worthington\n Cylinders` (15, with embedded newline), `Worthing Cylinders` (11) |
| SAFE | `SAFE` (102), `Safe` (133) |
| NK | `NK` (44), `NK CO.,LTD.` (123) |
| NPSAC / NPAC | `NPSAC` (54), `NPAC` (12) — possibly a typo, possibly two firms |
| *(unusable)* | `usa` (1), `Holding` (4) |

**SRV manufacturers:** `Anderson` (188 installed / 295 warehouse) vs `Tyco Anderson` (7). Tyco
acquired Anderson Greenwood, so these are plausibly the same maker — plausibly is not
deterministic.

**Models in `Station data base.xlsx`:**

| Column | Distinct | Examples of the inconsistency |
| --- | --- | --- |
| Compressor | 25 | `ANGI`/`Angi`; `CUBO`/`Cubo`/`CUBOGAS`; `GALILEO`/`GALLILEO`/`Galileo`; `SAFE`/`Safe`/`safe`; `Kir` (truncated?) |
| Dispenser | 23 | `GALILEO`/`GALLILEO`/`Galielio`; `safe (new )`/`safe (old)`; `ANGI SERIES II\nSafe`; **`0`** |
| Recovery tank | 26 | `EURE CO . LTD`/`EURE CO.LTD`; `STEEL FAB .INK`/`Fab Steel`; `WORTHIGTON CYLINDERA`; `GRAF - 6R0001102` (model + serial in one cell) |
| Storage | 23 | `C.P INDUSTRIES`/`C.P.I`/`CP INDUSTRIES`/`cp Industries`; `N.K`/`NK`/`Nk Aether`; `NAPSAC`/`NPSAC`; `Cylinders`, `USA` |
| Gas detector | 30 | `GIR-3000`/`GASTRON-GIR-3000`; `GMI`/`GMI - SPGA`/`GMI-SPGA`/`SPGA`; **`OPEN AREA`, `Open area`** |

**Wrong-column data.** `Gas Detector Model` holds `OPEN AREA`/`Open area` — values belonging to
the bay-status column. `Dispenser Model` holds `0`.

**Treatment.** Case-folding and whitespace collapsing are deterministic and are applied, with
the raw string preserved. Everything else — `NPSAC`↔`NPAC`, `Anderson`↔`Tyco Anderson`,
`Worthington`↔`Worthing` — is **reported as a merge candidate and left unmerged** (principle
#7). A curated alias table, confirmed by an engineer, is the correct fix; inferring one from
string distance is not. Wrong-column values import as raw text and are flagged.

---

## 6. Dates

### Year-only values — 332 cells

| File | Column | Year-only cells | Values |
| --- | --- | --- | --- |
| Relief valves (stations) | Last Calibration | **166** (151 int + 15 text) | `2021` |
| Relief valves (stations) | Next Calibration | **166** (71 int + 95 text) | `2022` |
| Relief valves (warehouse) | Last Calibration | 20 | `2009`, `2010`, `2015`, `2020`, `2021` |
| Relief valves (warehouse) | Next Calibration | 20 | `2010`, `2011`, `2016`, `2021`, `2022` |

Note the same year appears both as an **integer** `2021` and as a **text** `'2021'` in one
column — a type check alone will not find them all.

Per instruction, `2021` is **never** expanded to `01/01/2021`. Each date is stored as
`(value DATE NULL, precision 'year'|'day', raw TEXT)` with `value = NULL` at year precision.
Year-precision records are excluded from exact-date notifications and show "Year only — exact
date unknown" instead of a Days Left figure.

### Malformed and non-date values

| Value | File / column | Meaning |
| --- | --- | --- |
| `منتهية` (16 rows) | RV stations, both date columns | "expired" — a status, not a date |
| `شهادة المنشأ` | RV stations, both date columns | "certificate of origin" — a document reference |
| `منتهي` (2 rows) | Gas detector, both date columns | "expired" |
| `209/2021` | Vessels, Last Calibration | malformed — `20/9/2021`? `2/09/2021`? **not resolvable** |
| `______`, `__________` | Station DB, gas-detector date | deliberate blanks |
| `منتهى` | Station DB, gas-detector date | "expired" |
| **`16/8/3033`** | Station DB, gas-detector date | year 3033 — almost certainly `2033` or `2023`, but **guessing which is a fabrication** |

All are preserved raw with `value = NULL` and flagged. `منتهية`/`منتهي` is a genuine compliance
signal (the item is overdue) and should become an explicit status once an engineer confirms the
reading — it is not silently converted into a date.

### Mixed text-date formats

`Station data base.xlsx` column P mixes real dates (68) with **49 text dates** in inconsistent
shapes: `14/12/2025`, `16-6-2025`, `14/8/2023`. The relief-valve sheet adds `19/1/2026` (single
digit day and month). All observed text dates are unambiguously **day-first** (a day value above
12 appears in enough samples to settle the column), so parsing is deterministic *per column* —
but that must be asserted by the importer per column, never assumed globally.

### Conflicting calibration dates

| File | Pairs with both dates | `next ≤ last` |
| --- | --- | --- |
| RV stations | 2 286 | 0 |
| RV warehouse | 1 854 | 0 |
| Vessels | 1 119 | **1** (`2026-03-01` → `2026-03-01`) |
| Gas detectors | 115 | **1** (`2025-10-21` → `2025-10-21`) |

Both cases are a zero-length interval — last and next identical. Intervals are otherwise highly
consistent (SRVs and detectors 1 year; vessels 5 years), which makes these two visible as errors
rather than as a policy difference. Flagged, not corrected.

### Already overdue at time of analysis

| Source | Overdue / with a next date |
| --- | --- |
| Vessels | **456 / 1 120 (41 %)** |
| Gas detectors | 53 / 115 (46 %) |
| Relief valves (stations) | 300 / 2 309 (13 %) |
| Relief valves (warehouse) | 88 / 1 854 (5 %) |

Not a data defect, but a material operational finding: a large share of vessel certificates has
lapsed. Worth confirming with the asset owner that these are genuinely overdue rather than
recalibrated-but-unrecorded, since the answer changes what the system should alert on at launch.

---

## 7. `Days Left` columns are unusable

Three columns carry a precomputed Days Left. All three are excluded (principles #12, #13).

- **They are cached snapshots.** The values were computed when the workbook was last saved and
  are stale from that moment on.
- **They break entirely on year-only dates.** The relief-valve sheet contains **`-44257`** on a
  row whose next calibration is the text `2022` — the formula subtracted a date from a number.
  A record showing "overdue by 121 years" would be an alarming and meaningless alert.
- Even ignoring those, 9 rows in the relief-valve sheet disagree with a recomputation from their
  own `Next Calibration Date`.

Days Left is derived at read time and is `NULL` — never `0`, never "overdue" — wherever no exact
due date exists.

---

## 8. Identifiers damaged by Excel typing

| Column | File | Numeric-typed cells | Risk |
| --- | --- | --- | --- |
| `S/N` (gas detector) | 5 | **3 floats** — `1803.02075`, `1803.02079`, `1803.02072` | **Highest.** A dotted serial read as a float loses trailing zeros and may render in scientific notation. |
| `Serial Number` (SRV stations) | 3a | 958 ints | Leading zeros lost — the sheet also contains text serials such as `0003262609`, proving leading zeros are significant here |
| `Serial Number` (SRV warehouse) | 3b | 1 170 ints | as above |
| `Serial Number` (vessels) | 4 | 452 ints | as above |
| `DIS. S/N` | 2 | 195 ints | |
| `Storsge S/N` | 2 | 38 ints | |
| `SN` (hoses) | 6 | 70 ints | |
| `Unit Job No.` | 2 | 30 ints | |
| `Part Number` | 3b | **41 floats** + 2 ints | |

`0003262609` appearing as text in the same column where other serials are integers is direct
evidence that leading zeros carry meaning and have already been lost in the numeric cells.
**Whether a lost leading zero can be recovered is unknown** — the importer must not pad
speculatively.

All identifier columns import as TEXT from the raw cell value with no numeric formatting. The
dry-run asserts that no identifier column produced a float or scientific-notation string; a
failure aborts the run rather than writing corrupted serials.

---

## 9. Duplicates

### Duplicate serial numbers

| Source | Rows | Present | Distinct | Duplicate values | Extra rows |
| --- | --- | --- | --- | --- | --- |
| SRV stations | 2 662 | 2 542 | 2 318 | **38** | **224** |
| SRV warehouse | 2 188 | 2 187 | 2 187 | 0 | 0 |
| Vessels | 1 199 | 1 132 | 1 036 | **94** | **96** |
| Dispensers | 401 | 353 | 341 | 8 | 12 |
| Storage / hoses / gas detectors | — | — | — | 0 | 0 |

Worst SRV offenders: `SS-4R3A` on **48 rows**, `0003262609` on 34, `0003173616` on 32.

> **Resolved by decision D4** (`decisions.md`): `SS-4R3A` is confirmed a **part number**, and this
> SRV type has no unique serial assigned yet. Those 48 rows move to `part_number` with
> `serial_status = 'not_yet_assigned'` and **leave the duplicate-serial set**. The duplicate
> counts in this table are therefore pre-decision figures and must be recomputed at import. Dispenser duplicates are mostly placeholders (`-` ×6, `N/A` ×2),
which become NULL rather than duplicates.

The warehouse sheet is the one clean identifier space in the dataset: 2 187 distinct serials in
2 188 rows.

### Duplicate candidate rows

Keyed on `(area, station, location, serial, set pressure)` in the installed-SRV sheet:
**71 keys covering 142 extra rows**, e.g. 6 identical rows for
`(West, مصدق, Storage, 0003218822, (275-344) BAR)` and 6 for
`(East, نفق العبور 1, Storage, SS-4R3A, 330 BAR)`.

These are genuinely ambiguous. A station may legitimately have six identical relief valves of
the same model and pressure on six identical vessels — that is normal engineering. Or the rows
may be a copy-paste artefact. **Nothing here distinguishes the two**, so all rows import and the
groups are reported as suspected duplicates for human resolution. Silent de-duplication could
erase real safety devices from the register.

### Cross-sheet duplicates

A warehouse valve marked `Sent to Station - Received` (973 rows) may be the same physical device
as an installed row. Serial spaces overlap. These are reported as link candidates and **never
auto-merged** — merging on serial alone would be unsound given the `SS-4R3A` finding above.

### Duplicate job numbers

4 job numbers appear on 2 units each: `2919ps003`, `CSKD0000459N-2`, `SC21006/092`,
`SC21006/030`. Job numbers are therefore **not unique** and must not be used as a key.

---

## 10. Missing serial numbers

| Asset type | Rows | Missing serial | Rate |
| --- | --- | --- | --- |
| Gas detectors *(installed only)* | 178 | **149** | **84 %** |
| SRV stations | 2 662 | 120 | 5 % |
| Vessels | 1 199 | 67 | 6 % |
| Dispensers | 401 | 48 (+8 placeholders) | 12 % |
| Storage (assets file) | 401 | 151 | 38 % |
| SRV warehouse | 2 188 | 1 | 0 % |
| Hoses | 71 | 1 | 1 % |

Only 29 serials exist for 178 detectors declared present. Per principle #5 none of these records
is invalidated: the asset exists, is tracked, and carries `needs_review`. The 120 SRVs without a
serial collapse into just 73 distinct station/location/pressure groups, so they are additionally
indistinguishable from one another within a station — recorded as such rather than arbitrarily
numbered.

---

## 11. Missing Job Numbers

| Scope | Units | Job Number present |
| --- | --- | --- |
| East / West / Delta (`Assets DataBase`) | 188 | 186 |
| Canal / Alex / Upper | ~127 master rows | **0 — no source file contains them** |

Job numbers are also **non-uniform in format** (`2826ps001`, `MC 1138`, `SC21006-013`,
`2888 / 2891`, `212115`), **non-unique** (§9), and **30 are stored as integers**. They are
therefore imported as a TEXT attribute, never as a key.

Per principle #4, no Station or Unit creation is blocked by a missing Job Number. Canal, Alex
and Upper import in full from files 1, 3, 4 and 5 with `job_number = NULL`.

---

## 12. Structural hazards in the files themselves

| Hazard | Detail | Mitigation |
| --- | --- | --- |
| Header not on row 1 | Files 3a, 3b, 4 have headers on **row 5** | Header row asserted explicitly per file; dry-run prints the detected header and mapping |
| Phantom column range | File 4 reports **1 628 columns**; only A–J are real | Explicit `max_col` |
| Block/merged layout | File 2 writes Area/Station/Unit once per block — 398 of 401 rows have no Area | Forward-fill, then verify 188 units against 156 stations |
| Embedded newlines in headers | `Compressor\n Model`, `No. \nOf Dispensers` | Normalize headers before matching |
| Typos in headers | `Storsge S/N`, `CALBRATION DATE`, `NEXT CLIBRATION DATE`, leading space in ` Station` | Map by exact raw header string; do not "fix" the source |
| Trailing blank rows | 8 formatted-but-empty rows in file 1 | Skip rows where every cell is empty |
| Artefact columns | `Column1` (files 3a, 3b), stray `Sheet2` in four files | Excluded explicitly |
| Excel data-validation warning | openpyxl reports an unsupported validation extension | Read-only parsing; source never rewritten |

---

## 13. Open questions blocking a clean import

Ordered by how much they unblock.

> **Most of these are now answered — see [`decisions.md`](./decisions.md).** Items 1–8 map to
> decisions D1–D8. Item 9 remains open.

1. ~~**Governorate suffixes**~~ — **answered (D1):** decorative; suffix-stripping is deterministic
   under a single-match guard.
2. ~~**Numbered station names**~~ — **answered (D2):** `الخمائل` is a Station with two Units,
   `الخمائل 1` and `الخمائل 2`. `<base> <n>` denotes Unit *n*.
3. ~~**SRV parent equipment**~~ — **answered (D3):** manual/bulk mapping in the application, or a
   later source that names the parent. Default distribution is permanently forbidden.
4. ~~**`SS-4R3A`**~~ — **answered (D4):** a part number; this SRV type has no unique serial yet.
   `serial_status = 'not_yet_assigned'` until serials are issued.
5. ~~**Manufacturer aliases**~~ — **answered (D5):** `NPSAC`/`NPAC` and
   `Worthington`/`Worthing` are typo pairs; `Anderson`/`Tyco Anderson` are **different**.
6. ~~**`منتهي`/`منتهية`**~~ — **answered (D6):** kept as `source_status_raw`, never converted to
   a date or a compliance status.
6b. **456 overdue vessel certificates (41 %)** — genuinely lapsed, or recalibrated without record?
   Still open as an operational question; recompute after import (see D-effects).
7. ~~**Canal / Alex / Upper unit structure**~~ — **answered (D7):** no one-unit-per-station
   fallback. Unknown Unit stays NULL; the pattern generalizes to all Unit-scoped assets.
7b. **`16/8/3033`** — intended `2033` or `2023`? Still open.
8. ~~**Mapping ownership**~~ — **answered (D8):** Admin and Manager map anywhere; Engineer maps
   only within authorized Regions; every change audited, scope enforced in RLS.
9. **Hose coverage** — are hoses genuinely absent for five regions, or is the source partial?
   `Station data base.xlsx` reports hose *counts* for many stations with no matching records.
