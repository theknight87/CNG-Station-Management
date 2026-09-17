# Stage B, step one — batch Station mapping

*Prompt 22A. Migration 0047. **Built and verified locally; NOT deployed and NO
production mapping decision written.***

---

## 1. What this confirms, and what it does not

Stage A committed 157 Stations and 188 Units. 281 staged asset rows now resolve,
by exact Region-aware normalized name, to exactly one canonical Station each.
This records that as **Station-only** confirmations, in one transaction, bound to
the exact preview an owner read.

It writes no Unit and no equipment parent of any kind. It creates no alias,
imports no canonical asset, and touches no staging row outside the approved set.

## 2. It reuses the existing architecture

No parallel mapping system was invented. `import_mapping_decisions` (0039) with
its content binding (0041) already holds exactly this shape: one decision per
source row, keyed by `source_row_key`, bound to the `source_row_hash` the decider
actually read, superseding rather than overwriting, with
`imd_one_active_per_source_row` making "exactly one active decision" a database
property. The batch writes the same rows the single-row path writes.

**The resulting status is not a new rule either.** `cng_admin_decide_staged_mapping`
already derives it and the batch uses the identical expression:

| Family | Before | After Station-only confirmation |
| --- | --- | --- |
| Storage Vessels | `needs_station_mapping` | `needs_unit_mapping` |
| Recovery Tanks | `needs_station_mapping` | `needs_unit_mapping` |
| Gas Detectors | `needs_station_mapping` | `needs_unit_mapping` |
| Hoses | `needs_station_mapping` | `needs_unit_mapping` |

All four behave identically because all four carry the same
`station_id NOT NULL` / `unit_id NULL` shape. This is the lifecycle CLAUDE.md §4
states; no step was added or skipped to make a batch convenient. Station
confirmation is **not** Unit confirmation and **not** equipment resolution.

## 3. One deliberate deviation from the prompt, and why

Prompt 22A asked for a `service_role`-only function. **The schema forbids it.**

`import_mapping_decisions.decided_by` is `NOT NULL REFERENCES app_users(id)`,
because CLAUDE.md §9 requires every mapping change to record who made it and §10
forbids a forgeable actor column. `service_role` carries no Clerk subject, so a
`service_role` batch could satisfy that column only by

- accepting an actor parameter — which Prompt 22A itself forbids, or
- making the column nullable — which would create unattributed human rulings.

So the actor is derived server-side from the verified Clerk subject via
`cng_require_admin()`, exactly as the single-row path has since 0039, and EXECUTE
is granted to `authenticated` only, where **the admin check, not the grant, is
the gate**. Every non-admin role is refused, proved by attack (STAGEBSEC-4..9).

Stage A differs precisely because a Station carries no `created_by`: creating the
hierarchy is an operator action with no human ruling to attribute, so it could be
— and remains — `service_role` only (STAGEBSEC-14).

## 4. The candidate set is derived, never supplied

A candidate is a staged row of one of the four pre-import families, still
`needs_station_mapping`, whose normalized source Station name matches **exactly
one** canonical Station **in its own Region**.

Everything else is excluded by construction:

| Excluded | Why |
| --- | --- |
| no same-Region match | nothing to confirm; never fuzzy-matched |
| match only in another Region | Region is identity (§8); a cross-Region match is not a match |
| already past `needs_station_mapping` | this step is done for that row |
| already carrying an active decision | one active decision per source row |
| installed SRVs | their canonical `station_id` is nullable; they map in the canonical table |

There is no similarity, suffix stripping, edit distance or alias lookup.
`cng_normalize_name` is the only comparison, and it is the same deployed function
Stage A used.

**Same-Region ambiguity is unreachable, not merely unhandled**: two Stations in
one Region cannot share a normalized name, because `stations_region_norm_uq`
forbids it. Proved by attempting the duplicate (STAGEB-36), so the `exactly one`
test can only ever exclude a row for having *zero* matches.

## 5. Review is grouped; the commit is not

