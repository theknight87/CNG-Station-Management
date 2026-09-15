# Security Audit — standalone prompt

Copy everything between the rules below into any AI coding agent. It is
self-contained: it needs no skill system, no plugins and no prior
context. Delete the sections that obviously do not apply to your stack.

**Optional first line to add when you already know the answer:**
> Live platform access (MCP/CLI) is available — use it directly, do not
> ask me to run queries. Remediation is / is not pre-approved.

---

## ─────────── COPY FROM HERE ───────────

You are performing a security audit of this codebase. Work only from
files that exist here and from live platform state you can actually
observe. Never answer from general best practice. Never add a library or
a service just to make a check possible.

### Governing rules

1. Never trust the browser. Any client-supplied value is attacker-chosen
   until a trusted side re-derives or re-checks it.
2. Never assume the repository equals production. Verify live where
   tooling allows.
3. Never treat a hidden or disabled UI control as authorization.
4. Every finding cites real evidence — file, line, policy, function,
   table, or live query output. No intuition-only findings.
5. **PHASE 1 IS READ-ONLY.** Change no code, migration, policy, function,
   database or configuration until I approve remediation.
6. Never print, log or document a real secret value — reference it by
   name and location only.
7. Do not run availability-affecting tests against production (load,
   brute force, mass email, deletion).
8. A control being **enabled** is not the data being **protected**.
   State the property that matters — "no unauthenticated caller can
   read this" — and test it by *becoming* the untrusted caller. "Row
   security is on for every table" can be entirely true while the data
   is readable by anyone through a path the row rules never see.

---

### STEP 1 — Reconnaissance (prove, do not assume)

Do not infer architecture from filenames or framework conventions. Prove
it from the repository. Print a short **"What I found"** list, writing
**"not present"** for anything missing:

- Language, framework, versions.
- Whether ANY code runs on a trusted side — API routes, server actions,
  edge/serverless functions, a separate backend — or everything ships to
  the browser.
- Where data lives: hosted DB, backend-as-a-service, ORM, files, browser
  storage, nothing yet.
- How a user is identified: auth provider, hand-rolled sessions, API
  keys, none.
- How it deploys and where environment variables come from.
- Every external and paid integration (email, SMS, payments, AI/model
  APIs, storage, push).

Then answer the decisive question explicitly:

> **Does the browser talk to the database or a privileged service
> directly, using a credential shipped in the bundle?**

If yes, state plainly that the data store's own rules are the entire
security model and application-side filtering is irrelevant.

Finally, draw the trust boundaries and mark each one with what enforces
it (use `?` where nothing does).

---

### STEP 2 — Existing security history

Look for `SECURITY_HISTORY.md`, `SECURITY.md`, prior audit reports,
architecture/security notes, agent instruction files. Read them as
**historical context only**. Do not assume previous findings remain
fixed — re-verify current state. Re-examine previously **accepted**
risks as well, asking what accepting each one disables elsewhere: an
accepted risk is a decision taken against one consideration and usually
has consequences nobody enumerated at the time. For each, write down
what it switches off, then go and check whatever that was protecting.
If no history file exists, recommend creating one after remediation.

---

### STEP 3 — Audit domains

Cover the domains that apply. Explicitly skip inapplicable ones with one
line of reasoning rather than padding the report.

**"Test" in this phase means read-only probing.** Reading catalogues,
inspecting configuration, building with marker values and reasoning from
code are in scope now. Anything that *writes* — creating a user,
inserting a row, invoking an endpoint with side effects, changing a
policy — waits for my approval, **even inside a transaction you intend to
roll back**. If a finding can only be settled by a write, say so and mark
it ⚪ pending instead of performing it.

**3.1 Secrets.** Find every credential in code, config, committed env
files, CI definitions, infrastructure files and scheduled-job command
text; check git history where practical; check that env files are
ignored. For each, answer: **does it reach what the browser downloads?**
Decide from this project's own build and env rules, not convention.
Where a frontend build tool inlines variables by prefix, **prove the
behaviour with a marker build**: set each variable to a unique value,
build, and grep the output bundle. Classify every credential as
*public-by-design*, *sensitive*, or *privileged server-side*. If nothing
runs on a trusted side, say plainly that every key the project holds is
public.

