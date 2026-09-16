# Hoses Management (Prompt 14)

Company-wide registry for CNG station hoses.

**Route:** `/manage/hoses` — the existing sidebar entry, preserved, inside the existing
`AppShell`. No parallel layout was introduced.

**One new migration:** `0030_hose_registry_view.sql`, additive, `security_invoker`. See §7.

---

## 1. What makes this registry different

Every other asset registry in this product is organised around *compliance*. A hose is an
**individually traceable item**, so this one is organised around **identity** first and
compliance second. Serial leads the table, and serial *quality* — missing, duplicated — is a
first-class operational signal rather than a footnote.

## 2. The actual schema

`hoses` carries:

| Column | Notes |
| --- | --- |
| `station_id` | **NOT NULL** — see §4 |
| `region_id` | NOT NULL; pinned to the station's region by `hoses_station_region_fk` |
| `unit_id` | **nullable** — see §5 |
| `dispenser_id` | nullable — see §6 |
| `mapping_status` | `asset_mapping_status` |
| `description` | free text |
| `serial_number`, `serial_number_raw`, `serial_status` | TEXT |
| `working_pressure_raw` / `_value` / `_unit` | `pressure_unit` is `BAR` or `PSI` |
| `test_pressure_raw` / `_value` / `_unit` | |
| `last_test_raw` / `_date` / `_precision` | |
| `next_test_raw` / `_date` / `_precision` | |
| `source_status_raw` | e.g. `منتهي`, preserved beside a missing date |
| provenance, `needs_review`, `resolved_by`, `archived_at` | |

**Deliberately not invented**, because no column exists for them: `manufacturer`, `model`,
length, diameter, hose type, material, installation date and certificate reference. Manufacturer
and model are **not parsed out of `description`** — free text stays free text (`HS18`).

## 3. Terminology — the prompt's wording and the schema's differ

There is **no `hydrostatic_test_date` column**, and no column anywhere in the schema whose name
contains "hydro" (`HS19`). The columns are `last_test_date` and `next_test_date`, so the headers
read **"Last test"** and **"Next test"**.

Three vocabularies exist in this project and they are not merged:

| Where | Wording |
| --- | --- |
| `hoses` columns | `last_test_date`, `next_test_date` — a **test** |
| `alert_subject` enum | `hose_hydrotest` — a **hydrotest** |
| `HOSES.xlsx` source columns | `CALBRATION DATE`, `NEXT CLIBRATION DATE` (misspelled in the source) |

The UI follows the **schema columns**, matching the Prompt-10 Unit tab. It is *not* relabelled
"Calibration": testing a hose and calibrating an instrument are different activities, and the
project's own alert vocabulary calls this a hydrotest, not a calibration. Equally, nothing in the
UI claims the source said "hydrostatic", because no source or schema field does.

## 4. Canonical compatibility of `needs_station_mapping` — a THIRD Prompt-21 blocker

**The mandatory §5 check. The answer is NO.**

`hoses.station_id` is **NOT NULL**. Proved by attempting the insert inside a rolled-back
transaction, which the not-null constraint rejected (`HS1` runs that insert and requires
rejection, rather than reading the catalogue and inferring).

A second test was run, because the first alone does not settle it: a row *can* be stored with
`mapping_status = 'needs_station_mapping'` **if a Station is named**. That is not a way round the
blocker — it would mean recording a Station the evidence does not prove, which is fabricating a
mapping and is forbidden. So the state remains unreachable for any record that genuinely has no
confirmed Station.

Prompt 6 staged **49 hose rows** in that state (of 71: 22 resolved, 49 `needs_station_mapping` —
**dry-run staging figures, never displayed as production metrics**).

Nothing was relaxed, fabricated or dropped, and the unreachable state is **not offered** in the
Mapping filter, because offering a state the database cannot store would be a lie in the UI.

### Updated Prompt-21 blocker list

| Asset | Rows | Why |
| --- | --- | --- |
| Storage Vessels | 433 | `storage_vessels.station_id` NOT NULL |
| Recovery Tanks | 403 | `recovery_tanks.station_id` NOT NULL |
| Gas Detectors | 219 | `gas_detectors.station_id` NOT NULL |
| **Hoses** | **49** | **`hoses.station_id` NOT NULL** |
| **Total** | **1,104** | |

## 5. The Unit-mapping model — Unit is PENDING, not optional

The mandatory §6 check. The SRV and detector lifecycles were **not** assumed onto hoses; the
model was read from the constraints and tested.