An owner reads **69 Region-aware Station identities**, not 281 rows. Each group
carries every raw source spelling that folded into it, the exact staging row ids,
their `source_row_hash` evidence, the family split and the current lifecycle
states. Grouping is a review convenience — **the commit stays bound to every
individual row**.

Each group is classified `DETERMINISTIC STATION CANDIDATE` or `OWNER REVIEW`, and
anything with a pre-existing decision or mixed lifecycle states is separated out
rather than folded into the batch.

## 6. The approval is content-bound and fails closed

`cng_stage_b_station_commit(run, expected_manifest_fp, expected_preview_fp, reason)`.
Both fingerprints are required and re-derived inside the transaction; NULL, blank
or stale refuses.

The preview fingerprint folds in, **per candidate row**: staging row id, Region
id, Station id, Station normalized identity, Station display name,
`source_row_hash`, `mapping_status`, and whether a decision already exists. So a
single comparison covers every drift the prompt lists:

| Drift | Caught by |
| --- | --- |
| source row changed | `source_row_hash` |
| canonical Station changed, renamed or deleted | station id + name + normalized identity |
| Region changed | region id |
| normalization result changed | normalized identity |
| row `mapping_status` changed | status |
| a decision appeared after preview | `has_active_decision`, plus an explicit second gate |
| candidate became ambiguous | set membership — the row leaves the set |
| candidate disappeared | set membership |

## 7. Verified at full scale, locally

Against a 1,104-row fixture over the real Stage A hierarchy (157/188), driven
through the deployed functions:

| | |
| --- | --- |
| preview | **69 groups / 281 rows**, 69 deterministic, 0 owner-review |
| families | storage vessels 100 · recovery tanks 91 · gas detectors 64 · hoses 26 |
| decisions written | **281** across **69** Stations |
| Unit ids written | **0** |
| equipment ids written | **0** (structurally impossible — §8) |
| Region mismatches | 0 |
| `reviewed_source_row_hash` mismatches | 0 |
| other-Region rows decided | 0 |
| remaining undecided blockers | **823** |
| Stations / Units after | 157 / 188, unchanged |
| aliases / canonical assets after | 0 / 0 |
| audit rows | 281, one per decision |

**Atomicity was proved, not assumed**: the batch was run inside an explicit
transaction that wrote 281 decisions and was then rolled back — **0 persisted**.

**Replay was refused** on a second identical commit, at the fingerprint gate
(because `has_active_decision` had flipped), leaving 281 unchanged. The
already-decided gate and `imd_one_active_per_source_row` stand behind it.

Nine refusal scenarios were each proved to leave **zero** decisions behind:
missing, blank and wrong fingerprints; a wrong manifest; a changed source hash; a
moved lifecycle status; a renamed canonical Station; and a changed Region.

## 8. Equipment inference is structurally impossible

`import_mapping_decisions` has no `compressor_id`, `dispenser_id`,
`storage_vessel_id`, `recovery_tank_id`, `gas_detector_id` or `hose_id` column at
all. STAGEB-21 asserts that from `information_schema`, so equipment parentage
cannot be recorded here even by mistake — it is not merely omitted from the code.

The commit contains no dynamic SQL and names two literal targets,
`import_mapping_decisions` and `audit_logs`, re-derived from `pg_proc.prosrc`.

## 9. The remaining 823 rows / 247 identities

Read-only analysis. **No fuzzy match is proposed, no Station is created from an
asset name, and no alias is extended.**

| Region | Rows | Identities | Canonical Stations in that Region |
| --- | --- | --- | --- |
| Upper | 266 | 85 | **0** |
| Alex | 199 | 59 | **0** |
| Canal | 171 | 51 | **0** |
| Delta | 99 | 25 | 75 |
| West | 82 | 22 | 40 |
| East | 6 | 5 | 42 |

Families: storage vessels 333 · recovery tanks 312 · gas detectors 155 · hoses 23.

| Reason no candidate exists | Rows |
| --- | --- |
| **Region has zero canonical Stations** — no structural source covers it | **631** |
| no canonical Station carries this name in that Region | 178 |
| name matches a **Unit** name, not a Station name | 9 |
| name matches a Station only in **another Region** | 5 |