**3.2 Client-controlled values.** Find every browser-supplied value that
**decides** something: roles, permissions, ownership, user/tenant/org
IDs, prices, totals, quantities, transaction direction, discounts,
approval state, subscription tier, account status, feature access,
workflow state, billing state, audit attribution, `created_by`/
`updated_by`, admin flags, and any id selecting which record to read or
write. For each, say whether the trusted side re-derives it, re-checks
it, or takes it as sent. Enumerate **every writer** of a
security-sensitive column — triggers, RPCs, admin endpoints, imports and
webhooks included — not just the obvious one.

**3.3 Authentication.** Inspect signup, login, password reset, magic
links/OTP, invitations, OAuth, email verification, anonymous sign-in,
sessions, refresh tokens, logout, account-creation triggers, profile
creation, role initialization. Specifically test for: role or
entitlement taken from **signup metadata**; account-creation hooks that
run with elevated rights and therefore **bypass row-level rules**;
invite flows that carry privilege in the request; and auth settings that
live outside the repository (open signup, password policy, leaked-password
checks, MFA, session lifetime).

**3.4 Authorization.** Map every role and permission. For every entry
point that reads or writes data, say whether it requires a verified
identity and **where that check runs**. Flag anything that returns or
changes user data with no check, or relies on the interface hiding it, or
**takes a user/tenant id from the request** to decide whose data to
return instead of deriving it from the session. Say whether one choke
point covers every route or the check is repeated per handler; list any
route not covered. Test horizontal and vertical escalation,
self-promotion, cross-tenant access and alternate-path privilege change.

**3.5 Database-enforced access.** If the store can enforce its own
rules: verify **live** whether row-level security is actually ENABLED,
not merely that policies exist — *policies without RLS enabled are
inert, and this fails silently*. Inspect SELECT/INSERT/UPDATE/DELETE
policies separately. Hunt for `USING (true)` / `WITH CHECK (true)` on
writes. Enumerate policies from the live catalogue, because
dynamically-generated policies are invisible to a text search. Identify
tables with RLS on and zero policies and confirm whether that is
deliberate. Inspect elevated-privilege functions: what they do, who may
execute them, whether their search path is pinned, who owns them — and
remember **they bypass the row rules you just verified**, as do triggers
written that way.

Then audit the **grants**, which the row rules do not cover. A view that
runs as its owner does not apply the caller's row rules, so for such a
view the table-level grant is the only thing between it and an
unauthenticated reader. Do not infer read access from the policy list:
**assume the anonymous/untrusted role and select from every table and
view**, and report exactly which objects returned rows. Check the
schema's DEFAULT privileges as well — many platforms seed them so every
future object is granted to every role, which makes any revoke you
perform temporary; prove the change by creating an object the way the
project's migrations do, inside a transaction that rolls back, and
reading its ACL. If a default ACL belongs to a platform-owned role you
cannot alter, say so explicitly and name what stays exposed.

Probe **every object kind**, not one: loop over tables *and* views (and
materialized views / foreign tables where they exist), and state in the
finding which kinds you enumerated — a census that covers one kind
proves nothing about the other, and a finding that does not say what it
searched cannot be re-checked.

Read each policy's **role list** as well as its expression. A policy
written without a `TO` clause applies to PUBLIC, which includes the
anonymous role; a project can have correct-looking expressions
throughout and still address every policy to everyone. A `USING (true)`
read policy addressed to PUBLIC is protected only by the grant — report
that as a finding even when the current grant makes it unreachable, and
say plainly that it is a missing second layer rather than an open door.

When re-declaring policies to fix a role list, write each one out rather than regenerating them from the catalogue — a policy rebuilt by dynamic SQL is unreviewable in a diff. And before changing any policy, establish which callers bypass row security entirely (a platform service identity usually does, as does the owner of a definer function on the signup path); that tells you which risks are real before you write the migration rather than after it breaks something.

A rule that is documented but unenforced is itself a finding. Where a
spec or role table says "role X may only do Y", test whether anything
actually stops them doing Z, and report the gap classified by
consequence rather than treating it as handled because it is written
down. Before closing such a gap, enumerate every path that writes the
columns or calls the operation you are about to restrict — a
restriction written earlier often contradicts a feature shipped since,
and that conflict belongs to the owner, not to you. Note also that
per-column authorization usually cannot be a grant (column privileges
are per database role, and signed-in users typically share one, so the
grant would restrict the privileged role too), and that such a guard
must compare old values to new rather than firing on a column being
present, since clients commonly send the whole record on every save.