- `unit_id` **is nullable**, and a hose may legitimately be stored against a Station with its
  Unit unresolved. That insert was run and **accepted** (`HS2`). It is the normal pending state,
  not an error, and such a hose is a complete record with an unknown attribute (principle #19).
- But `resolved` **requires** a Unit: `hoses_resolved_ck` rejects `mapping_status = 'resolved'`
  with `unit_id IS NULL` (`HS3`). So "resolved" for a hose means **Station and Unit both
  confirmed** — Unit mapping is pending, never permanently optional.
- `hoses_needs_unit_ck` rejects `needs_unit_mapping` *with* a unit (`HS4`), so the state cannot
  lie in either direction.
- There is **no `needs_equipment_mapping`** for hoses. A hose's optional parent is a Dispenser,
  reached through the Unit — not the SRV equipment lifecycle.

## 6. Physical hierarchy — one level deeper than the prompt assumed

`hoses.dispenser_id` exists, so the chain is:

```
Region → Station → Unit → Dispenser → Hose
```

The Dispenser level is **optional and constrained**: `hoses_dispenser_needs_unit_ck` rejects a
dispenser while the Unit is unknown (`HS5`), and `hoses_dispenser_unit_fk` forces the dispenser to
belong to that same Unit. Where the source does not say which dispenser a hose serves,
`dispenser_id` stays NULL.

**A Unit is never inferred** — not from the Station, the description, the source row order, an
adjacent hose, another asset, a serial pattern, or source grouping. A description such as
`خرطوم غاز C` hints at a bay letter, but reading that as a dispenser identity is not
deterministic and would fabricate a physical relationship; a test asserts no dispenser is
conjured from it.

The Prompt-10 **Unit Hoses tab is unchanged** and remains Unit-scoped. `HOSE-19` asserts a
resolved hose always carries a confirmed Unit, so the tab cannot surface an unresolved one, and
`HOSE-23` asserts `v_hose_management` still exists for it.

## 7. The new view, and why one was genuinely needed

`0030_hose_registry_view.sql` adds `v_hose_registry`: everything `v_hose_management` carries,
plus `serial_missing`, `serial_duplicate` and provenance columns. `v_hose_management` is
**unchanged** and still serves the Unit tab.

Detecting a duplicated serial needs a **window function over the whole visible set**. A paged
client sees 50 rows and cannot know that row 12 on page 1 shares a serial with row 3 on page 2,
and computing it client-side would require fetching every hose — exactly what §31 forbids.

### `serial_duplicate` is RLS-scoped, and that is the point

The view is `security_invoker`, so the window function runs over **the rows the caller may see**.
A duplicate is reported only when *both* copies are inside the caller's authorized regions.

This is deliberate and it is the **non-leaking** behaviour. The RLS suite proves it with a
deliberately planted cross-region collision — one hose in East and one in West sharing
`TESTDATA-CROSS-DUP`:

- `HOSE-9` — the East viewer is **not** told their hose is a duplicate. Telling them would
  disclose that a West record they may not read exists.
- `HOSE-18` — an admin, who may read both regions, **is** shown the collision.

A narrower, honest signal is correct here; a complete one would be a leak.

### NULL serials are never duplicates of one another

Several hoses with no recorded serial are several unknowns, not one repeated value
(principle #16). `HS11` asserts it. `serial_missing` and `serial_duplicate` are separate
conditions and are never both true for the same row (`HS12`).

## 8. Serial identity

| Condition | Behaviour |
| --- | --- |
| recorded | shown verbatim; TEXT, so leading zeros survive (`HS6`) |
| missing | stays NULL; reads "not recorded". **No serial is generated** from a row number, a station, a unit or anything else, however much operational policy wants one (`HS7`) |
| `not_yet_assigned` | worded differently — the source *states* none has been issued, which is a fact, not a gap (principle #20) |
| duplicated | **reported** beside the identifier, never merged, never silently suffixed, never "repaired" (`HS9`, `HS10`) |

**No `UNIQUE` constraint was added on `serial_number`**, and none already existed (`HS8`,
`HOSE-24`). Uniqueness is operationally desirable, but the source does not prove it and a
constraint would reject valid historical rows at the Prompt-21 import. The condition is
**reported, never enforced**.

Serial quality is its own filter axis — `Any serial state / Serial recorded / No serial
recorded / Duplicate serial` — deliberately separate from Mapping and from Due, because a missing
serial is **not** an unresolved mapping and **not** an overdue test.

## 9. Test dates, precision, due status and the interval gap

**No authoritative test interval exists anywhere in this project.** `alert_rules` carries
`subject`, `threshold` and `days_before` only — no interval, frequency, period or months column
exists in any table (`HS20`). No configuration or seed row states one. (There are also no seeded
`hose_hydrotest` alert rules yet; alerts are Prompt 15's.)

Therefore **no interval is hard-coded in React.** The UI shows the stored `next_test_date` and
the due status SQL derives from it, and computes nothing of its own. A unit test feeds a
`days_left` and a `due_status` that deliberately disagree and asserts the UI renders both
unchanged, proving there is no competing frontend calculation.

**Date precision** follows the project rule. Only `exact_date` drives a countdown. A `year_only`
date shows its year, is labelled "year only", and is **never** converted to 1 January or
31 December; `days_left` is NULL and `due_status` is `unknown`, which reads "No exact date" and
never "Within date" (`HS13`, `HS15`). Excel `Days Left` is not used.

**Due status** comes from `cng_due_status()` via the view, using the project's existing buckets.

## 10. Pressures

Working and test pressure each carry the unit the source proved — `BAR` or `PSI`. **Nothing is
converted and nothing is inferred from magnitude.** Where no unit was proven the raw value is
shown alone rather than dressed in a guess. A test asserts a 3600 PSI hose never renders the
~248 BAR equivalent anywhere.

## 11. The registry

**Columns, in priority order:** Serial · Station · Unit · Next test · Days left · Status ·
Last test · Mapping · Description · Working pressure.

Identity leads because that is what a hose *is*; the test-attention triple follows. Description
is genuinely useful but descriptive rather than identifying, so it sits after Status rather than
consuming prime scan width. Measured at 1440px: every column through Description is visible
without scrolling; only Working pressure scrolls. A test locks the first six headers.

The Description column is visually truncated with the full text available in the expanded detail;
CSS truncation keeps the complete string in the accessibility tree, so screen readers still read
it in full.

**NULL** shows as a quiet em dash reading "not recorded" — never `N/A`, `0` or a placeholder, and
always distinct from `Due Status = Unknown` and from an unresolved mapping.

## 12. Search, filters, sorting, pagination

All server-side; nothing is fetched company-wide and filtered in React.

- **Search** — `serial_number`, `description`, `station_name` on the raw term and `unit_name` on
  the folded form, using the same Arabic folding as the SQL. Search is retrieval: a hit resolves
  no mapping and never merges two serials.
- **Filters** — Region, Station (dependent, offered only once a Region bounds the list), Serial
  quality, Mapping Status, Due Status. They combine as a true intersection; East + Overdue +
  No serial is verified in the browser.
- **Sorting** — 6 sortable columns with `aria-sort`, both directions verified, `nullsFirst:
  false` throughout so unknowns sort last intentionally, and `id` appended as a deterministic
  tie-break so paging is stable.
- **Pagination** — server-side, 50 per page, `count: 'exact'` under RLS.

Four distinct screens: loading, empty, filtered-no-results, query failure. A failure is never
rendered as an empty registry and a failed count is never rendered as zero.

## 13. Attention summary

Seven `head: true` counts over the **whole authorized dataset** — not the page, not the current
filters: hoses, overdue, due ≤60d (incl. overdue), needs unit mapping, no exact date, no serial,
duplicate serial. Each runs under the caller's own RLS. Any single failure fails the whole strip
and says so.

## 14. RLS, information leakage and performance

The view is `security_invoker` (`HOSE-20`) over `hoses`, whose SELECT policy is
`cng_can_read_region(region_id)`; `region_id` is NOT NULL and pinned by composite FK, so it is a
trustworthy authorization key. `anon` holds no grant (`HOSE-21`) and no application role may write
through the view (`HOSE-22`).

25 assertions prove an out-of-region hose is unreachable through list, direct lookup, the base
table, search by serial / description / station name, filtered counts, the missing-serial filter,
the duplicate flag, and detail expansion including provenance.

As on gas detectors, `authenticated` **holds** the UPDATE grant on `hoses`, so an unauthorized
UPDATE raises no privilege error — the row fails the policy's `USING` clause and the statement
matches nothing. **Zero rows changed is the security property**, so that is what `HOSE-12` and
`HOSE-13` assert, and `HOSE-14` confirms the target row is genuinely untouched rather than merely
invisible.

**Performance:** one set-based query per page plus seven head-only counts. No N+1 station lookup,
no N+1 unit lookup, no per-row due calculation, no per-row count query, no client-side
authorization filtering. The station dropdown is bounded by requiring a Region first. Existing
indexes cover `unit_id`, `station_id`, `region_id`, `serial_number`, `next_test_date` and
`mapping_status`.

## 15. Deliberate deferrals

| Item | Why | Owner |
| --- | --- | --- |
| Mapping mutation | `hoses` has no audit trigger and its mapping columns are client-writable, so attribution is forgeable and unrecorded (`HOSE-25`); CLAUDE.md §9 requires who and when | a later prompt, once the generic audited mechanism exists |
| Technical field editing | same attribution gap, and editing raw source fields would destroy evidence | as above |
| Alert generation and inbox | out of scope by instruction | Prompt 15 |
| `needs_station_mapping` for hoses | canonically unstorable (§4) | Prompt 21 |
| An authoritative test interval | not represented anywhere (§9) | needs a schema/config decision |

There is no delete control of any kind; the project forbids hard deletes.

### One recorded observation, not changed here

At 390px the attention strip occupies ~594px before the table begins, leaving about four rows in
the first screen. This matches the pattern already accepted for SRVs, Vessels and Gas Detectors
(detectors: 600px), so it is **not a regression introduced here**, and collapsing it would restyle
four accepted screens. Worth considering as a cross-registry change in a later prompt.