All 823 rows carry a raw source Station name, so nothing is lost — the evidence
is present and the canonical counterpart is not.

**631 of the 823 — more than three quarters — are not a mapping problem at all.**
Alex, Canal and Upper have no structural source, so Stage A correctly created no
Stations there. These rows need a source that states those Stations' structure;
inventing Stations from asset names is exactly what CLAUDE.md §8 forbids. The
open `unmatched_station` import issues (2,435 across all families) already record
this.

## 10. Status — DEPLOYED AND PREVIEWED (Prompt 22B)

Migration 0047 is **deployed**: 46 → **47**, recorded once as
`20260917094822 stage_b_station_batch`. File SHA-256
`a9a63f2413e6bc991d77fe7a244ea810d63337c230859f7a58b8cd687e7dd3fe`.

Deployment was proved byte-exact rather than merely applied: the `pg_proc.prosrc`
MD5 of all four deployed functions matches the locally built approved copy, and
`cng_normalize_name` hashes identically, so 0045 remains untouched.

**The migration executes no DML.** Its only two `INSERT`s live inside the commit
function's body; at migration time it creates four functions, four comments and
twelve grant/revoke statements, and changes no table, column, enum, index or
policy.

### Owner authorization decision (22B)

The commit **remains admin-gated with a server-derived actor**, explicitly
approved. `decided_by` stays `NOT NULL`, no actor is accepted from the client,
and attribution is not weakened. Stage A's `service_role`-only architecture is
unchanged — verified after deployment: Stage A browser EXECUTE 0, service_role 3.

### Deployed security verification

| | |
| --- | --- |
| commit `prosecdef` | true; read paths false |
| `search_path` | pinned on all four |
| volatility | commit `v`; all three read paths `s` (STABLE — cannot write) |
| EXECUTE: anon / authenticated | **0** / 4 |
| actor parameters | **0** |
| commit signature | `p_import_run_id uuid, p_expected_manifest_fingerprint text, p_expected_preview_fingerprint text, p_reason text DEFAULT NULL` |
| calls `cng_require_admin()` | yes |
| browser write grants on `import_mapping_decisions` | **0** |
| INSERT/UPDATE/DELETE policies on that table | **0** |
| tables without RLS | 0 |

**No dynamic SQL.** The deployed body contains no `EXECUTE` and no
`quote_ident`. It contains exactly one `format()`, at the audit-summary line,
which builds a human-readable message string — never SQL, and never from a
caller-supplied identifier.

**Attacks run in production, read-only.** `cng_require_admin()` was called
directly (not the commit, which this prompt did not authorize) with claims
carrying **no subject** and with a **subject mapping to no `app_user`**: both
refused with `42501`, and the probe aborted deliberately so it could leave
nothing behind.

**A minor behavioural finding, worth recording**: when `request.jwt.claims` is
set to an *empty string* rather than absent or valid JSON, the gate fails with a
JSON parse error (`22P02`) instead of `42501`. It still **fails closed** — nothing
proceeds — but the error class differs. No code was changed for this; it is noted
so a future reader is not surprised by the error text.

**Role-specific live refusal (viewer, engineer, manager, deactivated) is
DEFERRED with the reason recorded.** Proving it in production would require
either invoking the Stage B commit — which 22B forbids — or creating test
`app_users`, which would be fabricating authorization records. It is asserted
instead against real RLS with real personas in `rls_authorization.sql`
(STAGEBSEC-4..9), the same posture taken for the Prompt 20D role-specific item.

## 11. Deployed production preview

Executed through the **deployed** `cng_stage_b_station_preview`, not the inlined
reproduction. The fingerprint matched the expected value **exactly**, which also
confirms the 22A inline reproduction was faithful.