A platform security advisory is not always an actionable task. Managed
platforms report the desired state, not what the project's plan or
licence permits, so a warning needing a paid upgrade looks identical to
a five-second toggle. When an advisory resists clearing, check the
subscription tier from the API rather than the console's appearance —
some render a paid control as available and refuse only on save —
attempt the change and keep the refusal message as evidence, and record
that the advisory will keep firing so the next audit does not chase it
again. State the residual risk in one sentence and whether an upgrade is
warranted for that risk alone; that decision belongs to the owner.

Where every signed-in user reaches the database as the **same** role and
the application's own roles live in a table, note that a grant cannot
express per-role authorization at all — revoking to hide something from
one application role hides it from all of them, so the distinction must
live in a policy or inside the object. When you add such a restriction
to a shared object, enumerate every caller first — each application
role, the service/automation identity used by scheduled jobs and
serverless functions, and the anonymous role — and record a row count
for each. A restriction that also silences a background job reads as a
pass from the attacker's side and is discovered weeks later.

**3.6 Drift.** Where live tooling exists, compare repository against
production: schema, policies, RLS state, functions, triggers, scheduled
jobs, deployed serverless code, configuration, grants. Classify each as
`verified matching` / `drift found` / `cannot verify`.

**3.7 Serverless / edge functions.** For each deployed function check
authentication, token verification, authorization, privileged credential
use, public invocability, replay protection, rate limiting,
deduplication, idempotency, input validation, webhook signature
verification, and whether invoking it costs money or sends something.
**Do not trust a source comment claiming the function is protected —
read the deployed configuration.** Treat any function holding a
privileged/service-role credential as a high-risk trust boundary.

**3.8 Scheduled jobs.** Database cron, platform cron, CI schedules,
external schedulers. Do they call public endpoints? How do they
authenticate? **Is a broad privileged credential embedded in stored
command text?** Are repeated runs safe? Can they trigger billable or
externally visible actions repeatedly? Prefer a purpose-scoped secret
over a broad credential; generate it server-side so it is never typed or
committed, and verify it without ever returning it (compare a digest, or
compare inside the trusted system and return only a boolean).

**3.9 Rate limiting and abuse.** List every entry point reachable
without logging in, and every one that costs money or time per call
(paid APIs, mail, SMS, generated media, model inference, heavy compute,
uploads, report generation). For each: any limit per IP/user/key, where
enforced, what happens when exceeded. Include login, signup, password
reset and OTP. Distinguish application-side limits, provider limits,
deduplication, idempotency and replay protection. Ask: **if the trigger
secret leaked today, what is the maximum bill?** If unbounded, the
control is missing. If nothing is limited, state what someone could run
up in an hour and where the limit belongs in this stack.

**3.10 Data integrity.** Inspect business-critical calculations and state
transitions. Prefer server/database derivation for direction, balances,
totals, prices, ownership, timestamps, status, approval state, creator
identity and billing state. Ask whether a manipulated client can corrupt
accounting, inventory, audit, billing, entitlement or workflow state.
Credit good patterns where you find them (generated columns, append-only
ledgers, triggers rejecting direct writes to derived values).

**3.11 Audit trail integrity.** Review audit logs and attribution
columns. The client must not be able to impersonate another user in the
record of who did something. When attribution is broken on one table,
**enumerate the whole schema** — it is almost always systemic, and a
NULL default plus no policy mentioning the column means it is
client-supplied and unchecked.

**3.12 Multi-tenancy.** Where applicable, verify a user cannot read or
mutate another tenant's data by changing an id in a request. Test both
direct row access and indirect paths through RPCs, reports, exports and
search.

**3.13 Storage.** Bucket policies, public vs private, signed URL
generation and expiry, upload permissions, MIME/size restrictions, path
traversal, predictable paths, overwrite/delete permissions, tenant
isolation, metadata leakage.

**3.14 Injection.** Prioritise what this stack can actually suffer:
SQL/NoSQL injection, command injection, stored and reflected XSS, HTML
injection, SSRF, path traversal, unsafe redirects, template injection,
unsafe deserialization, spreadsheet formula injection. Pay attention to
dynamic SQL built by concatenation inside database functions.

**3.15 Browser security.** CORS, cookie flags (`SameSite`, `HttpOnly`,
`Secure`), CSRF for cookie-authenticated state changes, CSP,
frame/clickjacking exposure, tokens in `localStorage`, `postMessage`
origin checks.

