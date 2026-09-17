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
