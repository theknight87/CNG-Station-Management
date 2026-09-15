# Decision Log

Decisions taken by the project owner that resolve questions raised in
[`data-quality-report.md`](./data-quality-report.md) §13. Each entry states the decision, what it
changes, and what it explicitly forbids.

Decisions are binding on the importer and on the application. Where a decision creates a new
deterministic rule, that rule is recorded here so it can be audited later.

---

## D1 — `ابنوب` = `ابنوب اسيوط`, as an exact pair *(2026-09-14, narrowed by the owner)*

**Decision (authoritative, settled):** `ابنوب` and `ابنوب اسيوط` are the same physical Station.
This holds for current and future imports and requires no further confirmation.

**Scope — narrowed by the owner after this decision was first drafted.** The original draft
generalized this into a rule that stripped any trailing governorate qualifier. **The owner did not
authorize that.** The confirmation covers this **exact pair and nothing else**.

**Rule (exact value, not a pattern).** The pair is a row in `owner_confirmed_station_aliases`.
Resolution is by exact string equality:

- the raw name is exactly `ابنوب اسيوط` → resolves to Station `ابنوب`, alias auto-confirmed with
  `alias_source = 'owner_confirmed'`
- anything else — including every other governorate-suffixed name — → **proposed**, never
  confirmed; a human decides

There is no suffix rule, no regex, no similarity threshold, and none may be added. Tests
`RESOLVE-4` and `RESOLVE-5` in `src/import/__tests__/resolution.test.ts` assert both halves: the
pair resolves, and `ابو القمصان اسيوط`, `ابو تيج- اسيوط`, `الادبيه - السويس`, `شبرا اسيوط` do not.

Applied **0 times** in the Prompt 6 dry run, because `ابنوب اسيوط` does not occur in the
six-workbook corpus. That is a property of the corpus, not of the rule.

The rule is recorded on every alias it creates, so all of them can be listed, audited, and
reversed as a group if the rule is later found wrong.

**Forbidden:** applying the rule when the remainder is ambiguous; stripping any other trailing
token on the assumption it is a governorate.

---

## D2 — `<name> <n>` is Unit *n* of Station `<name>` *(2026-09-14)*

**Decision:** `الخمائل` is a Station containing two Units, `الخمائل 1` and `الخمائل 2`. The
numbered-name pattern denotes Units, consistent with `شبرا 1`…`شبرا 4` and `ابو رواش 1`/`2` in
`Assets DataBase`.

**Rule (deterministic).** For a source name of the form `<base> <n>` (trailing integer):

- `<base>` resolves to exactly one canonical Station in the Region → the name is **Unit `<n>`**
  of that Station; alias created with `alias_source = 'rule:numbered_unit'`
- `<base>` resolves to nothing or to several → **proposed** only; human review

This settles the mixed-grain problem in `Station data base.xlsx`: a numbered row is a Unit, and
`<base>` is its Station — the Station being created if the rule proves it exists.

**Forbidden:** treating a numbered name as a Station in its own right once `<base>` resolves;
inventing a Unit number the source never states.

**Note:** a Station whose real name genuinely ends in a number would be misread. None is known;
every alias created by this rule carries its provenance so the set can be reviewed.

---

## D3 — SRV parent resolution is manual only *(2026-09-14)*

**Decision:** SRV parentage is resolved by **manual or bulk mapping inside the application**, or
from a new source file if one is supplied later. **Default distribution is forbidden**
(«ممنوع التوزيع الافتراضي»).

This confirms the prohibited-inference list in `CLAUDE.md` §4 and adds: no future source may be
applied as a distribution heuristic either. A new file resolves an SRV only where it names that
SRV's parent.

**Forbidden:** any rule that spreads SRVs across compressors or vessels by count, order,
round-robin, capacity, or proportion — at import, in a backfill, or as a UI convenience.

---

## D4 — `SS-4R3A` is a part number; these SRVs have no serial yet *(2026-09-14)*

**Decision:** `SS-4R3A` (48 rows) is a **part number**, not a serial. This SRV type has **no
unique serial number yet**; unique serials will be assigned later.

**Consequences:**

- `serial_number` = `NULL`, `serial_status = 'not_yet_assigned'`
- the raw value is preserved in `serial_raw` **and** mapped to `part_number`
- these rows are **not duplicate-serial findings**. The largest cluster in the quality report
  (48 rows of `SS-4R3A`, plus similar part-number values) leaves the duplicate set, which must be
  recounted after import.