**3.16 Dependencies.** Outdated or known-vulnerable packages where
tooling allows, abandoned packages, install scripts, unnecessary
privileged packages, lockfile integrity. **Do not upgrade anything
during the audit unless I approve it.**

**3.17 Infrastructure.** Platform and CI/CD configuration, secret
handling in pipelines, preview environments pointing at production data,
branch protection, publicly exposed deploy previews. Separate repository
evidence from dashboard-only configuration.

---

### STEP 4 — Live tooling

If platform MCP/CLI/API access is available, **use it**. Verify
production yourself rather than asking me to run queries you could run.

When a setting is genuinely unreachable, mark it and move on — do not
block the audit:

```
⚪ CANNOT VERIFY — MANUAL CHECK REQUIRED
Setting:   <exact name>
Where:     <exact navigation path>
Expected:  <recommended value>
Why:       <what it protects>
```

If your own environment blocks network access, say that explicitly —
"blocked by my sandbox" and "the project lacks this" are different
statements. Where a fix can make a dashboard-only setting no longer
security-critical, prefer that over documenting the setting.

---

### STEP 5 — Severity

- 🔴 **Critical / High** — directly exploitable privilege, data,
  credential, money or control impact.
- 🟠 **Medium** — meaningful integrity or security weakness.
- 🟡 **Low** — defence in depth / hardening.
- 🟢 **Fine** — reviewed and correctly protected (record these too).
- ⚪ **Cannot verify** — say exactly what evidence you would need.

Do not inflate severity.

---

### STEP 6 — Report, then STOP

Produce: the "What I found" list; trust boundaries; findings by severity
with problem, location, why it matters, evidence, exploitability and a
proposed fix in this stack; one summary table; an ordering of
exploitable-now / weak / fine / cannot-verify; and the manual checks with
exact paths.

**Then stop and wait for my approval.** Change nothing yet.

---

### STEP 7 — Remediation (only after I approve)

Fix in severity order, one item at a time, smallest secure change first.

- Where the project uses migrations, **add a new one**; never edit an
  already-applied migration. Where it does not, follow the project's
  existing convention — do not introduce a migration system now.
- **Inspect live state immediately before changing it**, every time.
- Do not alter unrelated business logic, permissions or UI behaviour.
- Do not weaken an existing permission to simplify a fix.
- Preserve legitimate workflows; if a fix breaks a real journey,
  redesign the fix.
- **Prefer a systemic fix for a systemic problem.** If the same flaw
  exists on many tables, fixing the two I named and leaving the rest
  creates the illusion of coverage. Enumerate the full surface, then fix
  the class — and tell me you widened the scope.
- Add **defence in depth** for privilege and cost: two independent
  controls, where one failing does not silently disable the other.
- Avoid destructive changes. Never delete data to simplify a fix.

**Force vs reject.** For attribution/identity, prefer *forcing* the
correct value server-side over rejecting a mismatch — rejecting breaks
existing callers, and for a "who did this" field the right outcome is the
correct name on the row, not an error. For privilege and entitlement,
prefer *rejecting* or *downgrading*; never silently granting.

**Fail closed.** A guard that passes when its input is missing, when a
lookup returns nothing, or when an error is caught is not a guard. Be
suspicious of heuristic guards ("refuse if this looks like production") —
test the heuristic against the real environment; if it would have passed
where it must have failed, replace it with an explicit flag that must be
deliberately supplied.

**If a security check returns a generic error instead of its denial** (a
500 where a 401 belongs), the check is not deciding the outcome — the
error handler is. Fix the root cause. Do not wrap it in a catch that
treats the error as denial, and never as success.

**Keep the UI honest.** If a backend fix makes a UI control meaningless,
remove it rather than disabling it, and state plainly what happens now.
But removing a control is never itself a fix — verify the underlying
API/database permission too.

---

### STEP 8 — Testing

Test every remediation **against the original attack**:

```
1. Original malicious action
2. Expected secure result
3. Actual result
4. PASS / FAIL
```

Also run **regression tests for legitimate workflows** — one normal
action per role, and one calculation whose exact value you can predict.

Prefer **transaction-based tests that roll back**. In SQL, this pattern
reports results while guaranteeing rollback:

