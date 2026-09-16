# Admin Module (Prompt 19)

Routes: `/admin/users`, `/admin/alert-settings`, `/admin/data-quality`, `/admin/audit-log`.
One migration: **0038**, additive.

---

## 1. What this prompt actually found

The gap analysis was read-first, and it turned up a real defect rather than a
missing screen.

`authenticated` already held **direct `UPDATE (role, is_active)` on `app_users`**
and **full `INSERT`/`UPDATE`/`DELETE` on `user_region_access`**, gated only by
`cng_is_admin()` in an RLS policy. The policy was correct as far as it went — a
non-admin could not use those grants — but the shape was wrong in three ways:

1. **The audit was optional.** Writing an audit row was a separate client call.
   An administrator (or a tampered client, or a plain `curl` with a valid admin
   token) could change a role and write nothing.
2. **Nothing protected the last administrator.** An admin could demote or
   deactivate themselves, or the only other admin, and lock the product out of
   its own administration with an ordinary UI click.
3. **A stale tab could silently overwrite a newer decision.** Two admins editing
   the same user is not exotic, and last-write-wins on a ROLE is a privilege bug.

Migration 0038 revokes both grants and replaces them with narrow
`SECURITY DEFINER` functions. Each one verifies admin, derives the actor
server-side, checks the caller's row-version precondition, applies the change and
writes the audit row **in the same statement**. An audited mutation can no longer
become an unaudited one by dropping a second call.

`ADMSEC-13` and `ADMSEC-14` assert the new posture directly: **not even an admin**
may `UPDATE app_users SET role` or `INSERT INTO user_region_access` any more.

## 2. What was already true, and was NOT rebuilt

* The composite foreign keys already enforce the physical hierarchy:
  `irv_unit_station_fk (unit_id, station_id) → units(id, station_id)`,
  `irv_compressor_unit_fk (compressor_id, unit_id)` and its vessel/dispenser
  siblings, plus `irv_status_shape_ck` and `irv_resolved_attribution_ck`.
  **None of it is re-implemented in application code, and none of it is
  relaxed.** `cng_admin_map_srv` leans on it; the MAP-4/6/7/15/16 assertions are
  those constraints refusing, not a check the function invented.
* `audit_logs` and `asset_mapping_audit` are already append-only, and their
  INSERT policies require `actor_id = cng_current_app_user_id()`, so the actor
  cannot be forged. 0038 adds no grant that would change that.

## 3. Who may do what

| Role | User administration | Alert settings | Mapping resolution |
| --- | --- | --- | --- |
| `admin` | yes | yes | yes |
| `manager` | **no** | **no** | **no** (this module) |
| `engineer` | no | no | no (this module) |
| `viewer` | no | no | no |

A manager keeps every technical permission Prompt 5 gave them and gains **no**
user or role administration. That is asserted, not assumed: `ADMSEC-8`, `-9`
and `-10`.

Region-scoped mapping by an engineer (decision D8) remains a separate,
deliberately deferred capability — see §7.

## 4. The safety rules, and why each one exists

| Rule | Why | Asserted by |
| --- | --- | --- |
| An admin may not change their own role | self-demotion is the easiest lockout, and no legitimate use is unserved by a second admin | ADMSEC-17 |
| An admin may not deactivate themselves | same | ADMSEC-18 |
| The last ACTIVE admin may not be demoted or deactivated | the product must never reach zero administrators through an ordinary action | ADMSEC-19 |
| Every mutation carries the row version it was decided against | last-write-wins on a role is one admin silently undoing another | ADMSEC-20, MAP-13/14, ALSET-5 |
| An unknown target is refused | a silent no-op reads as success | ADMSEC-23, ALSET-6 |

`cng_check_precondition` raises `stale_write` with `ERRCODE = 40001`. A NULL
expectation means "no precondition" and is used only where the row was read in
the same statement.

**A Region may be granted to an INACTIVE user.** This is a decision, recorded
rather than left implicit: `cng_current_app_user_id()` already requires
`is_active`, so an inactive user resolves to nothing and the grant confers
nothing until an administrator activates them. Refusing the grant would force
two sequenced actions for no security gain.

## 5. Alert settings

