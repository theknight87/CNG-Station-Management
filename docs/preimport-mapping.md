# Pre-import mapping decisions (Prompt 19A)

Migrations **0039** and **0040**. Routes: `/admin/data-quality`, `/admin/alert-settings`,
`/admin/audit-log`.

---

## 1. Five kinds of statement, kept apart

The single most important thing in this document. Conflating any two of these is how a guess
becomes a fact.

| # | Kind | Where it lives | Scope | Who creates it |
| --- | --- | --- | --- | --- |
| 1 | **Raw import evidence** | `import_staging_rows.source_raw`, plus file/sheet/row | one source cell | the workbook |
| 2 | **Automated candidate** | `import_staging_rows.resolution.proposals` | a suggestion about one row | the pipeline's similarity matcher |
| 3 | **Owner-confirmed global rule** | `owner_confirmed_station_aliases`, `station_aliases` | **every** row carrying that exact value | the system owner, explicitly |
| 4 | **Human row-level mapping decision** | `import_mapping_decisions` | **exactly one source row** | an administrator, in the application |
| 5 | **Canonical imported record** | the asset table | the stored asset | Prompt 21's commit |

**A row-level decision never becomes a rule.** Confirming that `V.xlsx#Sheet1#11` belongs to
Station X says nothing about row 12, even if row 12 carries byte-identical text. There is no code
path — SQL or TypeScript — that promotes a decision into an alias, and two tests assert it:
`PREMAP-23`/`PREMAP-24` in SQL, and "does not resolve a second row carrying the identical raw
station text" in `mappingDecisions.test.ts`.

**A candidate is never applied.** The proposal is displayed as *"Suggested: …"* with its score, in
a dashed neutral treatment, in a different column from the confirmed mapping, with a
screen-reader note saying it confirms nothing.

## 2. The problem, stated exactly

The Prompt 6 dry run staged **1,104 rows** in `needs_station_mapping`: 433 Storage Vessels, 403
Recovery Tanks, 219 Gas Detectors, 49 Hoses. All four canonical tables declare
`station_id NOT NULL`, so none of those rows can be committed as staged.

**What was NOT done:** `station_id` was not made nullable on any canonical table, no constraint
was relaxed, and no staged row was dropped. `PREMAP-33` asserts all four columns are still
`NOT NULL` after these migrations.

**What was done:** the resolution moved *earlier*, to before the import, where the evidence still
lives. An admin confirms the Station on the staging row; Prompt 21 commits rows whose Station is
proven by that decision and leaves the rest staged.

## 3. The storage model

`import_mapping_decisions`, one row per decision:

| Column | Purpose |
| --- | --- |
| `staging_row_id` → `import_staging_rows` | which row this is about |
| `source_row_key` | the stable `(file, sheet, row)` identity — carried so a decision **survives a later dry run** that re-stages the same cells as new rows |
| `target_table`, `asset_type` | which of the four pre-import types |
| `region_id`, `confirmed_station_id`, `confirmed_unit_id` | the confirmed hierarchy; Region is **derived from the Station**, never taken from the caller |
| `previous_mapping_status`, `resulting_mapping_status` | where it came from and where it went |
| `decided_by`, `decided_at`, `reason` | who and when; the actor is server-derived |
| `superseded_at`, `superseded_by` | a correction **supersedes**, it never overwrites |
| `source_evidence` | a **copy** of what the human saw, taken at decision time |

Guarantees that are structural rather than conventional:

* `imd_one_active_per_source_row` — a **partial unique index** on `source_row_key WHERE
  superseded_at IS NULL`. Exactly one active decision per source row, enforced by the database.
* `imd_unit_station_fk (confirmed_unit_id, confirmed_station_id) → units(id, station_id)` — a Unit
  from another Station is not expressible. The same composite-FK technique the SRV table has used
  since Prompt 4; no trigger, no application check.
* `imd_status_shape_ck` — `resolved` requires a Unit, `needs_unit_mapping` requires its absence.
  The resulting status is **derived in SQL**, so a caller cannot assert one.
* **No INSERT, UPDATE or DELETE policy and no such grant.** The SECURITY DEFINER function is the
  only writer: a decision cannot be forged, edited in place or deleted through the API by anyone,
  administrators included (`PREMAP-27`…`PREMAP-29`).
* Raw staging is untouched: `PREMAP-21` asserts `source_raw` and the staged `mapping_status` are
  byte-identical after a decision, and `PREMAP-30` asserts an admin cannot resolve a row by
  editing staging directly.

### The function

```
cng_admin_decide_staged_mapping(
  p_staging_row_id, p_station_id, p_unit_id, p_expected_decision_at, p_reason)
```

`p_expected_decision_at` is the `decided_at` of the active decision the caller believes exists, or
NULL for "I believe there is none". A mismatch raises `40001`. That one comparison is both the
**stale-write guard** and the **duplicate guard**: two admins working the same queue cannot both
succeed, and a second decision that ignores the first is refused rather than silently replacing it
(`PREMAP-19`, `PREMAP-20`).

Admin only. Viewer, engineer, manager and anon are all refused (`PREMAP-1`…`PREMAP-4`).
Engineer/manager Region-scoped mapping remains deferred and was **not** opened here.

## 4. Per-asset workflow

