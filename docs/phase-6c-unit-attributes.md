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