Only `is_enabled` is editable. `subject`, `threshold` and `days_before` are rule
**identity**: alerts already raised carry the threshold they were raised under,
and editing the window would retroactively change what those alerts meant. There
is no function to change them and no direct grant — `ALSET-7`, `-8` and `-9`
prove an admin can neither edit, create nor delete a rule from a browser.

Disabling stops FUTURE generation and **deletes nothing** (`ALSET-2`). The
three-layer separation from Prompt 15 — due status, alert, delivery — is
untouched.

## 6. Manual mapping

The lifecycle runs
`needs_station_mapping → needs_unit_mapping → needs_equipment_mapping → resolved`,
and **the resulting status is DERIVED in SQL from what was actually proven**. It
is not a parameter. A screen therefore cannot declare a record resolved by
asserting it; it can only supply a Station, a Unit and an equipment parent, and
the database decides how far that goes.

What the UI offers:

* Station, then Unit, then equipment — each level unreachable until the one above
  is confirmed (`MAP-8`, `MAP-9`).
* `expected_parent_kind` pre-selects the **kind** of equipment. It never selects
  a record, and it never populates a foreign key.
* The raw source evidence — `source_station_name_raw`, `serial_number_raw`,
  file/sheet/row — shown beside the normalized value, because the human decides
  from what the workbook actually said.

What it deliberately does not offer: **no candidate ranking, no similarity
suggestion, no default parent, no bulk rule derived from a name or a Location.**
A candidate is not a mapping.

Source evidence is never written by a mapping decision (`MAP-18`), and a rejected
mapping writes **no audit row at all** — the audit is atomic with the mutation,
not a separate best-effort call (`MAP-22`).

`resolved_by` and `resolved_at` are set from the server-derived actor, satisfying
`irv_resolved_attribution_ck`. **This was found by the test matrix, not by
reading**: the first version of `cng_admin_map_srv` omitted them and the
constraint rejected the resolution — which is the constraint doing exactly the
job its comment claims, "a second line of defence against an automated backfill
inventing parentage".

## 7. Deliberately deferred, with reasons

* **Engineer/manager Region-scoped mapping (D8).** The mapping path is admin-only
  in this prompt. Opening it to a `can_map` engineer needs the Region scope
  enforced *inside* the SECURITY DEFINER function — a definer function bypasses
  the RLS that would otherwise bound them — and that deserves its own hostile
  pass rather than a clause added here.
* **Bulk mapping.** Supported by the design (§9 of CLAUDE.md) and not built. A
  bulk action must report the records outside the actor's scope rather than
  skipping them silently, which is the same scope work as above.
* **Vessel / gas-detector / hose mapping mutation.** Their queues are *counted*
  on this screen. Mutation stays deferred for the attribution reason carried
  since Prompt 11, and because the 1,104 staged rows cannot enter their canonical
  tables at all while `station_id` is NOT NULL — that is a Prompt-21 decision, not
  something an admin screen may resolve by relaxing a constraint.

## 8. No count is hard-coded

`v_admin_data_quality` counts live rows. The 1,104 staged blocker figure is a
**pipeline fact about a dry run**, not a UI constant: typing it into a screen
would make the product lie the moment one record is resolved. A frontend test
scans every shipped file under `src/features/admin` and fails on `1104`, `433`,
`403`, `219` or `49` appearing as a literal.

## 9. Verification

| | Count | Previous baseline |
| --- | --- | --- |
| Frontend tests | 451 | 433 |
| Schema assertions | 146 | 146 |
| Authorization assertions | 406 | 332 |
| Migrations replayed from zero | 38 | 37 |

`scripts/verify-all.sh` exits 0. Every count is taken from the process, never
from filtered text (CLAUDE.md §7a).

Two pre-existing authorization assertions were deliberately changed, because the
mechanism they exercised was deliberately removed:

* `ADMIN-3/4/5` performed a direct `UPDATE app_users` / `INSERT INTO
  user_region_access` as an admin. The intent — "an admin can do this" — is
  preserved; the mechanism is now `cng_admin_set_user_role` /
  `cng_admin_grant_region` / `cng_admin_revoke_region`.
* `ENG-21`'s cleanup `DELETE FROM user_region_access` was previously a zero-row
  no-op under RLS and now raises, so it became a denial assertion, `ENG-21b`.

**NOT DEPLOYED.** Migration 0038 has not been applied to the hosted project and
the frontend has not been redeployed. Nothing here is LIVE VERIFIED.