- the future serial assignment is a first-class workflow: an engineer assigns a serial, the
  record moves to `serial_status = 'assigned'`, and the change is audited. `serial_raw` is
  never overwritten.

`serial_status`: `assigned` · `not_yet_assigned` · `unknown` (absent from source, no statement
either way).

**Forbidden:** generating a serial automatically; treating `not_yet_assigned` as a data defect;
counting these rows as duplicates.

---

## D5 — Manufacturer aliases *(2026-09-14)*

| Raw values | Decision |
| --- | --- |
| `NPSAC` / `NPAC` | **Same** manufacturer, one is a typo |
| `Worthington Cylinders` / `Worthing Cylinders` | **Same** manufacturer, one is a typo |
| `Anderson` / `Tyco Anderson` | **Different** manufacturers — do **not** merge |

Confirmed pairs become rows in a curated `manufacturer_alias` table with the canonical name.
Raw values stay in `manufacturer_raw` on every record.

**Forbidden:** inferring further merges from string similarity. `Anderson`/`Tyco Anderson` is the
standing proof that visual similarity is not identity — every other pair needs its own decision.

---

## D6 — `منتهي` / `منتهية` stays a raw source signal *(2026-09-14)*

**Decision:** "expired" text in a date column is preserved as a **raw source signal**. It does
**not** become a final calibration status in place of the date.

**Implementation:** `source_status_raw TEXT` alongside the date triple. The date is
`precision = 'invalid'`, `value = NULL`, `raw = 'منتهية'`, and `source_status_raw = 'منتهية'`.

The UI shows the signal ("source marked: منتهية") beside the missing date. It is **not** counted
as Overdue, because no due date exists to prove when it lapsed — only that the source considered
it expired at some unknown time.

**Forbidden:** converting the text into a date; converting it into a computed compliance status;
suppressing it.

---

## D7 — No one-unit-per-station fallback *(2026-09-14)*

**Decision:** for Canal, Alex and Upper — and anywhere else without an explicit Unit source —
**do not** create a default single Unit per Station. **If the Unit is unknown, it is `NULL`.**

This **reverses** the fallback previously specified in `import-mapping.md` §2 stage 2b.

**Consequence — the unit-unknown pattern generalizes beyond SRVs.** Compressors, dispensers,
storage vessels, recovery tanks and gas detectors are Unit-scoped, so a source row that proves
only a Station cannot create one under a Unit that does not exist. Every Unit-scoped asset table
therefore carries the same shape already defined for SRVs:

```
station_id   NOT NULL      -- proven
unit_id      NULL          -- unknown until mapped
mapping_status              -- resolved | needs_unit_mapping | ... | conflict
```

with the same rule: `resolved` requires `unit_id`; anything else leaves it NULL. Such records are
visible in their global management module, flagged *Needs Mapping*, excluded from Unit tabs, and
worked through Admin → Data Quality exactly like SRVs.

Where D2 proves the Unit (a numbered name), the Unit **is** created — D7 forbids only the
*invented* default Unit, not a Unit the evidence supports.

**Forbidden:** creating a Unit named after its Station merely to have somewhere to hang assets;
treating a Station with no Units as invalid or incomplete (principle #19).

---

## D8 — Mapping ownership and permissions *(2026-09-14)*

| Role | Mapping rights |
| --- | --- |
| `admin` | map anywhere |
| `regional_manager` | map anywhere *(per this decision: Admin + Manager)* |
| `station_engineer` | map **only within the Regions they are authorized for** |
| `viewer` | none |

Region scope is enforced in **RLS**, not only in the UI: an engineer's `UPDATE` on a mapping
column outside their Regions fails at the database. Every change — single or bulk, by any role —
writes an `asset_mapping_audit` row with actor, timestamp, before/after values, and bulk batch id.

**Forbidden:** a UI-only permission check; an unaudited mapping change; a bulk action that
silently skips records outside the actor's scope — it reports them instead.

---

## Effect on earlier findings

| Earlier statement | Status after these decisions |
| --- | --- |
| "38 duplicate SRV serials over 224 rows" | **Recount.** `SS-4R3A` (48) and similar part numbers leave the duplicate set under D4. |
| "Create station + one unit for Canal/Alex/Upper" | **Reversed** by D7. Unit stays NULL. |
| "~100–156 unmatched station names per file" | **Reduced** by D1 and D2; the residue after both rules is the real review queue. |
| "9 open questions" | Q1, Q2, Q3, Q4, Q5, Q6, Q8 answered (D1, D2, D3, D4, D5, D6, D8). Q7 answered by D7. Q9 (hose coverage) still open. |
