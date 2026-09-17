# Canonical asset import (Prompt 23A)

Migration **0049_asset_import.sql** — SHA-256
`7fad16bb5962eaf1ed949cbec060aa9fea0f88db7d4c16d0f172d1ee037b3b1d`.
**NOT DEPLOYED. NO production asset import has been performed.**

## 1. The four target contracts — they are not the same

All four were read from the live production schema. They do **not** share a contract and
are not forced through one mapping.

| | storage_vessels | recovery_tanks | gas_detectors | hoses |
| --- | --- | --- | --- | --- |
| `station_id` | NOT NULL | NOT NULL | NOT NULL | NOT NULL |
| `region_id` | NOT NULL | NOT NULL | NOT NULL | NOT NULL |
| **`unit_id`** | **nullable** | **nullable** | **nullable** | **nullable** |
| `mapping_status` default | `needs_unit_mapping` | same | same | same |
| dates | `last_/next_inspection_*` | `last_/next_inspection_*` | `last_/next_calibration_*` | `last_/next_test_*` |
| distinctive | `compressor_type_raw` | `compressor_type_raw` | — | pressures, `description`, `dispenser_id` |
| serial UNIQUE | **none** | **none** | **none** | **none** |

**`unit_id` NULL is legal in ALL FOUR, and the schema is why.** Each family carries

```
<table>_needs_unit_ck  CHECK (mapping_status <> 'needs_unit_mapping' OR unit_id IS NULL)
```

`needs_unit_mapping` **requires** a NULL Unit. Station-level existence with an unknown Unit
is the shape these tables were designed for, not a workaround. **No family is blocked, and
nothing was relaxed** — ASSETIMP-14 asserts `station_id` is still NOT NULL in all four.

Related constraints that shape the mapping:
- `(precision = 'exact_date') = (date IS NOT NULL)` on every date pair — a date may exist
  **only** at `exact_date` precision.
- `hoses_dispenser_needs_unit_ck` — `dispenser_id` requires a Unit, so with Unit NULL the
  dispenser is necessarily NULL. Consistent, not a limitation.

## 2. Unit stays NULL — structurally, not by convention

The four INSERT statements **name no `unit_id` column at all**. A caller cannot supply one
and no code path can infer one. ASSETIMP-1 re-derives this from `pg_proc.prosrc`, and
ASSETIMP-4 proves the detector actually fires on a violating column list, so a passing
assertion means something.

This follows the Prompt 22D census: across all 281 rows there is **no Unit evidence of any
kind** — `unit_id` non-empty on 0, and no unit name, number, code or job-number key exists
anywhere. `Location` is `Recovery`/`Storage`, an equipment KIND that section 4 states is
not Unit evidence; a compressor TYPE names no instance.

## 3. Source-to-canonical field map

Shared by all families: `station_id` and `region_id` come from the **active Stage B mapping
decision** (Region via the confirmed Station, so it cannot disagree);
`mapping_status = 'needs_unit_mapping'`; `import_batch_id`, `source_file`, `source_sheet`,
`source_row` and `source_raw` carry provenance through unchanged.

| Source (`normalized`) | Canonical | Transform | Nullable | Evidence |
| --- | --- | --- | --- | --- |
| `serial_number` | `serial_number` | trim, empty -> NULL | yes | verified |
| `serial_number_raw` | `serial_number_raw` | verbatim | yes | raw preserved |
| `serial_status` | `serial_status` | enum, default `unknown` | no | verified |
| `manufacturer` | `manufacturer` + `manufacturer_raw` | trim | yes | verified (SV/RT) |
| `compressor_context_raw` | `compressor_type_raw` | verbatim | yes | **context only — never a Unit** |
| `last_calibration.raw` | `last_inspection_raw` / `last_calibration_raw` | verbatim | yes | raw preserved |
| `last_calibration.value` | `*_date` | **only if precision = `exact_date`** | yes | verified |
| `last_calibration.precision` | `*_precision` | enum | no | verified |
| `next_due_date.*` | `next_inspection_*` / `next_calibration_*` / `next_test_*` | same rule | yes | verified |
| `last_test.*` (hoses) | `last_test_*` | same rule | yes | verified |
| `working_pressure` / `test_pressure` | `*_raw`, `*_value`, `*_unit` | `min` (measured: `min = max` on every row, so no range is flattened); unit enum is exactly `BAR, PSI` | yes | verified |
| `description` (hoses) | `description` | trim | yes | verified |