| Asset | Hierarchy offered | Station-only valid? | Equipment parent |
| --- | --- | --- | --- |
| Storage Vessel | Region → Station → Unit | yes, recorded as `needs_unit_mapping` | none — a vessel hangs off a Unit |
| Recovery Tank | Region → Station → Unit | yes | none |
| Gas Detector | Region → Station → Unit | yes | none — `needs_equipment_mapping` does not apply to detectors |
| Hose | Station → Unit | **yes, explicitly** — the accepted hose architecture says Station-only is a legitimate end state where the source does not prove the Unit | none — a hose's optional parent is a Dispenser, and no source proves one |
| Installed SRV | Region → Station → Unit → equipment | via `needs_unit_mapping` | compressor, storage vessel or dispenser |

Region is not a separate control: it is **derived from the confirmed Station**, because a Station
already belongs to exactly one Region and offering both would invite them to disagree.

No equipment parent is invented for an asset model that does not have one.

## 5. How Prompt 21 consumes decisions

Prompt 21 is **not executed here.** What it will do:

1. Read `v_import_confirmed_mappings` — the ACTIVE decisions, keyed by `source_row_key`.
2. For each staging row, call `planRow()` (`src/import/mappingDecisions.ts`):
   * a matching active decision for the same `target_table` → plan `commit`, using
     `confirmed_station_id` / `confirmed_unit_id`;
   * no decision and no staged Station → plan `hold_needs_station`, and the row **stays staged**;
   * not a pre-import asset type → plan `not_applicable`, untouched.
3. `applyDecision()` returns a **new** staged row carrying the confirmed ids. It copies
   `sourceRaw`, `sourceRowKey`, `sourceRowHash` and `provenance` through unchanged, preserves what
   the pipeline concluded under `normalized.staged_mapping_status`, and records
   `resolution.human_decision` with `scope: "this source row only; NOT an alias and NOT a global
   rule"` — so a later reader can tell a confirmed mapping from a matched alias.

**Prompt 21 never re-derives a Station.** It either finds an active decision or leaves the row
alone. The whole replay is covered end to end by "goes raw unresolved row → decision → plan that
would commit confirmed ids" in `src/import/__tests__/mappingDecisions.test.ts`.

## 6. Admin channel policy (migration 0040)

`/settings` is a **user** saying "I want email". `notification_channel_policy` is the
**organization** saying "email is available at all".

```
effective delivery = admin policy permits the channel
                 AND the user opted in to that channel
```

They compose; neither overwrites the other. Disabling a channel writes **no preference row**
(`CHAN-3`), so re-enabling restores exactly the audience that existed before (`CHAN-5`, `CHAN-6`).
That is the entire reason this is a separate table rather than a bulk update over
`notification_preferences`.

The gate lives in `cng_enqueue_alert_deliveries`, which is otherwise byte-for-byte the 0034 logic —
recipient predicate, urgency floor, visibility check and `ON CONFLICT` idempotency all unchanged.
Putting it there rather than in the Edge Function means it applies to every caller, present and
future. All three channels ship **enabled**, so Prompt 15–18 delivery is unaffected.

### In-app has no off switch — a decision, not an omission

In-app is not a delivery channel in this product; it is the **read surface**. `/alerts` and the
notification bell are how an engineer learns a vessel is overdue, and `notification_channel` has
only ever held `email` and `web_push` (migration 0001), so there is no delivery row to suppress.

An admin toggle that hid them would remove safety-critical compliance visibility from people
authorized to see it, invisibly. So:

* `ncp_in_app_mandatory_ck` makes disabling it **impossible**, not merely discouraged (`CHAN-9`);
* the function refuses with an explanation (`CHAN-7`);
* the screen says *"Cannot be disabled — it is the alert read surface, not a delivery channel"*
  instead of offering a control that always refuses. A toggle that never works is a lie in the
  shape of a control.

**What remains immutable on an alert rule:** `subject`, `threshold` and `days_before`. They are
rule identity — alerts already raised carry the threshold they were raised under, and editing the
window would retroactively reinterpret them. **Severity was not invented**: there is no severity
column on `alert_rules` or `alerts`, and none was added to satisfy a checklist.

## 7. Verification

| | Now | Prompt 19 baseline |
| --- | --- | --- |
| Frontend tests | 486 | 451 |
| Schema assertions | 146 | 146 |
| Authorization assertions | 479 | 406 |
| Migrations replayed from zero | 40 | 38 |

The gate also replays the **upgrade path**: a production-equivalent database at 37, then 0038,
0039 and 0040 in order, then both SQL suites against the upgraded database — because a replay from
zero proves internal consistency, not that the hosted database can take the new migrations.

**NOT DEPLOYED.** 0039 and 0040 exist in the repository only. Nothing here is LIVE VERIFIED.

## 8. Still deferred, with reasons

| Item | Why |
| --- | --- |
| Engineer / manager Region-scoped mapping (D8) | a SECURITY DEFINER function bypasses the RLS that would bound an engineer to their Regions, so the scope must be enforced *inside* the function and given its own hostile pass |
| Bulk mapping | the same scope work, plus a bulk action must **report** out-of-scope records rather than skipping them |
| `conflict` resolution UI | `conflict` is an evidence-preserving side state; resolving it means choosing between two sources, which is the `import_source_conflicts` workflow, not this one |
| Prompt 21's commit itself | explicitly out of scope |