```sql
DO $$
DECLARE r1 text; r2 text;
BEGIN
  -- attack attempts, each in its own BEGIN ... EXCEPTION ... END
  -- so one rejection does not abort the suite; capture SQLSTATE
  RAISE EXCEPTION 'RESULTS >> a=[%] b=[%] <<', r1, r2;
END $$;
```

**Afterwards, verify production is unchanged** — query for every artefact
you might have created (test users, rows, secrets, seeded entries,
files) and confirm zero.

**Side effects escape a rollback.** An outbound HTTP request, an email,
a webhook or a queue message sent from inside a transaction still
happens even though the transaction rolls back — rollback protects your
data, not the outside world. So if something cannot be rolled back,
design the test so the expensive branch is skipped — pre-seed state, or
test only denial paths — and say which branch you did not exercise. Then
remove that pre-seeded state and confirm removal, or you will suppress
the next legitimate run.

**Traps that produce false results — check these before concluding a fix
failed:**

- `INSERT … RETURNING` also applies the **read** policy. A write can be
  legal while `RETURNING` fails because the caller may not read the
  table. Re-test without `RETURNING`.
- Running a function as its owner changes `current_user` but **not**
  `session_user`. Platform internals (secret decryption, key management)
  may behave differently depending on the connection role, so **a
  passing direct-SQL test does not guarantee a passing test through the
  application's real connection path**. Test through the real path.
- Elevated-privilege functions bypass row rules, so testing through one
  proves nothing about the policies.
- Generated/computed columns cannot be assigned in a before-trigger — a
  "rebuild the whole row" approach breaks on them; assign named fields.
- An existing column may carry a `CHECK` allow-list that blocks the value
  you planned to reuse. Verify constraints before designing around a
  column.
- A view may expose a column under a different name than the base table.
  Verify the actual column list before shipping a query.
- A row rule may be evaluated before a table constraint, so an invalid
  test fixture can mask the result you wanted — use valid data.
- The same error code can mean "policy denied" and "insufficient
  privilege". Read the message, not just the code.

**Do not record a test as passed until you understand why it produced
that result.** If a test fails unexpectedly, first determine whether the
vulnerability remains **or the test itself is flawed** — before changing
production code. Changing the fix to satisfy a broken test re-opens real
holes.

---

### STEP 9 — Final verification

Re-check live: RLS/policy state, policies per command, roles, triggers,
functions and their execution grants, serverless configuration,
scheduled jobs, secret exposure, authorization, attribution, drift, and
that **no test artefact remains**. Re-run the critical attack tests after
all changes are in, because fixes interact. Run any platform security
advisor and compare against the pre-audit baseline: the goal is no new
findings, with a documented reason for each remaining one.

---

### STEP 10 — Final report

Include: architecture summary · trust boundaries · findings by severity ·
evidence · exploitability · fixes made · tests performed with results ·
regression results · live verification output · remaining risks ·
manual/dashboard checks · files and migrations changed · live objects
changed · commits created.

**Never conclude "the application is secure."** State exactly what was
verified, by what means, and what remains unknown.

---

### STEP 11 — Security history

Append (never erase) a dated record to `SECURITY_HISTORY.md`: findings,
remediation, migrations, live changes, tests, commits, unresolved items,
final verified state. Maintain a separate `SECURITY.md` describing the
**current** model — what enforces what, the verification query with its
expected output, and the attack tests to re-run after touching auth or
policies. If neither file exists, create them.

On any future audit: inspect the repository and live state again, compare
against previous results, identify regressions and new attack surface,
and verify each previously fixed finding by **re-running its attack
test**, not by reading the old report.

## ─────────── COPY TO HERE ───────────

---

## Notes for the human running this

- **The single highest-value check** in most modern stacks is whether the
  browser reaches the data store directly with a bundled key. It changes
  the meaning of every other finding.
- **The most commonly missed check** is whether database row rules are
  actually *enabled* in production versus merely present in migrations.
  They fail silently and look correct in git.
- **The most commonly missed surface** is the second writer of a
  privileged column — a trigger, an RPC, an import path, a webhook.
- If your agent has live platform access, say so in the first line;
  otherwise it will ask you to run queries it could run itself.
- Expect the audit to pause after Step 6. That pause is deliberate.
- To use the companion `SKILL.md` as an invokable skill in an agent that
  supports them, copy the `security-audit/` folder into that project's
  skills directory (for Claude Code: `.claude/skills/security-audit/`).
  This standalone prompt needs no installation at all.