**Deliberately NOT mapped:**
- `area_type_raw` — `area_type` lives on `gas_detector_presence` and classifies the AREA,
  never the detector (Prompt 13). There is no column to put it in, and inventing one to
  hold it would be the fabrication this project forbids.
- `location_raw` — equipment kind, already covered by `expected_parent_kind` semantics; it
  is not a canonical asset attribute.
- `model` / `model_raw` — **0 of 281 rows carry any model value.** The columns stay NULL
  rather than being filled from the compressor type, which is a different thing.
- `notes`, `source_status_raw` — present as keys but **empty on every row**; they stay NULL.

## 4. Identity and duplicates — nothing is invented

**None of the four tables has a UNIQUE constraint on `serial_number`**, by deliberate prior
decision (Prompt 14, data principle 16): six identical vessels at one Station may be six
real devices. ASSETIMP-11 asserts none was added here.

So **this import does not deduplicate**. One staged source row becomes exactly one canonical
asset. Measured on the real 281: 199 rows carry a serial, 82 do not, and **8 serial groups
covering 16 rows repeat within a family (6 at the same Station)**. Those 16 are **flagged as
duplicate candidates** in the preview and imported as distinct assets. Merging them would
destroy real equipment on the strength of a repeated string.

Replay is guarded **per source row** instead, using lineage that already exists —
`committed_entity_id` / `committed_at` / `committed_entity_kind`, whose CHECK allowlist
**already contained** `storage_vessel`, `recovery_tank`, `gas_detector` and `hose`
(ASSETIMP-12). No new table, no new column, no invented key.

## 5. Eligibility — measured on production, read-only

| Class | Rows | Meaning |
| --- | --- | --- |
| **B — ready, Unit NULL** | **279** | Station proven, schema permits NULL Unit |
| C — needs review | 0 | — |
| D — already imported | 0 | — |
| **E — blocked by target** | **2** | recorded detector ABSENCE |
| A | 0 | by definition empty: no row has a proven Unit |

Eligible by family: **storage vessels 100, recovery tanks 91, gas detectors 62, hoses 26**,
across 68 Stations; 16 rows carry a duplicate-serial warning; 0 rows carry a Unit.

**The 2 excluded rows are the substantive finding.** They carry
`presence = 'not_installed'` with the pipeline's own `creates_detector_record = false`: they
are evidence that an area has **no** detector. Creating a `gas_detectors` row for them would
manufacture a device the source explicitly denies. They stay staging-only and belong to
`gas_detector_presence` — a different table with a different contract, which this prompt did
not authorize building. Forcing them through the detector path is exactly what the exclusion
prevents.

## 6. Commit architecture

`cng_asset_import_proposal` (pure SELECT) -> `cng_asset_import_preview` (fingerprint +
counts) -> `cng_asset_import_commit` (one transaction). Preview, fingerprint and commit all
read **one** derivation, so what is approved and what is written cannot be two code paths —
the Stage A lesson.

**One generic function was correct here, and the four contracts are honoured inside it** as
four separate literal INSERTs with different column lists. The families differ in fields, not
in transaction semantics, so four transactions would add risk without adding safety.