| | |
| --- | --- |
| import run | `cdad1e5e-7faa-4f3b-9432-12a720f3dd64` |
| manifest fingerprint | `764d3c0f…f091b8f` |
| **preview fingerprint** | **`a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769`** |
| candidate groups | **69** |
| candidate rows | **281** |
| `DETERMINISTIC STATION CANDIDATE` | **69** |
| `OWNER REVIEW` | **0** |
| groups carrying a warning | 0 |
| rows with an existing decision | 0 |
| canonical Stations / Units | 157 / 188 |

**Region and family distribution, from the deployed grouping function:**

| Region | Groups | Rows | Storage | Recovery | Detectors | Hoses |
| --- | --- | --- | --- | --- | --- | --- |
| Delta | 60 | 199 | 67 | 72 | 60 | 0 |
| West | 9 | 82 | 33 | 19 | 4 | 26 |
| **Total** | **69** | **281** | **100** | **91** | **64** | **26** |

- **69 distinct Station targets**, one per group; all exist, all Region-correct.
- **78 raw spellings** across the 69 identities — 9 groups carry more than one
  written form of the same Station.
- Group sizes: eleven groups of 1 row, up to one group of 32.
- **Hash coverage is complete**: 281 of 281 rows carry a 64-character
  `source_row_hash`, and all **281 are distinct**, so no two rows share evidence.
  Every group's hash and row-id arrays match its row count exactly.
- Every candidate row is still `needs_station_mapping`; **0** already decided.

**The preview wrote nothing**, proved by counters either side of the call:
`import_mapping_decisions.n_tup_ins` 0 → 0, `audit_logs.n_tup_ins` 1 → 1,
`import_staging_rows.n_tup_upd` 402 → 402 (the 402 is Stage A's lineage update
from Prompt 21D, unchanged).

## 12. Expected effect of the batch, if later approved

Read-only simulation. All **281** rows would transition
`needs_station_mapping → needs_unit_mapping`, producing exactly **281**
`import_mapping_decisions`, each carrying the staged row identity, the confirmed
canonical Station, `confirmed_unit_id = NULL`, the server-derived Admin actor, a
decision timestamp and an audit row.

Verified from the deployed body: it writes `NULL` into the unit position, derives
`needs_unit_mapping`, names only `import_mapping_decisions` and `audit_logs`, and
matches no hierarchy, alias or canonical-asset write. The decision table carries
**0** equipment columns, so no equipment parent is expressible.

## 13. The remaining 823 stay out, provably

Candidates and remainder are **disjoint — 0 rows appear in both**.

| Region | Rows | | Reason no candidate exists | Rows |
| --- | --- | --- | --- | --- |
| Upper | 266 | | Region has zero canonical Stations | **631** |
| Alex | 199 | | no Station of that name in the Region | 178 |
| Canal | 171 | | matches a **Unit** name, not a Station | 9 |
| Delta | 99 | | matches a Station only in **another Region** | 5 |
| West | 82 | | | |
| East | 6 | | | |

No fuzzy match is proposed, no Station is created from an asset name, and no
alias is extended.

---

## 14. Prompt 22C — STOPPED AT THE ADMIN GATE (no commit performed)

The batch was approved and the final pre-commit guard passed on **every** value.
The commit was **not executed**, because this session cannot legitimately
satisfy the authorization model the owner approved in 22B.

### The pre-commit guard passed

| | |
| --- | --- |
| preview fingerprint | `a014745d…e0cbe769` — **match** |
| manifest fingerprint | `764d3c0f…f091b8f` — **match** |
| groups / rows | **69 / 281** |
| families | 100 / 91 / 64 / 26 |
| all 281 still `needs_station_mapping` | yes |
| rows already decided | 0 |
| baseline | 47 migrations · 157 Stations · 188 Units · 0 decisions · 0 aliases · 0 assets · 1,104 blockers |

### Why it stopped

`cng_stage_b_station_commit` derives its actor from `cng_require_admin()`, which
reads the verified Clerk subject. This session's execution context is:

| | |
| --- | --- |
| `current_user` / `session_user` | `postgres` (operator connection) |
| superuser | false |
| `request.jwt.claims` present | **no** |
| verified subject | **none** |
| `cng_current_app_user_id()` resolves | **no** |