Gates, all raising rather than silently proceeding: approval presented (both fingerprints,
NULL/blank refused) · run exists · run completed · manifest matches · preview matches
(re-derived in the commit's own transaction) · **no eligible rows is a refusal, not a silent
success** · every eligible row still backed by an active decision with a matching
`reviewed_source_row_hash`, a matching Station and a NULL Unit · lineage reconciles or the
whole thing aborts.

**Security follows the existing canonical-import architecture rather than inventing one:**
`service_role` ONLY, matching Stage A, because a canonical asset carries **no `created_by`**
— there is no actor to attribute, so there is no reason to open a browser path
(STAGEBSEC-14's reasoning). `SECURITY DEFINER` with pinned `search_path`; the two read paths
are deliberately **not** definer. No dynamic SQL, four literal targets. The region-scoped
INSERT policies on these tables are the **operational** path for an engineer adding one asset
by hand — they are not the import path and were not touched.

## 7. Lineage

```
import_staging_rows.id
  -> import_mapping_decisions (active, Station confirmed, Unit NULL, hash matched)
    -> canonical asset  (storage_vessels | recovery_tanks | gas_detectors | hoses)
```

The staged row records `committed_entity_id`, `committed_entity_kind` and `committed_at`.
**Stage A's lineage is untouched**: its 402 structural rows are a disjoint set and keep their
`station`/`unit` kinds. Lineage links on `source_row_key` — the stable `(file, sheet, row)`
identity — **not** on payload equality, because two rows sharing a serial and every other
value would otherwise be indistinguishable and could link to the wrong asset. `source_raw`
carries that key, so the link is exact. The commit refuses if assets created and rows linked
disagree.

## 8. Local destructive tests — all 20 pass

Full-scale local database, all 49 migrations from zero, real functions.

| # | Requirement | Result |
| --- | --- | --- |
| 1 | only Station-confirmed rows eligible | the unconfirmed row is absent from the proposal entirely |
| 2 | unconfirmed rows cannot import | stays staging-only after commit |
| 3 | Station matches active decision | 0 mismatches |
| 4 | `unit_id` stays NULL | 5/5 NULL, 0 set, status `needs_unit_mapping` |
| 5 | no Unit inference | no INSERT names `unit_id` |
| 6 | no Station/Unit creation | 2 / 3 unchanged |
| 7 | no alias creation | 0 |
| 8 | correct family target | sv 2, rt 1, gd 1, hose 1 |
| 9 | source values preserved | serial, `250 BAR`, description all intact |
| 10 | missing values stay NULL | NULL serial, NULL date, precision `unknown`, **raw text `bad` preserved** |
| 11 | wrong source hash refuses | -> `C_NEEDS_REVIEW`, excluded |
| 12 | superseded decision refuses | row leaves the proposal (5 -> 4) |
| 13 | wrong Station refuses | **structurally impossible** — `imd_station_region_fk` rejects a cross-Region Station |
| 14 | non-NULL Unit refuses | **structurally impossible** — `imd_status_shape_ck` forbids a `needs_unit_mapping` decision with a Unit; the commit's own check is defence in depth |
| 15 | wrong preview fingerprint refuses | refused (also NULL, blank, wrong manifest, unknown run) |
| 16 | replay refuses safely | fingerprint changes after commit; both the old and current values refuse; assets stay 5 |
| 17 | mid-transaction failure rolls back | in-transaction 5 created -> rollback -> assets 0, linked 0, audit 0 |
| 18 | provenance reconciles | 5 linked, 5 `committed_at`, all four kinds correct |
| 19 | canonical count = approved eligible | 5 = 5; 1 audit row |
| 20 | blocked/review rows stay staging-only | the not-installed row and the unconfirmed row both unlinked |

Two of these (13, 14) were **stronger than the test intended**: the states could not even be
constructed, because pre-existing constraints forbid them.

## 9. Production data quality (read-only)

| | total | serial | no serial | manufacturer | model | dates | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| storage vessels | 100 | 100 | 0 | 100 | **0** | 100 last + 100 next | all `assigned` |
| recovery tanks | 91 | 74 | 17 | 90 | **0** | 91 + 91 | mixed `assigned`/`unknown` |
| gas detectors | 64 | **0** | 64 | 0 | **0** | 62 + 62 | 2 are absence evidence |
| hoses | 26 | 25 | 1 | 0 | **0** | 26 last test + 26 next | 26 working + 26 test pressure |

Date precisions present are **only `exact_date` and `unknown`** — no `year_only` or
`invalid` — so the precision CHECK is satisfied by construction. Pressures are never ranges
(`min = max` everywhere) and units are exactly the `BAR, PSI` enum.

Missing optional data is **not** treated as blocking: a detector with no serial is a complete
record with an unknown attribute (principle 19), and `serial_status` records which kind of
unknown it is.

## 10. Status

**NOT DEPLOYED, NOT IMPORTED.** Production remains 48 migrations, 157 Stations, 188 Units,
281 decisions, **0 canonical assets**, 0 aliases, 0 asset lineage rows, and **0 asset-import
functions deployed**.

**No production preview fingerprint is claimed.** The 22B rule is that the fingerprint must
come from the **deployed** function, not from an inlined reproduction; 0049 is not deployed,
so the counts above are reproduced read-only and the fingerprint is deliberately left for
deployment. Nothing is presented as more verified than it is.

## 11. Prompt 23B — 0049 deployed, production preview verified (read-only)

Production went **48 -> 49**, recorded once (`20260917120310 asset_import`), from the file
approved at commit `55e7e18`, SHA-256 `7fad16bb...` recomputed immediately before transmission.

**DEPLOYMENT IS BYTE-EXACT, NOT MERELY APPLIED.** All three function bodies were hashed FROM
THE APPROVED FILE BEFORE deploying and compared to `pg_proc.prosrc` afterwards:

| Function | Expected `prosrc` MD5 | Deployed | Length |
| --- | --- | --- | --- |
| `cng_asset_import_proposal` | `7a6394c2a7eb0ddcb7ac9235f259cf64` | identical | 5772 |
| `cng_asset_import_preview` | `9da86e438005c79a215ca071b47e8150` | identical | 1829 |
| `cng_asset_import_commit` | `e759bebb4c585dd026cf3bd2b24413ad` | identical | 11594 |

**THE MIGRATION EXECUTES NO DML.** Machine-scanned with function bodies stripped out: at
migration time it runs 3 `CREATE OR REPLACE FUNCTION`, 3 `COMMENT`, 3 `GRANT` and 6 `REVOKE`,
and **zero** INSERT/UPDATE/DELETE/ALTER/DROP/POLICY/INDEX. All six DML statements in the file sit
**inside function bodies** (4 asset INSERTs, 1 audit INSERT, 1 staging UPDATE), and the file
contains **no write of any kind** to `stations`, `units`, `station_aliases`, `unit_aliases`,
`import_mapping_decisions` or `gas_detector_presence`.

**SECURITY AS APPROVED**: commit `prosecdef = true`, both read paths `false` and STABLE (so they
cannot write); `search_path` pinned on all three; EXECUTE **anon 0, authenticated 0,
service_role 3** — no browser canonical-import path exists. No dynamic SQL. **Nothing else
moved**: `cng_normalize_name` `3c4d8a93...`, `cng_stage_a_commit` `4aef8bea...`,
`cng_stage_b_station_commit` `b040117a...`, candidates `ddf963f6...`, preview `5780e33f...`,
`cng_require_admin` `ff29bdea...` all unchanged; Stage A EXECUTE service_role 3 / browser 0;
70 policies and 0 tables without RLS, exactly as before. The four operational asset INSERT
policies are intact and still `WITH CHECK (cng_can_write_region(region_id))` — untouched.

### The deployed preview fingerprint

```
b0d594482b40c21099ba39cb3b9a827cb5dee46cd557fcb676055054bd91104b
```

obtained from the **deployed** function, not an inlined reproduction — the 22B rule. Manifest
`764d3c0f...` as expected.

| | value |
| --- | --- |
| eligible canonical assets | **279** |
| storage vessels / recovery tanks / gas detectors / hoses | **100 / 91 / 62 / 26** |
| excluded | **2** (all `E_BLOCKED_BY_TARGET`) |
| needs review / already imported | 0 / 0 |
| duplicate-serial rows flagged | 16 |
| distinct Stations | 68 |
| rows with a Unit | **0** |
| canonical assets now | 0 |

**Every 23A expectation reconciles exactly.**

### Verified against the deployed proposal

- **Unit appears nowhere**: 0 eligible payloads carry any of `unit_id`, `unit`, `unit_name`,
  `unit_no`, `unit_number`, `unit_code`.
- **Station comes from the active Stage B decision**: 279/279 match on Station AND
  `confirmed_unit_id IS NULL` AND `reviewed_source_row_hash = source_row_hash`;
  0 eligible rows without a decision; 0 Region mismatches against the Station's own Region.
- **0 candidates from the remaining 823**, and **0 from the two not-installed rows**.
- **Identity**: 199 serial-present / 82 no-serial over all 281 (reconciling 23A exactly), 16
  duplicate-serial warnings retained, and **279 eligible rows carry 279 distinct
  `source_row_key`s and 279 distinct hashes** — one canonical asset per source row, nothing
  deduplicated.

### The two detector exclusions, by provenance

Both from `Gas detector.xlsx / Sheet1`, rows **75** and **109**, hashes `78a9207b77e6…` and
`ea8e6c272b78…`. Each carries `presence = not_installed` with `creates_detector_record = false`
and `area_type_raw = Open Area`. No identity text was retyped: the raw Station name is confirmed
**retained** (lengths 6 and 15) and `source_raw` is intact, so nothing was discarded from
provenance. Both remain `staged_mapping_status = needs_station_mapping`, staging-only, with no
canonical row proposed. **No `gas_detector_presence` write occurred** — that table still holds 0
rows and is not touched by this migration at all.

### Field and NULL preservation — 17 checks, 0 violations

no fabricated serial · **0 model keys anywhere** (no model value exists in the source, and none
was filled from the compressor type) · compressor context copied verbatim · **`location` and
`area_type` appear nowhere in any payload** · a date value exists **only** where precision is
`exact_date` (next, last-calibration and last-test rules each 0 violations) · raw date text
retained including on non-exact rows · pressure units and values faithful with **0 ranges
flattened** · no fabricated notes or status · serial_status faithful.

### Lineage and write-free proof

Guards present on all 279 (`source_row_key`, 64-char `source_row_hash`, payload key matching the
row key). Stage A's **402** `station`/`unit` lineage rows are untouched and **0 rows overlap**
with the asset proposal. Asset lineage rows: **0** — no lineage write has occurred.

Counters either side of the preview are **identical**: `storage_vessels`/`recovery_tanks`/
`gas_detectors`/`hoses` live counts 0, `audit_logs` 282 with **0** `service_role:asset_import`
rows, decisions 281, Unit mappings 0, aliases 0, `gas_detector_presence` 0. (The non-zero
all-time `n_tup_ins` on `storage_vessels` (2), `hoses` (1) and `gas_detector_presence` (1) are
historical ROLLED-BACK probe tuples from Prompts 12-14; live counts are 0 and the delta across
this preview is zero on every table.)

**Gate exit 0**: frontend 617, schema 261, authorization 624, 49 migrations from zero, upgrade
replay 48 -> 49. 0044-0048 byte-identical.

**NO CANONICAL ASSET WAS IMPORTED.** `cng_asset_import_commit` was not invoked in any execution
context. Production: 49 migrations, 6 / 157 / 188, 281 decisions, 0 Unit mappings, canonical
assets 0, aliases 0, asset lineage 0, 0 tables without RLS.

## 12. Prompt 23C — the 279 canonical assets are committed to production

`cng_asset_import_commit` was invoked **exactly once**, after a final pre-commit guard matched
every approved value. **This is the first time this system has held canonical assets.**

**PRE-COMMIT GUARD, ALL EXACT**: 49 migrations, 6 / 157 / 188, 281 decisions, all four asset
tables 0, asset lineage 0, aliases 0/0. The deployed preview returned fingerprint
`b0d59448...bd91104b` and manifest `764d3c0f...`, both matching the approved values; 279 eligible
(100 / 91 / 62 / 26), 2 blocked, 0 needs-review, 0 already imported, 0 rows with a Unit;
**279/279 fully qualified** (active decision, Station match, `confirmed_unit_id IS NULL`, hash
match, Region agreeing with the Station's own); 0 candidates from the 823. The commit body still
hashed `e759bebb...`, SECURITY DEFINER, `search_path` pinned, EXECUTE **authenticated 0 / anon 0 /
service_role 3**, no dynamic SQL; normalizer, Stage A and all four Stage B functions unchanged.

**COMMIT RETURN** — `assets_created 279`, `storage_vessels 100`, `recovery_tanks 91`,
`gas_detectors 62`, `hoses 26`, `rows_linked 279`, fingerprint `b0d59448...`. Unambiguous
success; no retry was needed and none was made.

**RECONCILIATION — every check zero-defect:**

| Check | Result |
| --- | --- |
| Families | 100 / 91 / 62 / 26 = **279** |
| Other families untouched | compressors, dispensers, installed SRV, warehouse SRV all **0** |
| `station_id` NULL | 0 |
| **`unit_id` NOT NULL** | **0** |
| `mapping_status` <> needs_unit_mapping | 0 |
| Wrong Station vs active decision | 0 |
| Wrong Region vs the Station's own | 0 |
| Asset without lineage | 0 |
| Distinct source keys across 279 assets | **279** |
| One source row used twice | 0 |

**LINEAGE**: 279 links, **one** `committed_at` across all of them (one transaction), 0 orphans,
0 wrong entity kinds, 0 wrong asset pointers, 0 hash-evidence mismatches, 0 links without a
decision. **Stage A's 402 structural rows are untouched** and keep their own single timestamp.

**THE TWO DETECTOR EXCLUSIONS HELD**: **0** rows with `creates_detector_record = false` were
imported anywhere in staging, their evidence is intact (presence, raw Station name and
`source_raw` all retained), and `gas_detector_presence` still holds **0** rows — nothing was
written there.

**DATA PRESERVATION — 17 checks, 0 violations**: no fabricated serial; **0 model values anywhere**
and none derived from compressor type; compressor context copied verbatim; no fabricated notes or
status; serial_status faithful; a date exists **only** where precision is `exact_date` (next, last
inspection/calibration and last test each 0 violations) and every stored date equals its source
value; raw date text retained; pressure unit and value unchanged with no range flattened; and
**no `location`, `area_type` or unit key appears in any stored asset**.

**DUPLICATE SERIALS WERE NOT DEDUPLICATED**: 199 assets carry a serial and 80 do not (82 staged
no-serial rows minus the 2 excluded detectors — exact). The **8 repeated-serial groups covering 16
rows produced 16 DISTINCT assets**, as data principle 16 requires.

**AUDIT**: exactly **1** row — `import_executed` on `import_runs`
`cdad1e5e-...`, `actor_label = service_role:asset_import`, **`actor_id` NULL**, carrying
`assets_created 279` and the approved fingerprint, 0 orphans, and an `occurred_at` equal to the
lineage `committed_at`. The NULL human actor is correct and deliberate: these tables carry no
`created_by` contract, so no human attribution was invented.

**REPLAY IS BLOCKED BY THREE INDEPENDENT SERVER-SIDE BARRIERS**, proved read-only without
re-invoking the commit:
1. **The fingerprint moved** — `b0d59448...` -> `e3b0c442...` (the SHA-256 of the empty string,
   because no eligible row remains). Presenting the approved constant now fails the Gate 3/4
   comparison.
2. **Gate 5** — `eligible_rows = 0`, so the commit raises *"has no eligible rows"* rather than
   silently succeeding.
3. **Lineage** — all 279 rows are classified `D_ALREADY_IMPORTED`; `committed_entity_id` is set on
   every one and `staging_commit_shape_ck` keeps id and timestamp in step.

**FIREWALLS**: the remaining **823** Station-unconfirmed rows are untouched with **0** imported;
decisions still 281 with **0 Unit mappings**; aliases 0; hierarchy unchanged at 6 / 157 / 188 —
East 42/56, West 40/58, Delta 75/74, Canal/Alex/Upper 0/0; 0 tables without RLS.

**Gate exit 0**: frontend 617, schema 261, authorization 624, 49 migrations from zero, upgrade
replay 48 -> 49. Migrations 0044-0049 byte-identical.

## 13. Prompt 24A — live data verification against the 279 canonical assets

**SCOPE LIMIT STATED FIRST.** This environment answers **403 at CONNECT** for
`cng-station-management.pages.dev` (re-tested, not assumed). **I could not open the
application in a browser**, so nothing here is BROWSER VERIFIED. What is verified is the
DATABASE and the **view/query layer the UI actually reads**, plus the CSV encoder run against
real production rows. Rendering and interaction still need owner browser acceptance.

### Database truth (Phase 1)

279 assets: storage vessels 100, recovery tanks 91, gas detectors 62, hoses 26. **All 279**
carry `station_id NOT NULL`, `unit_id NULL` and `mapping_status = needs_unit_mapping` — 0
exceptions in every family. Distribution: **Delta 199** (SV 67, RT 72, GD 60) and **West 80**
(SV 33, RT 19, GD 2, hoses 26), across 68 Stations. Both excluded detector rows were West,
which is why West is 80 rather than 82.

### The views the UI reads reconcile exactly

| View | Rows | Expected |
| --- | --- | --- |
| `v_vessel_management` | **191** (100 storage + 91 recovery) | 191 |
| `v_gas_detector_management` | **62**, of which absence rows **0** | 62 |
| `v_report_gas_detectors` | **62** | 62 |
| `v_hose_registry` / `v_hose_management` | **26** / **26** | 26 |
| `v_report_due_compliance` | **279** | 279 |
| `v_installed_srv_management` | **0** | 0 (no SRV imported) |

**Zero view drift**: every row in all four families was compared field-by-field against its
canonical table (serial, manufacturer, model, station, unit, next-due date, pressure) — **0
differences** in each.

**THE DETECTOR EXCLUSION IS VISIBLE AND CORRECT END TO END**: the detector registry shows 62
with **0** absence rows, and Data Quality shows `staged_decision_recorded` of **64** detectors
against **62** canonical — the difference being exactly the two `not_installed` rows, decided at
staging and correctly never canonical. `gas_detector_presence` remains 0 rows.

### Due semantics (Phase 5) — exact, with zero drift

`days_left` and `due_status` were compared against a fresh evaluation of `cng_days_left()` /
`cng_due_status()` on every row: **0 drift on both**. **51 rows carry `unknown` precision and
every one has `days_left` NULL and `due_status = unknown`** — 0 non-exact rows carry a
days-remaining figure and 0 are classified. Only `exact_date` drives classification, exactly as
principle 17 requires.

**A REAL OPERATIONAL FINDING: 142 of 279 assets are OVERDUE** — storage vessels 60, recovery
tanks 56, gas detectors 26 — the worst by **764 days**. 51 are `unknown`, 86 valid/due_60.
This is the first real compliance picture the system has produced and is business content, not
a defect.

### CSV export (Phase 6) — verified against REAL production rows

Production contains **0** naturally occurring formula-lead values, so that case was exercised
with the local fixtures, as anticipated. But production **does** contain 33 values with a comma
or quote and **179 Arabic values (157 Arabic Station names)**, so the export was run through the
real `csv.ts` encoder on actual production rows:

- UTF-8 BOM present (`ef bb bf`) and CRLF line endings.
- **Arabic Station names round-trip byte-intact.**
- `NK CO.,LTD.` — a real manufacturer value — correctly quoted as `"NK CO.,LTD."`.
- NULL Unit and NULL model emit a genuinely **empty** field: no `N/A`, `-`, `0` or `undefined`.
- `-624` days left is emitted **bare as a number**, so the column still sorts numerically.
- Formula guard on fixtures: `=cmd|calc`, `+1+1`, `-5`, `@SUM(A1)` and a leading tab each gain
  the apostrophe prefix and quoting; a genuine numeric `-5` in a numeric column stays `-5`; a
  non-numeric value in a numeric column falls back to the text guard.

### Paging (Phase 7) — verified on the real 279 rows

The UI orders by the spec column then **always** appends the id column. Simulating that exactly
over `v_report_due_compliance` at PAGE_SIZE 50: **279 rows, 279 distinct ids across all pages,
0 duplicated, 6 pages (50×5 + 29)**. The 51 NULL-due rows sort deterministically last
(positions 229-279), so no row can appear on two pages or vanish between them.

### Report contract re-verified against PRODUCTION (the 20B defect class)

Every column all eight report specs select, order, filter or identify by was checked against
`information_schema` **in production**: **0 missing columns**. The 20B failure mode is absent.

### NULL Unit UX (Phase 8)

Correct by design in the code: `NullValue` renders an em dash with an `sr-only`
"not recorded" (never `N/A`, `Unknown`, `-`, `0` or `undefined`), and `needs_unit_mapping`
renders as "Needs unit mapping" with kind `unmapped` — explicitly **not** an error state. No
Unit is fabricated and no one-Unit Station is assumed. Visual confirmation still needs a browser.

### Data Quality (Phase 9) — rules that actually fire

Canonical layer: **279 rows, all `needs_unit_mapping`** (100/91/62/26) and nothing else — no
rule was invented merely because a field is NULL. Staged layer: 281 `staged_decision_recorded`
(100/91/64/26) and 1,037 `staged_awaiting_decision`. Import-issue layer, from the existing enum:
`unmatched_station` 2,435 · `year_only_date` 372 · `missing_serial` 339 ·
`not_found_in_assets_database` 142 · `placeholder_value` 48 · `invalid_date` 37 ·
`ambiguous_station_identity` 20 · `missing_job_number` 6 ·
`suspected_part_number_in_serial_column` 3.

### Observations (E-class, no fix applied)

1. **Three columns are entirely empty across the whole dataset** and will render as a full
   column of em dashes: `model` (191/191 vessels — no model value exists in any source),
   detector `serial_number` (62/62), and detector `area_type` (62/62, because it lives on
   `gas_detector_presence` and no presence row exists). All three are *correct* — the data
   genuinely is not there — but an all-empty column is worth a product decision.
2. **16 duplicate-serial storage vessels (8 serials, 12 at the same Station) are not flagged in
   the UI.** `serial_duplicate` exists only on `v_hose_registry`, by the Prompt 14 design where
   a hose is individually traceable. Principle 16 says report duplicate candidates; for vessels
   they currently are not surfaced anywhere in the product.
3. **All 26 hoses sit at a single Station in West**, and 60 of 62 detectors are one-per-Station
   in Delta — a distribution worth an operator sanity check against the real estate.

### Firewall and gate

Production unchanged: 49 migrations, 6 / 157 / 188, 281 decisions, 100 / 91 / 62 / 26,
aliases 0, Unit mappings 0, `gas_detector_presence` 0, asset lineage 279. No row was created,
updated or deleted by this review. Gate exit 0 — frontend 617, schema 261, authorization 624.