So `cng_require_admin()` raises `42501` and the commit refuses — correctly.

**The only way to make it succeed from here would be to set
`request.jwt.claims` to the owner's subject myself.** That is forging the actor.
It is what Prompt 22C forbids ("the server must derive the actor", "do not bypass
the gate"), what Prompt 22B's authorization decision exists to prevent, and what
CLAUDE.md §10 forbids outright — an audit actor column that cannot be forged.
Written approval in a prompt is not the same as an authenticated Admin session,
and the whole point of the approved design is that the decision record names the
human who made it in one.

**This is the gate working, not a defect.** Nothing was written: production holds
0 mapping decisions with an all-time `n_tup_ins` of **0**.

### How the owner runs it

From an authenticated **active Admin** session (the deployed app, or any client
carrying their Clerk token — `authenticated` holds EXECUTE):

```sql
select * from cng_stage_b_station_commit(
  'cdad1e5e-7faa-4f3b-9432-12a720f3dd64',
  '764d3c0fbe09f3ac95b27ce235f0fb08cfd92711e2a4ec56defb227b5f091b8f',
  'a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769',
  'Prompt 22C approved Stage B Station batch'
);
```

It returns `decisions_written`, `rows_confirmed`, `groups_confirmed` and the
fingerprint it committed against, and refuses if anything has moved since the
preview. Run it **once**; on any ambiguous transport error, check
`import_mapping_decisions` read-only before considering anything further.

## 15. Future Unit-mapping workload — and a blocking finding

Recomputed read-only against the real committed hierarchy. The categories are
unaffected by whether the Station decisions exist, since the commit creates no
Station or Unit.

| Category | Rows | |
| --- | --- | --- |
| **A** — candidate Station has exactly one Unit | **240** | |
| **B** — candidate Station has several Units | **38** | every one has exactly **2** Units |
| **C** — candidate Station has zero Units | **3** | all Delta |

### The finding: no Unit evidence exists on any of the 281 rows

The normalized payload of these rows carries **no Unit-bearing field at all**:

| Evidence | Rows |
| --- | --- |
| any unit name / number / raw unit column | **0** |
| non-NULL `unit_id` | **0** |
| `location_raw` | 191 |
| `compressor_context_raw` | 191 |
| `area_type_raw` (gas detectors) | 64 |
| `serial_number` | 199 |

The full key set is region, station name, serial, dates, manufacturer, pressures,
presence and the `location`/`compressor context`/`area type` text. **Not one
names a Unit.**

**Category A cannot be resolved by its own shape.** "The Station has exactly one
Unit" is a fact about the *hierarchy*, not evidence about the *asset*, and
treating it as proof is the distribution rule CLAUDE.md §4 permanently forbids.
240 rows is precisely the size at which that shortcut is tempting.

**Category B** would need evidence naming the Unit — a source column, a
per-asset work record, or a human on site confirming each asset. `location_raw`
(present on 37 of the 38) is an equipment-KIND hint by §4's own words and
"is not evidence of Unit membership", so it narrows *which kind of parent*, never
*which Unit*.

**Category C** cannot proceed at all: the Station has no Units, and D7 forbids
inventing one to have somewhere to attach an asset.

**Conclusion for the next stage: a Stage B Unit batch has no source to run on.**
Unit mapping needs new evidence — a source that states Unit membership per asset
— not a cleverer rule over the evidence already staged. That is a finding to act
on, not a gap to close by inference.

---

## 16. Prompt 22C.1 — the Admin execution surface

Prompt 22C stopped because the commit can only be run by a session carrying a
verified Clerk subject, and an operator connection has none. This is that
session's path to the one approved batch. **No migration was required.**

### The authenticated path, verified before any code was written

`src/lib/supabase/client.ts` holds a single Supabase client created with the
project URL and the **publishable** key, and an `accessToken` callback that
reads the current Clerk session token per request. Supabase verifies that token
against the trusted Clerk issuer and exposes its claims to PostgreSQL, where
`cng_jwt_sub()` → `cng_current_app_user_id()` → `cng_require_admin()` read them.
No JWT template, no service-role key, no hand-built claims.

Proved against production, read-only, by assuming the owner's real subject under
role `authenticated` inside a deliberately aborted transaction:
`cng_current_app_user_id()` resolved, `cng_is_admin()` was true, and the
deployed preview returned **69 groups / 281 rows** with the approved
fingerprints. The commit was **not** invoked.

### What was added

| File | Purpose |
| --- | --- |
| `src/features/admin/useStationBatch.ts` | the guard, the RPC call, the verification path |
| `src/features/admin/sections/AdminStationBatchSection.tsx` | the surface |
| `src/features/admin/__tests__/stationBatch.test.tsx` | 33 tests |
| `src/features/admin/{index.ts,AdminView.tsx}`, `src/routes.tsx` | route `/admin/station-batch` and its nav entry |

### The guard is the live server, not the constants

The approved run, both fingerprints and the expected 69/281 are constants, but
they are only what the **live preview is compared against**. The control unlocks
only when the server currently reports all of them; any drift renders
`APPROVED BATCH HAS CHANGED — EXECUTION BLOCKED` and lists **every** mismatch,
not just the first. A failed preview read shows an error rather than a button.

### Accidental execution is not possible

Opening the dialog sends nothing. The final action stays disabled until the
Admin types `CONFIRM 281 STATION MAPPINGS` exactly — case and all. Nothing
executes on page load or on preview.

### Running it twice is not possible

The control locks the instant it is submitted. **An uncertain result is never a
retry**: a thrown request, or an error carrying no PostgreSQL SQLSTATE, is
classified `uncertain`, and the screen says *"Execution result is uncertain. Do
not submit again."* and offers only a **read-only** check, which reads the
outcome as committed (281 decided), not executed (0 decided, fingerprint
unchanged) or — deliberately — **unexpected** for anything between, which stops
rather than guessing.

Replay protection after a refresh is **server-derived, not remembered**: once
the batch runs, every candidate row carries an active decision, the preview
reports it, and the screen shows the completed state. Nothing in `localStorage`
can bring the button back, and another Admin in another browser sees the same.

### One wording precision

The batch writes a **decision**; it does not rewrite
`import_staging_rows.mapping_status`. `v_admin_staged_mapping_queue` keeps the
two apart as `staged_mapping_status` (raw, untouched evidence) and
`confirmed_mapping_status` (from the decision). The screen therefore says
**Confirmed mapping status: Needs Unit Mapping** rather than implying the staged
column moved.

### Authorization is unchanged

The section is hidden from non-Admins for UX only; `AdminView` already refuses
the whole area to anyone else. **The database remains the authority** —
`cng_require_admin()` was not touched, no RLS or grant was changed, the browser
receives no service-role key or password, and the RPC carries exactly four
parameters: the run and the three approved strings. Tests assert the payload
contains no `actor`, `decided_by`, `clerk`, `sub`, `app_user`, `service_role`,
`password` or `secret` under any key, and that no table is written directly.

---

## 17. Prompt 22C.2 — the preview timeout, diagnosed and fixed

`/admin/station-batch` failed in production with *"canceling statement due to
statement timeout"* while loading the READ-ONLY preview. The commit was never
reached and nothing was written.

### It was RLS evaluation count, not data volume

The same call, same data, same moment:

| | |
| --- | --- |
| as an operator connection (RLS bypassed) | **225 ms** |
| as the owner's authenticated session (RLS enforced) | **39,371 ms** |

A 175× gap over 7,163 staged rows and 157 Stations is not size. Broken down
under RLS:

| | |
| --- | --- |
| plain staged scan | 894 ms |
| `stations` scan | 27 ms |
| `import_mapping_decisions` scan | 0.8 ms |
| `cng_stage_b_station_candidates` | **9,737 ms** |
| `cng_stage_b_station_groups` | 9,892 ms |
| `cng_stage_b_station_preview` | **39,371 ms** ≈ 4 × candidates |

**Two compounding causes, both structural:**

1. `candidates` asked, for **every one of the 1,104 staged rows**, "how many
   Stations in this Region carry this normalized name?" as a correlated
   subquery — and each evaluation re-scanned `stations` **through its RLS
   policy**. 1,104 × ~9 ms is the 9.7 s almost exactly.
2. `preview` then evaluated that **four times** — once for its own candidate
   CTE and once inside each of its three calls to `groups`. 4 × 9.7 s is the
   39 s almost exactly.

### The first fix attempt was four times slower

Joining once and counting with a window function — the obvious rewrite —
measured **37,444 ms**, worse than the original, because the planner still
re-scanned the RLS-protected table and added window overhead on top. It is
recorded here because it is exactly the change a reasonable reviewer would
propose, and only measurement rules it out.

Measured alternatives, same session, same RLS, all returning the same 281 rows:

| Shape | Time |
| --- | --- |
| current correlated shape | 9,795 ms |
| window-function rewrite — **rejected** | 37,444 ms |
| materialize `stations` only | 1,321 ms |
| **materialize `stations` and the staged set** | **303 ms** |

### The fix, and what it does not change

Migration **0048** marks both CTEs `AS MATERIALIZED`, so RLS is evaluated **once
per table** rather than once per staged row, and has `preview` hold its candidate
and group sets in materialized CTEs so `groups` is called once instead of three
times.

**The exact new body, measured in production under real RLS, read-only:
307.6 ms, 281 rows, fingerprint
`a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769` — byte-for-byte
the approved one.**

Semantics were proved unchanged locally at full scale, by snapshotting the old
output and diffing against the new: **0 rows differ** in candidates, groups and
preview; row **order** is identical; 281 rows both ways; the local fingerprint is
identical before and after.

RLS is evaluated fewer **times**, never bypassed. The read paths stay SECURITY
INVOKER and STABLE, so a caller still sees exactly the rows their own policies
allow — asserted from the catalog (STAGEBPERF-6). No grant, policy, RLS setting
or `cng_require_admin()` was touched, and `cng_stage_b_station_commit` is not
modified.

### Raising the timeout was deliberately not the fix

A preview over 7,163 rows has no business taking 39 seconds. Hiding that behind
a longer `statement_timeout` would have left the same per-row RLS re-evaluation
in place to bite a larger dataset later. No timeout was changed.

### One limit worth stating plainly

**The slowness does not reproduce locally** — the same preview runs in ~235 ms
against the local fixture before *and* after 0048, because local RLS is cheap.
So the performance evidence is **production-measured** (read-only) and the
correctness evidence is **local**. Neither is presented as the other.

## 18. Prompt 22C.3 — 0048 deployed, live Admin preview verified

Migration 0048 is **deployed to production**: 47 -> **48**, recorded exactly once
(`20260917110814 stage_b_preview_performance`), from the file approved at commit
`52d38ec` with SHA-256 `9e3d2c3e...f303620b` recomputed immediately before transmission.

**DEPLOYMENT IS PROVED BYTE-EXACT, NOT MERELY APPLIED.** The two function bodies were
extracted from the approved file and hashed *before* deployment, then compared against
`pg_proc.prosrc` afterwards:

| Function | Expected `prosrc` MD5 | Deployed | Length |
| --- | --- | --- | --- |
| `cng_stage_b_station_candidates` | `ddf963f66bcc46903db4480601ba34ef` | identical | 1828 |
| `cng_stage_b_station_preview` | `5780e33f99aef996d8ca8c0f60fc25fd` | identical | 1856 |

**EXACTLY TWO FUNCTIONS CHANGED.** Verified from the catalog by comparing before/after
`prosrc` MD5: `cng_stage_b_station_commit` (`b040117a...`), `cng_require_admin`
(`ff29bdea...`), `cng_normalize_name` (`3c4d8a93...`) and `cng_stage_b_station_groups`
(`4cd1e91e...`) are **bit-for-bit unchanged**. The migration's statement inventory was
machine-scanned, not eyeballed: two `CREATE OR REPLACE FUNCTION`, two `COMMENT`, and
**zero** ALTER/DROP/GRANT/REVOKE/INSERT/UPDATE/DELETE/TRUNCATE/CREATE POLICY/CREATE INDEX.
The words `grant`, `statement_timeout`, `cng_require_admin` and `cng_stage_b_station_commit`
appear in the file **only on `--` comment lines**. No migration-time DML.

**SECURITY UNCHANGED.** Both replaced functions remain `prosecdef = false`
(SECURITY INVOKER) and `provolatile = 's'` (STABLE), so they cannot write and RLS still
bounds every row they return; `search_path` stays pinned; EXECUTE remains `authenticated`
with **anon 0**; `import_mapping_decisions` still has **0** browser write grants and **0**
write policies; **0** public tables without RLS.

**NO TIMEOUT WAS RAISED.** `authenticated` still carries Supabase's stock
`statement_timeout = 8s` and `anon` 3s — untouched. That 8s is the real browser budget,
and the verification was run *under it* rather than against a relaxed one.

**LIVE AUTHENTICATED PREVIEW — 664 ms, and the approved fingerprint.** Executed READ-ONLY
as the owner's Admin identity (`is_admin = t`) with the genuine 8s timeout in force, in a
deliberately aborted transaction. Six samples: **664.0 / 676.7 / 677.2 / 668.3 / 687.0 /
712.1 ms** — a single distinct fingerprint across all runs,
`a014745dd823917027a082a2d61a57fc831ccd59d22c67dcd7145982e0cbe769`, **exactly the approved
value**, so the owner's approval does not lapse. Against the pre-fix 39,371 ms this is a
**~59x improvement, landing at ~8% of the 8s budget**.

**ONE NUMBER IS HIGHER THAN 22C.2 PREDICTED, AND IS REPORTED AS MEASURED.** Prompt 22C.2
measured the candidate body at 307.6 ms; the deployed end-to-end preview measures ~670 ms.
The 22C.2 figure timed the new body inline, while this times the full deployed preview
including its `groups` call, on a shared instance under its own load. The honest figure is
**~670 ms**, not 307.6 ms. It is well inside budget either way, and no claim is restated
at the more flattering number.

**SEMANTICS EXACT**: 69 groups / 281 rows, 69 DETERMINISTIC STATION CANDIDATE, **0** OWNER
REVIEW, **0** already decided; families **100 / 91 / 64 / 26**; **78 raw spellings = 69
normalized identities**; stations 157, units 188; manifest `764d3c0f...` as approved.

**THE PREVIEW WROTE NOTHING**, proved by counters either side: `import_mapping_decisions`
`n_tup_ins` 0 -> **0** (and `n_tup_ins` counts even rolled-back tuples, so no decision was
ever so much as attempted), `audit_logs` 1 -> 1, `import_staging_rows` `n_tup_upd`
402 -> 402, stations/units/aliases all unmoved.

**READING AS THE OWNER IS NOT FORGING AN ACTOR.** Prompt 22C refused to set the claims GUC
because doing so would have attributed a *written* mapping decision to a human who had not
made it in a session. The preview takes no actor parameter, writes no row and attributes
nothing, so the same technique carries no forgery — the distinction is what is written, not
what is read. **`cng_stage_b_station_commit` was not invoked in any execution context.**

**GATE**: exit 0 — frontend **617**, schema **247**, authorization **624**, 48 migrations
from zero, upgrade replay 47 -> 48 with both suites re-run. No baseline decreased.
Migrations 0044-0047 re-hashed after the work and byte-identical.

**PRODUCTION AFTER**: 48 migrations, regions 6, stations 157, units 188,
`import_mapping_decisions` **0** (all-time `n_tup_ins` **0**), 1,104 rows still
`needs_station_mapping`, canonical assets 0, aliases 0/0, 7,163 staging rows, 0 tables
without RLS. **The batch still awaits the owner's click.**
